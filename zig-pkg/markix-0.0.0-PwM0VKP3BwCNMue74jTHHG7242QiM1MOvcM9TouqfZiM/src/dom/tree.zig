const std = @import("std");
const Rect = @import("../layout/rect.zig").Rect;
const flex_layout = @import("../layout/flex.zig");
const grid_layout = @import("../layout/grid.zig");
const DomNode = @import("node.zig").DomNode;
const NodeKind = @import("node.zig").NodeKind;
const Props = @import("node.zig").Props;
const types = @import("types.zig");
const text_measure = @import("../layout/text_measure.zig");
const LayoutElement = @import("../layout/tree.zig").LayoutElement;

/// A tree holds a whole screen, or a whole generated document. A long blog
/// post runs to a few hundred blocks, so this is sized for that rather than
/// for a terminal's worth of widgets.
pub const dom_nodes_max: u16 = 1024;

pub const Tree = struct {
    const Self = @This();
    pub const NodeIndex = u16;

    pub const Node = struct {
        element: DomNode,
        parent: ?Self.NodeIndex = null,
        first_child: ?Self.NodeIndex = null,
        last_child: ?Self.NodeIndex = null,
        next_sibling: ?Self.NodeIndex = null,
    };

    nodes: [dom_nodes_max]Node = undefined,
    node_count: Self.NodeIndex = 0,
    root: ?Self.NodeIndex = null,
    dirty_count: Self.NodeIndex = 0,

    pub fn init() Self {
        return .{};
    }

    pub fn reset(self: *Self) void {
        self.node_count = 0;
        self.root = null;
        self.dirty_count = 0;
    }

    pub fn get(self: *Self, index: Self.NodeIndex) ?*DomNode {
        if (index >= self.node_count) return null;
        return &self.nodes[index].element;
    }

    pub fn parent_index(
        self: *const Self,
        index: Self.NodeIndex,
    ) ?Self.NodeIndex {
        if (index >= self.node_count) return null;
        return self.nodes[index].parent;
    }

    pub fn child_count(
        self: *const Self,
        parent: Self.NodeIndex,
    ) Self.NodeIndex {
        if (parent >= self.node_count) return 0;
        var count: Self.NodeIndex = 0;
        var child = self.nodes[parent].first_child;
        while (child) |index| : (count += 1) {
            child = self.nodes[index].next_sibling;
        }
        return count;
    }

    pub fn set_root(self: *Self, element: DomNode) !Self.NodeIndex {
        if (self.root != null) return error.RootAlreadySet;
        const index = try self.append_node(element, null);
        self.root = index;
        if (element.dirty) self.dirty_count += 1;
        return index;
    }

    pub fn append_child(
        self: *Self,
        parent: Self.NodeIndex,
        element: DomNode,
    ) !Self.NodeIndex {
        std.debug.assert(self.node_count <= dom_nodes_max);
        if (parent >= self.node_count) return error.InvalidParent;
        const child = try self.append_node(element, parent);
        // Every pass over the tree relies on this: a child is always reached
        // after the parent that contains it, so one ascending walk is
        // parent-before-child and one descending walk is the reverse.
        std.debug.assert(child > parent);
        const parent_node = &self.nodes[parent];
        if (parent_node.last_child) |last| {
            self.nodes[last].next_sibling = child;
        } else {
            parent_node.first_child = child;
        }
        parent_node.last_child = child;
        if (element.dirty) self.dirty_count += 1;
        return child;
    }

    fn append_node(
        self: *Self,
        element: DomNode,
        parent: ?Self.NodeIndex,
    ) !Self.NodeIndex {
        if (self.node_count >= dom_nodes_max) return error.TreeFull;
        const index = self.node_count;
        self.nodes[index] = .{ .element = element, .parent = parent };
        self.node_count += 1;
        return index;
    }

    /// Marks a single node for repaint.
    ///
    /// Dirt deliberately does not climb to ancestors. The renderer scans nodes
    /// linearly, so a parent gains nothing from being repainted -- and since a
    /// list paints a background across its whole rect, repainting it would
    /// erase every sibling of the changed row. That is exactly the O(rows)
    /// cost this model exists to avoid. Dirt spreads downward instead, and
    /// only through nodes that paint over their children.
    pub fn mark_dirty(self: *Self, index: Self.NodeIndex) void {
        if (index >= self.node_count) return;
        const node = &self.nodes[index].element;
        if (node.dirty) return;
        node.dirty = true;
        self.dirty_count += 1;
    }

    /// Marks every node for repaint.
    ///
    /// For when the surface no longer holds what the tree last painted --
    /// another view drew over it, or the terminal was reset. Dirty flags track
    /// the tree against its own last paint, so nothing else can detect that.
    pub fn mark_all_dirty(self: *Self) void {
        var index: Self.NodeIndex = 0;
        while (index < self.node_count) : (index += 1) {
            self.mark_dirty(index);
        }
    }

    /// Focus and hover are DOM-owned state, so the tree mutates them: setting
    /// the flag through the node alone would dirty it without the tree's
    /// dirty_count agreeing, and the renderer would skip the frame.
    pub fn set_focused(self: *Self, index: Self.NodeIndex, value: bool) void {
        if (index >= self.node_count) return;
        const node = &self.nodes[index].element;
        if (node.focused == value) return;
        node.focused = value;
        self.mark_dirty(index);
    }

    pub fn set_hovered(self: *Self, index: Self.NodeIndex, value: bool) void {
        if (index >= self.node_count) return;
        const node = &self.nodes[index].element;
        if (node.hovered == value) return;
        node.hovered = value;
        self.mark_dirty(index);
    }

    /// True when repainting a node lays a background across its whole rect,
    /// which would erase any child that is not repainting alongside it.
    fn paints_over_children(kind: NodeKind) bool {
        return switch (kind) {
            .list, .panel => true,
            .heading, .rule, .code_block => false,
            .container,
            .label,
            .badge,
            .button,
            .list_item,
            .text_input,
            .segmented,
            .status_line,
            .image,
            => false,
        };
    }

    /// Expands dirt so that everything a repaint disturbs repaints with it.
    pub fn propagate_dirty(self: *Self) void {
        std.debug.assert(self.node_count <= dom_nodes_max);
        std.debug.assert(self.dirty_count <= self.node_count);
        var index: Self.NodeIndex = 0;
        while (index < self.node_count) : (index += 1) {
            const node = &self.nodes[index].element;
            if (!node.dirty) continue;
            if (paints_over_children(node.kind)) {
                var child = self.nodes[index].first_child;
                while (child) |child_index| {
                    std.debug.assert(child_index > index);
                    self.mark_dirty(child_index);
                    child = self.nodes[child_index].next_sibling;
                }
            }
            const damaged = node.rect();
            if (damaged.width == 0 or damaged.height == 0) continue;
            var later: Self.NodeIndex = index + 1;
            while (later < self.node_count) : (later += 1) {
                std.debug.assert(later > index);
                const candidate = &self.nodes[later].element;
                if (candidate.dirty) continue;
                if (!damaged.overlaps(candidate.rect())) continue;
                self.mark_dirty(later);
            }
        }
        std.debug.assert(self.dirty_count <= self.node_count);
    }

    pub fn clear_dirty(self: *Self) void {
        var index: Self.NodeIndex = 0;
        while (index < self.node_count) : (index += 1) {
            self.nodes[index].element.dirty = false;
        }
        self.dirty_count = 0;
    }

    pub fn is_dirty(self: *const Self, index: Self.NodeIndex) bool {
        if (index >= self.node_count) return false;
        return self.nodes[index].element.dirty;
    }

    /// The node carrying an anchor name, or null when nothing does.
    ///
    /// Linear, and deliberately so: a tree holds at most `dom_nodes_max` nodes,
    /// and an index would have to be rebuilt on every relayout to answer a
    /// question asked once per navigation. Bounded by the node count, which is
    /// the only bound available -- names are not unique by construction, so the
    /// first match wins and a caller that needs uniqueness must assert it.
    pub fn find_by_id(self: *const Self, id: []const u8) ?Self.NodeIndex {
        std.debug.assert(id.len <= types.semantic_id_bytes_max);
        if (id.len == 0) return null;
        var index: Self.NodeIndex = 0;
        while (index < self.node_count) : (index += 1) {
            const semantic = self.nodes[index].element.semantic;
            if (semantic.id.len != id.len) continue;
            if (std.mem.eql(u8, semantic.id, id)) return index;
        }
        return null;
    }

    /// Moves a list's selection to one of its rows.
    ///
    /// A list and its rows both hold selection state, and they have to be
    /// changed together: the list's `selected` is what a caller reads back,
    /// while the row's is what the renderer paints from. Setting only the
    /// list's -- which is what stepping through a list used to do -- moves a
    /// selection nothing draws.
    ///
    /// Two rows change, so two rows repaint: the one losing the selection and
    /// the one gaining it. Marking the list dirty instead would drag every row
    /// down with it, which is the O(rows) repaint the row nodes exist to
    /// avoid.
    ///
    /// `row` is an ordinal among the mounted rows, not a node index, because
    /// that is what a caller stepping through a list has in hand. Returns
    /// whether the selection now names that row.
    pub fn select_row(self: *Self, list: Self.NodeIndex, row: Self.NodeIndex) bool {
        if (list >= self.node_count) return false;
        if (self.nodes[list].element.kind != .list) return false;
        const gaining = self.row_node(list, row) orelse return false;
        const props = &self.nodes[list].element.props.list;
        const losing = self.row_node(list, props.selected);
        std.debug.assert(gaining < self.node_count);

        if (losing) |index| {
            if (index != gaining) self.set_row_selected(index, false);
        }
        self.set_row_selected(gaining, true);
        props.selected = row;
        std.debug.assert(self.nodes[gaining].element.props.list_item.selected);
        return true;
    }

    fn set_row_selected(self: *Self, index: Self.NodeIndex, value: bool) void {
        std.debug.assert(index < self.node_count);
        std.debug.assert(self.nodes[index].element.kind == .list_item);
        const state = &self.nodes[index].element.props.list_item.selected;
        if (state.* == value) return;
        state.* = value;
        self.mark_dirty(index);
    }

    /// The node holding a list's nth row.
    ///
    /// Rows are appended one after another, so they occupy a contiguous run of
    /// indices starting at the list's first child, and the nth is found by
    /// arithmetic rather than by walking to it. That is what keeps moving a
    /// selection independent of how long the list is -- walking made a key
    /// press in a thousand-row list cost a thousand steps to change two rows.
    ///
    /// The run is contiguous only while nothing else was appended in between,
    /// so it is verified rather than assumed, and a list built some other way
    /// falls back to the walk.
    fn row_node(self: *const Self, list: Self.NodeIndex, row: Self.NodeIndex) ?Self.NodeIndex {
        std.debug.assert(list < self.node_count);
        const first = self.nodes[list].first_child orelse return null;
        const last = self.nodes[list].last_child.?;
        std.debug.assert(last >= first);
        const candidate = first +| row;
        if (candidate <= last and self.nodes[candidate].parent == list) {
            std.debug.assert(self.nodes[candidate].element.kind == .list_item);
            return candidate;
        }
        if (candidate <= last) return self.walk_to_row(list, row);
        return null;
    }

    fn walk_to_row(self: *const Self, list: Self.NodeIndex, row: Self.NodeIndex) ?Self.NodeIndex {
        std.debug.assert(list < self.node_count);
        var ordinal: Self.NodeIndex = 0;
        var child = self.nodes[list].first_child;
        while (child) |index| : (ordinal += 1) {
            std.debug.assert(index > list);
            if (ordinal == row) return index;
            child = self.nodes[index].next_sibling;
        }
        return null;
    }

    pub fn set_props(
        self: *Self,
        index: Self.NodeIndex,
        props: Props,
    ) void {
        if (index >= self.node_count) return;
        const node = &self.nodes[index].element;
        if (!types.props_equal(node.props, props)) {
            node.props = props;
            self.mark_dirty(index);
        }
    }

    /// Resolves the layout, deriving content sizes along the way.
    ///
    /// Widths come from the container down, heights from the content up, so
    /// this runs three phases: place once to settle widths, measure the
    /// content those widths imply, then place again now that extents are
    /// known. Callers with only fixed sizes can keep using `evaluate`.
    pub fn layout(self: *Self, bounds: Rect) !void {
        try self.evaluate(bounds);
        self.measure();
        try self.evaluate(bounds);
    }

    /// Fills in `extent` for every `.content` sized node.
    ///
    /// Children always hold a higher index than their parent, so one
    /// descending pass sees every child before the parent that contains it.
    pub fn measure(self: *Self) void {
        var index = self.node_count;
        while (index > 0) {
            index -= 1;
            const element = &self.nodes[index].element;
            if (element.layout.sizing != .content) continue;
            element.layout.extent = self.intrinsic_extent(index);
        }
    }

    /// Height this node needs.
    ///
    /// A node with content of its own is measured from that content even when
    /// it has children, because those children are parts of it rather than
    /// things stacked beneath it -- the spans making up a wrapped paragraph,
    /// say. Containers hold rather than contain, so they measure from what is
    /// inside them.
    pub fn intrinsic_extent(self: *const Self, index: Self.NodeIndex) u16 {
        std.debug.assert(index < self.node_count);
        const element = &self.nodes[index].element;
        if (self.nodes[index].first_child == null) return self.content_extent(index);
        // Children that placed themselves have already settled the question.
        // Measuring the node's own content instead would be a second answer to
        // it, derived from a different width, and the two would disagree.
        if (arranges_freely(element)) return self.placed_extent(index);
        if (holds_children(element.kind)) return self.children_extent(index);
        return self.content_extent(index);
    }

    fn arranges_freely(element: *const DomNode) bool {
        return switch (element.layout.kind) {
            .free => true,
            else => false,
        };
    }

    /// How far down the furthest placed child reaches.
    fn placed_extent(self: *const Self, index: Self.NodeIndex) u16 {
        std.debug.assert(index < self.node_count);
        std.debug.assert(self.nodes[index].first_child != null);
        const element = &self.nodes[index].element;
        var bottom: u16 = 0;
        var child = self.nodes[index].first_child;
        while (child) |child_index| {
            const place = self.nodes[child_index].element.layout.placement;
            bottom = @max(bottom, place.y +| place.height);
            child = self.nodes[child_index].next_sibling;
        }
        std.debug.assert(bottom > 0);
        return bottom +| vertical_chrome(element);
    }

    /// Whether a node is sized by what it holds or by what it is.
    ///
    /// A container holds; a panel holds and frames. Everything else has
    /// content of its own -- the spans of a wrapped paragraph are parts of
    /// that paragraph, not rows stacked beneath it.
    fn holds_children(kind: NodeKind) bool {
        return switch (kind) {
            .container, .panel => true,
            .heading, .rule, .code_block => false,
            .label,
            .badge,
            .button,
            .list,
            .list_item,
            .text_input,
            .segmented,
            .status_line,
            .image,
            => false,
        };
    }

    fn children_extent(self: *const Self, index: Self.NodeIndex) u16 {
        std.debug.assert(index < self.node_count);
        std.debug.assert(self.nodes[index].first_child != null);
        const element = &self.nodes[index].element;
        const stacked_column = switch (element.layout.kind) {
            .stack => |spec| spec.direction == .column,
            else => false,
        };
        const gap = switch (element.layout.kind) {
            .stack => |spec| spec.gap,
            else => 0,
        };
        var total: u16 = 0;
        var count: u16 = 0;
        var child = self.nodes[index].first_child;
        while (child) |child_index| : (count += 1) {
            const extent = self.nodes[child_index].element.layout.extent;
            // A column stack accumulates its children; anything else lays them
            // side by side, so it is as tall as the tallest.
            total = if (stacked_column) total +| extent else @max(total, extent);
            child = self.nodes[child_index].next_sibling;
        }
        if (stacked_column and count > 1) total +|= gap *| (count - 1);
        return total +| vertical_chrome(element);
    }

    fn content_extent(self: *const Self, index: Self.NodeIndex) u16 {
        const element = &self.nodes[index].element;
        const width = element.layout.rect.width;
        return switch (element.kind) {
            .label => label_extent(element.props.label, width),
            .heading => heading_extent(element.props.heading, width),
            .rule => 1,
            .code_block => code_extent(element.props.code_block),
            .list => list_extent(element.props.list),
            .status_line, .text_input, .segmented, .badge, .button => 1,
            .container, .list_item, .panel, .image => 0,
        } +| vertical_chrome(element);
    }

    fn label_extent(props: types.LabelProps, width: u16) u16 {
        if (props.wrap) return text_measure.wrapped_rows(props.text, width);
        return text_measure.literal_rows(props.text);
    }

    /// A heading measures itself, marker indent and underline included.
    fn heading_extent(props: types.HeadingProps, width: u16) u16 {
        const widget = @import("../widgets/heading.zig").Heading{
            .text = props.text,
            .level = props.level,
            .style = props.style,
            .visual = props.visual,
        };
        return widget.rows(width);
    }

    fn code_extent(props: types.CodeBlockProps) u16 {
        const widget = @import("../widgets/code_block.zig").CodeBlock{
            .text = props.text,
            .language = props.language,
            .style = props.style,
            .visual = props.visual,
        };
        return widget.rows();
    }

    fn list_extent(props: types.ListProps) u16 {
        return props.item_count *| @as(u16, props.visual.row_height);
    }

    /// Rows a node spends on its own chrome rather than on content.
    fn vertical_chrome(element: *const DomNode) u16 {
        if (element.kind != .panel) return 0;
        return element.props.panel.chrome.content_padding_top;
    }

    pub fn evaluate(self: *Self, bounds: Rect) !void {
        const root_index = self.root orelse return error.MissingRoot;
        std.debug.assert(root_index == 0);
        std.debug.assert(root_index < self.node_count);
        self.nodes[root_index].element.layout.rect = bounds;
        var index: Self.NodeIndex = 0;
        while (index < self.node_count) : (index += 1) {
            // A list stacks its rows itself: row count is data-driven and can
            // exceed the fixed track budget a flex container is limited to.
            if (self.nodes[index].element.kind == .list) {
                self.evaluate_rows(index);
                continue;
            }
            const element = &self.nodes[index].element.layout;
            switch (element.kind) {
                .leaf => if (self.nodes[index].first_child != null) {
                    return error.LeafHasChildren;
                },
                .flex => |spec| try evaluate_flex(self, index, spec),
                .grid => |spec| try evaluate_grid(self, index, spec),
                .stack => |spec| self.evaluate_stack(index, spec),
                .free => self.evaluate_free(index),
            }
        }
    }

    /// Places children end to end along the stack axis, each taking the extent
    /// it declares. Unlike flex this needs no per-child track, so a container
    /// can hold as many children as the tree has room for -- which is what a
    /// document of arbitrary length needs.
    fn evaluate_stack(
        self: *Self,
        parent: Self.NodeIndex,
        specification: @import("../layout/tree.zig").StackLayout,
    ) void {
        std.debug.assert(parent < self.node_count);
        const container = self.nodes[parent].element.content_rect();
        var child = self.nodes[parent].first_child;
        var offset: u16 = 0;
        while (child) |index| {
            std.debug.assert(index > parent);
            const element = &self.nodes[index].element.layout;
            element.rect = @import("../layout/tree.zig").stack_rect(
                container,
                specification.direction,
                offset,
                element.extent,
            );
            offset +|= element.extent +| specification.gap;
            child = self.nodes[index].next_sibling;
        }
    }

    /// Keeps children where they placed themselves, relative to this node.
    ///
    /// For content whose arrangement was resolved before layout ran -- text
    /// already flowed into rows and columns, say -- where recomputing it would
    /// only risk disagreeing with the result already in hand.
    fn evaluate_free(self: *Self, parent: Self.NodeIndex) void {
        std.debug.assert(parent < self.node_count);
        const container = self.nodes[parent].element.content_rect();
        var child = self.nodes[parent].first_child;
        while (child) |index| {
            std.debug.assert(index > parent);
            const element = &self.nodes[index].element.layout;
            const place = element.placement;
            const width = @min(place.width, container.width -| place.x);
            const height = @min(place.height, container.height -| place.y);
            element.rect = Rect.init(
                container.x +| place.x,
                container.y +| place.y,
                width,
                height,
            );
            child = self.nodes[index].next_sibling;
        }
    }

    /// Stacks a list's mounted rows down its rect at the configured row height,
    /// starting from the one `scroll` names.
    ///
    /// Rows outside the window -- above it, or past the bottom edge -- collapse
    /// to zero size and the renderer skips them. So a caller may mount every
    /// item and let the list scroll through them, or mount only the window it
    /// wants and leave `scroll` at zero. Ignoring `scroll` here, which is what
    /// this did, made the second the only option that worked: the event
    /// handlers moved a window that never moved, and a selection driven past
    /// the bottom edge scrolled to a row that stayed exactly where it was.
    fn evaluate_rows(self: *Self, parent: Self.NodeIndex) void {
        std.debug.assert(parent < self.node_count);
        const props = self.nodes[parent].element.props.list;
        const rect = self.nodes[parent].element.layout.rect;
        const row_height: u16 = props.visual.row_height;
        var child = self.nodes[parent].first_child;
        var slot: u16 = 0;
        while (child) |index| : (slot += 1) {
            const element = &self.nodes[index].element.layout;
            if (slot < props.scroll or row_height == 0) {
                element.rect = Rect.init(rect.x, rect.y, 0, 0);
                child = self.nodes[index].next_sibling;
                continue;
            }
            const top = rect.y +| (slot - props.scroll) *| row_height;
            const fits = top +| row_height <= rect.y +| rect.height;
            element.rect = if (fits)
                Rect.init(rect.x, top, rect.width, row_height)
            else
                Rect.init(rect.x, top, 0, 0);
            child = self.nodes[index].next_sibling;
        }
        std.debug.assert(slot <= self.node_count);
    }

    fn evaluate_flex(
        self: *Self,
        parent: Self.NodeIndex,
        specification: @import("../layout/tree.zig").FlexLayout,
    ) !void {
        std.debug.assert(parent < self.node_count);
        std.debug.assert(specification.track_count > 0);
        const count = self.child_count(parent);
        if (count != specification.track_count) return error.ChildTrackMismatch;
        var rectangles: [@import("../utils/limits.zig").layout_items_max]Rect = undefined;
        const parent_node = &self.nodes[parent];
        try flex_layout.layout(
            parent_node.element.content_rect(),
            specification.direction,
            specification.gap,
            specification.tracks[0..specification.track_count],
            rectangles[0..count],
        );
        self.assign_child_rects(parent, rectangles[0..count]);
    }

    fn evaluate_grid(
        self: *Self,
        parent: Self.NodeIndex,
        specification: @import("../layout/tree.zig").GridLayout,
    ) !void {
        std.debug.assert(parent < self.node_count);
        std.debug.assert(specification.column_count > 0);
        std.debug.assert(specification.row_count > 0);
        const count = self.child_count(parent);
        const expected = @as(u16, specification.column_count) * specification.row_count;
        if (count != expected) return error.ChildTrackMismatch;
        var rectangles: [dom_nodes_max]Rect = undefined;
        const parent_node = &self.nodes[parent];
        try grid_layout.layout(
            parent_node.element.content_rect(),
            specification.column_gap,
            specification.row_gap,
            specification.columns[0..specification.column_count],
            specification.rows[0..specification.row_count],
            rectangles[0..count],
        );
        self.assign_child_rects(parent, rectangles[0..count]);
    }

    fn assign_child_rects(
        self: *Self,
        parent: Self.NodeIndex,
        rectangles: []const Rect,
    ) void {
        var child = self.nodes[parent].first_child;
        var index: u16 = 0;
        while (child) |child_index| : (index += 1) {
            std.debug.assert(index < rectangles.len);
            std.debug.assert(child_index > parent);
            self.nodes[child_index].element.layout.rect = rectangles[index];
            child = self.nodes[child_index].next_sibling;
        }
        std.debug.assert(index == rectangles.len);
    }
};

test "dirt does not climb to ancestors" {
    // A changed child must not force its parent to repaint: for a background
    // painting parent that would erase every sibling.
    var tree = Tree.init();
    const root = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.leaf(),
        .dirty = false,
    });
    const child = try tree.append_child(root, .{
        .kind = .label,
        .props = .{ .label = .{ .text = "hello" } },
        .layout = LayoutElement.leaf(),
        .dirty = false,
    });
    tree.clear_dirty();
    try std.testing.expectEqual(@as(u16, 0), tree.dirty_count);
    tree.mark_dirty(child);
    try std.testing.expect(tree.is_dirty(child));
    try std.testing.expect(!tree.is_dirty(root));
    try std.testing.expectEqual(@as(u16, 1), tree.dirty_count);
}

test "one changed row dirties only that row" {
    var tree = try row_tree(4);
    tree.clear_dirty();
    tree.set_props(2, .{ .list_item = .{ .title = "changed" } });
    tree.propagate_dirty();
    try std.testing.expectEqual(@as(u16, 1), tree.dirty_count);
    try std.testing.expect(tree.is_dirty(2));
    try std.testing.expect(!tree.is_dirty(0));
    try std.testing.expect(!tree.is_dirty(1));
    try std.testing.expect(!tree.is_dirty(3));
}

test "a dirty list repaints all of its rows" {
    // The list paints a background over its whole rect, so leaving rows clean
    // would blank them.
    var tree = try row_tree(4);
    tree.clear_dirty();
    tree.set_props(0, .{ .list = .{ .item_count = 4, .selected = 2 } });
    tree.propagate_dirty();
    try std.testing.expectEqual(@as(u16, 5), tree.dirty_count);
    var index: Tree.NodeIndex = 0;
    while (index < tree.node_count) : (index += 1) {
        try std.testing.expect(tree.is_dirty(index));
    }
}

test "set_props skips a repaint when rebuilt text is unchanged" {
    // Reformatting a string into fresh storage each frame yields a new pointer
    // with identical bytes. Comparing by identity would repaint every frame;
    // comparing by content correctly does nothing.
    var tree = Tree.init();
    _ = try tree.set_root(.{
        .kind = .label,
        .props = .{ .label = .{ .text = "same" } },
        .layout = LayoutElement.leaf(),
    });
    tree.clear_dirty();
    var rebuilt = [_]u8{ 's', 'a', 'm', 'e' };
    tree.set_props(0, .{ .label = .{ .text = rebuilt[0..] } });
    try std.testing.expect(!tree.is_dirty(0));
}

test "set_props repaints when rebuilt text differs" {
    var tree = Tree.init();
    _ = try tree.set_root(.{
        .kind = .label,
        .props = .{ .label = .{ .text = "one" } },
        .layout = LayoutElement.leaf(),
    });
    tree.clear_dirty();
    var rebuilt = [_]u8{ 't', 'w', 'o' };
    tree.set_props(0, .{ .label = .{ .text = rebuilt[0..] } });
    try std.testing.expect(tree.is_dirty(0));
}

test "text mutated in place behind a live slice needs an explicit mark_dirty" {
    // Props store a slice, not a copy, so the node's previous value aliases the
    // caller's buffer. Overwriting that buffer changes old and new together and
    // no comparison can see it. Callers that mutate in place must say so.
    var buffer = [_]u8{ 'o', 'n', 'e' };
    var tree = Tree.init();
    _ = try tree.set_root(.{
        .kind = .label,
        .props = .{ .label = .{ .text = buffer[0..] } },
        .layout = LayoutElement.leaf(),
    });
    tree.clear_dirty();
    buffer = [_]u8{ 't', 'w', 'o' };
    tree.set_props(0, .{ .label = .{ .text = buffer[0..] } });
    try std.testing.expect(!tree.is_dirty(0));
    tree.mark_dirty(0);
    try std.testing.expect(tree.is_dirty(0));
}

test "list rows stack at the configured row height" {
    var tree = try row_tree(3);
    try tree.evaluate(Rect.init(0, 0, 20, 6));
    try std.testing.expectEqual(Rect.init(0, 0, 20, 2), tree.get(1).?.rect());
    try std.testing.expectEqual(Rect.init(0, 2, 20, 2), tree.get(2).?.rect());
    try std.testing.expectEqual(Rect.init(0, 4, 20, 2), tree.get(3).?.rect());
}

test "rows past the bottom edge collapse instead of overflowing" {
    var tree = try row_tree(5);
    // Room for two rows of height 2 only.
    try tree.evaluate(Rect.init(0, 0, 20, 4));
    try std.testing.expectEqual(@as(u16, 20), tree.get(2).?.rect().width);
    try std.testing.expectEqual(@as(u16, 0), tree.get(3).?.rect().width);
    try std.testing.expectEqual(@as(u16, 0), tree.get(5).?.rect().height);
}

test "list rows are not limited by the flex track budget" {
    const many = @import("../utils/limits.zig").layout_items_max + 8;
    var tree = try row_tree(many);
    try tree.evaluate(Rect.init(0, 0, 20, 200));
    try std.testing.expectEqual(@as(u16, many + 1), tree.node_count);
    try std.testing.expectEqual(Rect.init(0, 2, 20, 2), tree.get(2).?.rect());
}

fn row_tree(rows: u16) !Tree {
    std.debug.assert(rows > 0);
    std.debug.assert(rows < dom_nodes_max);
    var tree = Tree.init();
    const list = try tree.set_root(.{
        .kind = .list,
        .props = .{ .list = .{ .item_count = rows, .visual = .{ .row_height = 2 } } },
        .layout = LayoutElement.leaf(),
    });
    var index: u16 = 0;
    while (index < rows) : (index += 1) {
        _ = try tree.append_child(list, .{
            .kind = .list_item,
            .props = .{ .list_item = .{ .title = "row" } },
            .layout = LayoutElement.leaf(),
        });
    }
    return tree;
}

test "moving the selection repaints two rows, not the list" {
    // The whole reason rows are nodes: highlighting a different one must cost
    // the two rows that changed, not the viewport.
    var tree = try row_tree(64);
    tree.clear_dirty();
    try std.testing.expect(tree.select_row(0, 7));
    try std.testing.expectEqual(@as(u16, 1), tree.dirty_count);
    try std.testing.expect(tree.is_dirty(8));

    tree.clear_dirty();
    try std.testing.expect(tree.select_row(0, 8));
    try std.testing.expectEqual(@as(u16, 2), tree.dirty_count);
    try std.testing.expect(tree.is_dirty(8));
    try std.testing.expect(tree.is_dirty(9));
    try std.testing.expect(!tree.is_dirty(0));
    try std.testing.expect(!tree.is_dirty(10));
}

test "the list and its rows agree about which row is selected" {
    var tree = try row_tree(4);
    try std.testing.expect(tree.select_row(0, 2));
    try std.testing.expectEqual(@as(u16, 2), tree.get(0).?.props.list.selected);
    try std.testing.expect(tree.get(3).?.props.list_item.selected);
    try std.testing.expect(!tree.get(2).?.props.list_item.selected);

    // A row that does not exist leaves the selection where it was.
    try std.testing.expect(!tree.select_row(0, 9));
    try std.testing.expectEqual(@as(u16, 2), tree.get(0).?.props.list.selected);
    // And a node that is not a list has no rows to select.
    try std.testing.expect(!tree.select_row(1, 0));
}

test "a node is found by the name it carries" {
    var tree = Tree.init();
    const root = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.stack(.column, 0),
    });
    _ = try tree.append_child(root, .{
        .kind = .heading,
        .props = .{ .heading = .{ .text = "One" } },
        .layout = LayoutElement.sized(1),
        .semantic = .{ .tag = .heading, .level = 2, .id = "one" },
    });
    const second = try tree.append_child(root, .{
        .kind = .heading,
        .props = .{ .heading = .{ .text = "Two" } },
        .layout = LayoutElement.sized(1),
        .semantic = .{ .tag = .heading, .level = 2, .id = "two" },
    });
    try std.testing.expectEqual(second, tree.find_by_id("two").?);
    // A name nothing carries, and the empty name, are both misses rather than
    // matching the first node that happens to have no name.
    try std.testing.expect(tree.find_by_id("three") == null);
    try std.testing.expect(tree.find_by_id("") == null);
    try std.testing.expect(tree.find_by_id("on") == null);
}

test "tree clear dirty resets all flags" {
    var tree = Tree.init();
    _ = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.leaf(),
    });
    tree.clear_dirty();
    try std.testing.expectEqual(@as(u16, 0), tree.dirty_count);
}

test "tree rejects duplicate root" {
    var tree = Tree.init();
    _ = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.leaf(),
    });
    try std.testing.expectError(error.RootAlreadySet, tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.leaf(),
    }));
}

test "tree set_props marks dirty on change" {
    var tree = Tree.init();
    const root = try tree.set_root(.{
        .kind = .label,
        .props = .{ .label = .{ .text = "a" } },
        .layout = LayoutElement.leaf(),
    });
    tree.clear_dirty();
    tree.set_props(root, .{ .label = .{ .text = "b" } });
    try std.testing.expect(tree.is_dirty(root));
}

test "tree set_props skips when unchanged" {
    var tree = Tree.init();
    const root = try tree.set_root(.{
        .kind = .label,
        .props = .{ .label = .{ .text = "a" } },
        .layout = LayoutElement.leaf(),
    });
    tree.clear_dirty();
    tree.set_props(root, .{ .label = .{ .text = "a" } });
    try std.testing.expect(!tree.is_dirty(root));
}

test "a wrapping label measures the rows its text needs" {
    var tree = Tree.init();
    const root = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.content_stack(.column, 0),
    });
    _ = try tree.append_child(root, .{
        .kind = .label,
        .props = .{ .label = .{
            .text = "the quick brown fox jumps over the lazy dog",
            .wrap = true,
        } },
        .layout = LayoutElement.content_sized(),
    });
    try tree.layout(Rect.init(0, 0, 20, 40));
    // 43 characters wrapped at 20 columns.
    try std.testing.expectEqual(
        text_measure.wrapped_rows("the quick brown fox jumps over the lazy dog", 20),
        tree.get(1).?.rect().height,
    );
    try std.testing.expect(tree.get(1).?.rect().height > 1);
}

test "a label that does not wrap stays one row" {
    var tree = Tree.init();
    const root = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.content_stack(.column, 0),
    });
    _ = try tree.append_child(root, .{
        .kind = .label,
        .props = .{ .label = .{ .text = "a very long line that would wrap if asked" } },
        .layout = LayoutElement.content_sized(),
    });
    try tree.layout(Rect.init(0, 0, 10, 40));
    try std.testing.expectEqual(@as(u16, 1), tree.get(1).?.rect().height);
}

test "a content stack grows to hold what it contains" {
    var tree = Tree.init();
    const root = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.content_stack(.column, 1),
    });
    const texts = [_][]const u8{
        "one two three four five six seven",
        "short",
        "eight nine ten eleven twelve thirteen fourteen",
    };
    for (texts) |value| {
        _ = try tree.append_child(root, .{
            .kind = .label,
            .props = .{ .label = .{ .text = value, .wrap = true } },
            .layout = LayoutElement.content_sized(),
        });
    }
    try tree.layout(Rect.init(0, 0, 16, 200));

    var expected: u16 = 0;
    for (texts) |value| expected += text_measure.wrapped_rows(value, 16);
    expected += 2; // two gaps between three children
    try std.testing.expectEqual(expected, tree.get(0).?.layout.extent);

    // Children follow one another without overlapping.
    var bottom: u16 = 0;
    var index: Tree.NodeIndex = 1;
    while (index < tree.node_count) : (index += 1) {
        const rect = tree.get(index).?.rect();
        try std.testing.expect(rect.y >= bottom);
        bottom = rect.y + rect.height;
    }
}

test "measured rows are the rows the terminal paints" {
    // The contract behind sharing the measurer: what layout reserves is what
    // the renderer fills, so wrapped text never spills past its node.
    const TerminalCanvas = @import("../backend/terminal/canvas.zig").TerminalCanvas;
    const Surface = @import("../widgets/surface.zig").Surface;
    const Label = @import("../widgets/label.zig").Label;
    const Color = @import("../style/color.zig").Color;
    const Style = @import("../style/style.zig").Style;

    var canvas = try TerminalCanvas.init(std.testing.allocator, 24, 40);
    defer canvas.deinit();
    const text = "the quick brown fox jumps over the lazy dog once more";

    var tree = Tree.init();
    const root = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.content_stack(.column, 0),
    });
    _ = try tree.append_child(root, .{
        .kind = .label,
        .props = .{ .label = .{ .text = text, .wrap = true } },
        .layout = LayoutElement.content_sized(),
    });
    try tree.layout(Rect.init(0, 0, 24, 20));
    const reserved = tree.get(1).?.rect().height;

    const style = Style.monochrome(
        Color.from_rgb(230, 230, 230),
        Color.from_rgb(0, 0, 0),
    );
    const surface = Surface{ .canvas = &canvas };
    // wrapped_text reports the rows it actually filled.
    const painted = try surface.wrapped_text(
        tree.get(1).?.rect(),
        text,
        style.foreground,
        style.background,
    );
    try std.testing.expectEqual(reserved, painted);
    _ = Label;
}

test "a list measures to its rows" {
    var tree = Tree.init();
    const root = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.content_stack(.column, 0),
    });
    _ = try tree.append_child(root, .{
        .kind = .list,
        .props = .{ .list = .{ .item_count = 7, .visual = .{ .row_height = 2 } } },
        .layout = LayoutElement.content_sized(),
    });
    try tree.layout(Rect.init(0, 0, 30, 40));
    try std.testing.expectEqual(@as(u16, 14), tree.get(1).?.layout.extent);
}

test "fixed sizing is left alone by the measure pass" {
    var tree = Tree.init();
    const root = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.stack(.column, 0),
    });
    _ = try tree.append_child(root, .{
        .kind = .label,
        .props = .{ .label = .{ .text = "wraps if measured", .wrap = true } },
        .layout = LayoutElement.sized(3),
    });
    try tree.layout(Rect.init(0, 0, 5, 40));
    try std.testing.expectEqual(@as(u16, 3), tree.get(1).?.rect().height);
}

test "stack places children by the extent each declares" {
    var tree = Tree.init();
    const root = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.stack(.column, 1),
    });
    const heights = [_]u16{ 1, 3, 2 };
    for (heights) |height| {
        _ = try tree.append_child(root, .{
            .kind = .label,
            .props = .{ .label = .{ .text = "x" } },
            .layout = LayoutElement.sized(height),
        });
    }
    try tree.evaluate(Rect.init(0, 0, 40, 20));
    try std.testing.expectEqual(Rect.init(0, 0, 40, 1), tree.get(1).?.rect());
    try std.testing.expectEqual(Rect.init(0, 2, 40, 3), tree.get(2).?.rect());
    try std.testing.expectEqual(Rect.init(0, 6, 40, 2), tree.get(3).?.rect());
}

test "a free container is as tall as the children placed in it" {
    // A block of prose flowed into rows ahead of layout: the rows know where
    // they go, and the block has to be given room for them. Measuring it from
    // its own text instead would answer at a different width than the flow
    // used, and the two would not agree.
    var tree = Tree.init();
    const root = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.content_stack(.column, 0),
    });
    const block = try tree.append_child(root, .{
        .kind = .label,
        .props = .{ .label = .{ .text = "flowed elsewhere", .wrap = true } },
        .layout = LayoutElement.content_free(),
    });
    const rows = [_]u16{ 0, 1, 2 };
    for (rows) |row| {
        _ = try tree.append_child(block, .{
            .kind = .label,
            .props = .{ .label = .{ .text = "row" } },
            .layout = LayoutElement.placed(0, row, 3, 1),
        });
    }

    try tree.layout(Rect.init(0, 0, 40, 20));
    try std.testing.expectEqual(@as(u16, 3), tree.get(block).?.rect().height);
    // And the rows survive: a block measured at zero clips them all away.
    try std.testing.expectEqual(Rect.init(0, 0, 3, 1), tree.get(block + 1).?.rect());
    try std.testing.expectEqual(Rect.init(0, 2, 3, 1), tree.get(block + 3).?.rect());
}

test "a free container with no room for a child clips it, not the block" {
    var tree = Tree.init();
    const root = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.content_stack(.column, 0),
    });
    const block = try tree.append_child(root, .{
        .kind = .label,
        .props = .{ .label = .{ .text = "x" } },
        .layout = LayoutElement.content_free(),
    });
    _ = try tree.append_child(block, .{
        .kind = .label,
        .props = .{ .label = .{ .text = "wide" } },
        .layout = LayoutElement.placed(0, 0, 400, 1),
    });
    try tree.layout(Rect.init(0, 0, 10, 4));
    try std.testing.expectEqual(@as(u16, 1), tree.get(block).?.rect().height);
    try std.testing.expectEqual(@as(u16, 10), tree.get(block + 1).?.rect().width);
}

test "stack is not bound by the flex track budget" {
    // The reason stack exists: a document has as many blocks as it has, and
    // flex would cap that at layout_items_max.
    const many = @import("../utils/limits.zig").layout_items_max * 8;
    var tree = Tree.init();
    const root = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.stack(.column, 0),
    });
    var index: u16 = 0;
    while (index < many) : (index += 1) {
        _ = try tree.append_child(root, .{
            .kind = .label,
            .props = .{ .label = .{ .text = "line" } },
            .layout = LayoutElement.sized(1),
        });
    }
    try tree.evaluate(Rect.init(0, 0, 40, many));
    try std.testing.expectEqual(@as(u16, many + 1), tree.node_count);
    try std.testing.expectEqual(Rect.init(0, many - 1, 40, 1), tree.get(many).?.rect());
}

test "stack clips a child that runs past the container" {
    var tree = Tree.init();
    const root = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.stack(.column, 0),
    });
    _ = try tree.append_child(root, .{
        .kind = .label,
        .props = .{ .label = .{ .text = "a" } },
        .layout = LayoutElement.sized(4),
    });
    _ = try tree.append_child(root, .{
        .kind = .label,
        .props = .{ .label = .{ .text = "b" } },
        .layout = LayoutElement.sized(10),
    });
    try tree.evaluate(Rect.init(0, 0, 40, 6));
    try std.testing.expectEqual(@as(u16, 4), tree.get(1).?.rect().height);
    // Only two rows remain, so the second child is clipped rather than
    // overflowing the container.
    try std.testing.expectEqual(@as(u16, 2), tree.get(2).?.rect().height);
}

test "stack runs along a row when asked" {
    var tree = Tree.init();
    const root = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.stack(.row, 2),
    });
    _ = try tree.append_child(root, .{
        .kind = .badge,
        .props = .{ .badge = .{ .text = "one" } },
        .layout = LayoutElement.sized(5),
    });
    _ = try tree.append_child(root, .{
        .kind = .badge,
        .props = .{ .badge = .{ .text = "two" } },
        .layout = LayoutElement.sized(6),
    });
    try tree.evaluate(Rect.init(0, 0, 40, 3));
    try std.testing.expectEqual(Rect.init(0, 0, 5, 3), tree.get(1).?.rect());
    try std.testing.expectEqual(Rect.init(7, 0, 6, 3), tree.get(2).?.rect());
}

test "a panel stacking its children still insets them" {
    const panel_widget = @import("../widgets/panel.zig");
    const chrome = panel_widget.Chrome{
        .rail_width = 1,
        .content_padding_left = 2,
        .content_padding_top = 1,
    };
    var tree = Tree.init();
    const root = try tree.set_root(.{
        .kind = .panel,
        .props = .{ .panel = .{ .chrome = chrome } },
        .layout = LayoutElement.stack(.column, 0),
    });
    _ = try tree.append_child(root, .{
        .kind = .label,
        .props = .{ .label = .{ .text = "inside" } },
        .layout = LayoutElement.sized(1),
    });
    try tree.evaluate(Rect.init(0, 0, 30, 10));
    try std.testing.expectEqual(Rect.init(3, 1, 27, 1), tree.get(1).?.rect());
}

test "panel children are laid out inside the panel content rect" {
    const panel_widget = @import("../widgets/panel.zig");
    const chrome = panel_widget.Chrome{
        .rail_width = 1,
        .content_padding_left = 2,
        .content_padding_top = 1,
    };
    var tree = Tree.init();
    const root = try tree.set_root(.{
        .kind = .panel,
        .props = .{ .panel = .{ .chrome = chrome, .title = "Feeds" } },
        .layout = try LayoutElement.flex(.column, 0, &.{.{ .fraction = 1 }}),
    });
    _ = try tree.append_child(root, .{
        .kind = .list,
        .props = .{ .list = .{} },
        .layout = LayoutElement.leaf(),
    });
    const bounds = Rect.init(0, 0, 30, 10);
    try tree.evaluate(bounds);
    // The child fills the chrome-inset box, not the panel's outer rect.
    const expected = panel_widget.content_rect(chrome, bounds);
    try std.testing.expectEqual(expected, tree.get(1).?.rect());
    try std.testing.expectEqual(Rect.init(3, 1, 27, 9), tree.get(1).?.rect());
    try std.testing.expectEqual(bounds, tree.get(root).?.rect());
}

test "non panel containers lay children out over their whole rect" {
    var tree = Tree.init();
    const root = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = try LayoutElement.flex(.column, 0, &.{.{ .fraction = 1 }}),
    });
    _ = try tree.append_child(root, .{
        .kind = .label,
        .props = .{ .label = .{ .text = "x" } },
        .layout = LayoutElement.leaf(),
    });
    const bounds = Rect.init(0, 0, 30, 10);
    try tree.evaluate(bounds);
    try std.testing.expectEqual(bounds, tree.get(1).?.rect());
}

test "tree evaluates flex layout" {
    var tree = Tree.init();
    const root = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = try LayoutElement.flex(.row, 0, &.{.{ .fraction = 1 }}),
    });
    _ = try tree.append_child(root, .{
        .kind = .label,
        .props = .{ .label = .{ .text = "hi" } },
        .layout = LayoutElement.leaf(),
    });
    try tree.evaluate(Rect.init(0, 0, 20, 10));
    const child_rect = tree.get(1).?.rect();
    try std.testing.expectEqual(Rect.init(0, 0, 20, 10), child_rect);
}
