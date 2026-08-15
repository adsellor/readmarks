const std = @import("std");
const flex_layout = @import("flex.zig");
const grid_layout = @import("grid.zig");
const limits = @import("../utils/limits.zig");
const Rect = @import("rect.zig").Rect;

pub fn Tree(comptime Element: type) type {
    return struct {
        const Self = @This();
        pub const NodeIndex = u16;

        pub const Node = struct {
            element: Element,
            parent: ?Self.NodeIndex = null,
            first_child: ?Self.NodeIndex = null,
            last_child: ?Self.NodeIndex = null,
            next_sibling: ?Self.NodeIndex = null,
        };

        nodes: [limits.layout_nodes_max]Node = undefined,
        node_count: Self.NodeIndex = 0,
        root: ?Self.NodeIndex = null,

        pub fn init() Self {
            return .{};
        }

        pub fn reset(self: *Self) void {
            self.node_count = 0;
            self.root = null;
        }

        pub fn set_root(self: *Self, element: Element) !Self.NodeIndex {
            if (self.root != null) return error.RootAlreadySet;
            const index = try self.append_node(element, null);
            self.root = index;
            return index;
        }

        pub fn append_child(
            self: *Self,
            parent_index: Self.NodeIndex,
            element: Element,
        ) !Self.NodeIndex {
            std.debug.assert(self.node_count <= limits.layout_nodes_max);
            if (parent_index >= self.node_count) return error.InvalidParent;
            const child_index = try self.append_node(element, parent_index);
            // Every pass relies on this: a child is reached after the parent
            // that contains it, so one ascending walk is parent-before-child.
            std.debug.assert(child_index > parent_index);
            const parent = &self.nodes[parent_index];
            if (parent.last_child) |last_child| {
                self.nodes[last_child].next_sibling = child_index;
            } else {
                parent.first_child = child_index;
            }
            parent.last_child = child_index;
            return child_index;
        }

        pub fn get(self: *Self, index: Self.NodeIndex) ?*Node {
            if (index >= self.node_count) return null;
            return &self.nodes[index];
        }

        pub fn child_count(
            self: *const Self,
            parent_index: Self.NodeIndex,
        ) Self.NodeIndex {
            if (parent_index >= self.node_count) return 0;
            var count: Self.NodeIndex = 0;
            var child = self.nodes[parent_index].first_child;
            while (child) |index| : (count += 1) {
                std.debug.assert(count < self.node_count);
                std.debug.assert(index < self.node_count);
                child = self.nodes[index].next_sibling;
            }
            return count;
        }

        fn append_node(
            self: *Self,
            element: Element,
            parent: ?Self.NodeIndex,
        ) !Self.NodeIndex {
            if (self.node_count >= limits.layout_nodes_max) return error.TreeFull;
            const index = self.node_count;
            self.nodes[index] = .{ .element = element, .parent = parent };
            self.node_count += 1;
            return index;
        }
    };
}

pub const FlexLayout = struct {
    direction: flex_layout.Direction,
    gap: u16,
    tracks: [limits.layout_items_max]flex_layout.Track = undefined,
    track_count: u8,
};

pub const GridLayout = struct {
    column_gap: u16,
    row_gap: u16,
    columns: [limits.layout_items_max]flex_layout.Track = undefined,
    column_count: u8,
    rows: [limits.layout_items_max]flex_layout.Track = undefined,
    row_count: u8,
};

/// Stacks children one after another along an axis, each taking the extent it
/// declares for itself.
///
/// Flex sizes children from the container down, which needs one track per
/// child and so is capped at `layout_items_max`. A document is the other way
/// around: the number of blocks is data, and each block knows its own height.
/// Stack carries no per-child data, so a container can hold as many children
/// as the tree has room for.
pub const Sizing = enum { fixed, content };

pub const Placement = struct {
    x: u16 = 0,
    y: u16 = 0,
    width: u16 = 0,
    height: u16 = 1,
};

pub const StackLayout = struct {
    direction: flex_layout.Direction,
    gap: u16 = 0,
};

pub const LayoutElement = struct {
    kind: union(enum) {
        leaf: void,
        flex: FlexLayout,
        grid: GridLayout,
        stack: StackLayout,
        /// Children are placed where they say, relative to this node.
        free: void,
    },
    rect: Rect = Rect.init(0, 0, 0, 0),
    /// Offset and size a child declares for itself, honoured only when its
    /// parent is `.free`. This is how content that has already been resolved
    /// elsewhere -- text flowed into rows and columns, an overlay pinned to a
    /// corner -- states a position the engine should keep rather than compute.
    placement: Placement = .{},
    /// Size along the parent's stack axis. Read only when the parent is a
    /// stack; ignored by flex and grid, which size their children themselves.
    extent: u16 = 0,
    /// Where `extent` comes from. `.fixed` keeps whatever was declared;
    /// `.content` has the measure pass derive it from what the node holds.
    sizing: Sizing = .fixed,

    pub fn leaf() LayoutElement {
        return .{ .kind = .{ .leaf = {} } };
    }

    /// A leaf that declares its own extent, for use inside a stack.
    pub fn sized(extent: u16) LayoutElement {
        return .{ .kind = .{ .leaf = {} }, .extent = extent };
    }

    /// A leaf whose extent the measure pass derives from its content.
    pub fn content_sized() LayoutElement {
        return .{ .kind = .{ .leaf = {} }, .sizing = .content };
    }

    /// A container that keeps its children where they place themselves.
    pub fn free() LayoutElement {
        return .{ .kind = .{ .free = {} } };
    }

    /// A free container as tall as the children placed inside it.
    ///
    /// Without this a free container declares no extent, so a stack gives it no
    /// room and the children it was holding are clipped away to nothing -- the
    /// content is placed correctly and then cropped out of existence.
    pub fn content_free() LayoutElement {
        return .{ .kind = .{ .free = {} }, .sizing = .content };
    }

    /// A leaf at a declared offset and size, for use inside a `.free` parent.
    pub fn placed(x: u16, y: u16, width: u16, height: u16) LayoutElement {
        std.debug.assert(height > 0);
        return .{
            .kind = .{ .leaf = {} },
            .placement = .{ .x = x, .y = y, .width = width, .height = height },
        };
    }

    /// A placed container: it sits where it says and its children do too.
    /// Lets a run of text broken across rows stay one element with a fragment
    /// per row, rather than becoming several elements that merely look alike.
    pub fn placed_free(x: u16, y: u16, width: u16, height: u16) LayoutElement {
        std.debug.assert(height > 0);
        return .{
            .kind = .{ .free = {} },
            .placement = .{ .x = x, .y = y, .width = width, .height = height },
        };
    }

    pub fn stack(direction: flex_layout.Direction, gap: u16) LayoutElement {
        return .{ .kind = .{ .stack = .{ .direction = direction, .gap = gap } } };
    }

    /// A stack that grows to hold its children.
    pub fn content_stack(direction: flex_layout.Direction, gap: u16) LayoutElement {
        return .{
            .kind = .{ .stack = .{ .direction = direction, .gap = gap } },
            .sizing = .content,
        };
    }

    pub fn flex(
        direction: flex_layout.Direction,
        gap: u16,
        tracks: []const flex_layout.Track,
    ) !LayoutElement {
        if (tracks.len == 0) return error.NoTracks;
        if (tracks.len > limits.layout_items_max) return error.TooManyTracks;
        std.debug.assert(tracks.len > 0);
        std.debug.assert(tracks.len <= limits.layout_items_max);
        var specification = FlexLayout{
            .direction = direction,
            .gap = gap,
            .track_count = @intCast(tracks.len),
        };
        @memcpy(specification.tracks[0..tracks.len], tracks);
        return .{ .kind = .{ .flex = specification } };
    }

    pub fn grid(
        column_gap: u16,
        row_gap: u16,
        columns: []const flex_layout.Track,
        rows: []const flex_layout.Track,
    ) !LayoutElement {
        if (columns.len == 0 or rows.len == 0) return error.NoTracks;
        if (columns.len > limits.layout_items_max) return error.TooManyTracks;
        if (rows.len > limits.layout_items_max) return error.TooManyTracks;
        const cell_count = std.math.mul(usize, columns.len, rows.len) catch
            return error.TooManyCells;
        if (cell_count > limits.layout_nodes_max - 1) return error.TooManyCells;
        std.debug.assert(cell_count > 0);
        std.debug.assert(cell_count == columns.len * rows.len);
        var specification = GridLayout{
            .column_gap = column_gap,
            .row_gap = row_gap,
            .column_count = @intCast(columns.len),
            .row_count = @intCast(rows.len),
        };
        @memcpy(specification.columns[0..columns.len], columns);
        @memcpy(specification.rows[0..rows.len], rows);
        return .{ .kind = .{ .grid = specification } };
    }
};

pub const LayoutTree = Tree(LayoutElement);
pub const LayoutNodeIndex = LayoutTree.NodeIndex;

pub fn evaluate(tree: *LayoutTree, bounds: Rect) !void {
    const root_index = tree.root orelse return error.MissingRoot;
    std.debug.assert(root_index == 0);
    std.debug.assert(root_index < tree.node_count);
    tree.nodes[root_index].element.rect = bounds;
    var index: LayoutNodeIndex = 0;
    while (index < tree.node_count) : (index += 1) {
        const kind = tree.nodes[index].element.kind;
        switch (kind) {
            .leaf => if (tree.nodes[index].first_child != null) {
                return error.LeafHasChildren;
            },
            .flex => |specification| try evaluate_flex(tree, index, specification),
            .grid => |specification| try evaluate_grid(tree, index, specification),
            .stack => |specification| evaluate_stack(tree, index, specification),
            .free => evaluate_free(tree, index),
        }
    }
}

/// Keeps children where they placed themselves, relative to the container.
fn evaluate_free(tree: *LayoutTree, parent_index: LayoutNodeIndex) void {
    std.debug.assert(parent_index < tree.node_count);
    const container = tree.nodes[parent_index].element.rect;
    var child = tree.nodes[parent_index].first_child;
    while (child) |child_index| {
        std.debug.assert(child_index > parent_index);
        const element = &tree.nodes[child_index].element;
        const place = element.placement;
        element.rect = Rect.init(
            container.x +| place.x,
            container.y +| place.y,
            @min(place.width, container.width -| place.x),
            @min(place.height, container.height -| place.y),
        );
        child = tree.nodes[child_index].next_sibling;
    }
}

/// Places children end to end along the stack axis, each taking its declared
/// extent and the container's full width across the other axis. A child that
/// runs past the container is clipped to zero rather than overflowing.
fn evaluate_stack(
    tree: *LayoutTree,
    parent_index: LayoutNodeIndex,
    specification: StackLayout,
) void {
    std.debug.assert(parent_index < tree.node_count);
    const container = tree.nodes[parent_index].element.rect;
    var child = tree.nodes[parent_index].first_child;
    var offset: u16 = 0;
    while (child) |child_index| {
        std.debug.assert(child_index > parent_index);
        const element = &tree.nodes[child_index].element;
        element.rect = stack_rect(container, specification.direction, offset, element.extent);
        offset +|= element.extent +| specification.gap;
        child = tree.nodes[child_index].next_sibling;
    }
}

pub fn stack_rect(
    container: Rect,
    direction: flex_layout.Direction,
    offset: u16,
    extent: u16,
) Rect {
    // A child never starts outside the box that holds it; it is clipped to
    // nothing at the edge instead, which is what the callers rely on to keep
    // an overlong stack inside its container.
    std.debug.assert(container.width < std.math.maxInt(u16));
    std.debug.assert(container.height < std.math.maxInt(u16));
    if (direction == .column) {
        const available = container.height -| offset;
        return Rect.init(
            container.x,
            container.y +| offset,
            container.width,
            @min(extent, available),
        );
    }
    const available = container.width -| offset;
    return Rect.init(
        container.x +| offset,
        container.y,
        @min(extent, available),
        container.height,
    );
}

fn evaluate_flex(
    tree: *LayoutTree,
    parent_index: LayoutNodeIndex,
    specification: FlexLayout,
) !void {
    std.debug.assert(parent_index < tree.node_count);
    std.debug.assert(specification.track_count > 0);
    const count = tree.child_count(parent_index);
    if (count != specification.track_count) return error.ChildTrackMismatch;
    var rectangles: [limits.layout_items_max]Rect = undefined;
    const parent = &tree.nodes[parent_index];
    try flex_layout.layout(
        parent.element.rect,
        specification.direction,
        specification.gap,
        specification.tracks[0..specification.track_count],
        rectangles[0..count],
    );
    assign_children(tree, parent_index, rectangles[0..count]);
}

fn evaluate_grid(
    tree: *LayoutTree,
    parent_index: LayoutNodeIndex,
    specification: GridLayout,
) !void {
    std.debug.assert(parent_index < tree.node_count);
    std.debug.assert(specification.column_count > 0);
    std.debug.assert(specification.row_count > 0);
    const count = tree.child_count(parent_index);
    const expected = @as(u16, specification.column_count) * specification.row_count;
    if (count != expected) return error.ChildTrackMismatch;
    var rectangles: [limits.layout_nodes_max]Rect = undefined;
    const parent = &tree.nodes[parent_index];
    try grid_layout.layout(
        parent.element.rect,
        specification.column_gap,
        specification.row_gap,
        specification.columns[0..specification.column_count],
        specification.rows[0..specification.row_count],
        rectangles[0..count],
    );
    assign_children(tree, parent_index, rectangles[0..count]);
}

fn assign_children(
    tree: *LayoutTree,
    parent_index: LayoutNodeIndex,
    rectangles: []const Rect,
) void {
    var child = tree.nodes[parent_index].first_child;
    var index: u16 = 0;
    while (child) |child_index| : (index += 1) {
        std.debug.assert(index < rectangles.len);
        std.debug.assert(child_index > parent_index);
        tree.nodes[child_index].element.rect = rectangles[index];
        child = tree.nodes[child_index].next_sibling;
    }
    std.debug.assert(index == rectangles.len);
}

test "layout tree evaluates nested flex and grid containers" {
    var tree = LayoutTree.init();
    const root = try tree.set_root(try LayoutElement.flex(
        .column,
        0,
        &.{ .{ .cells = 2 }, .{ .fraction = 1 } },
    ));
    _ = try tree.append_child(root, LayoutElement.leaf());
    const content = try tree.append_child(root, try LayoutElement.grid(
        1,
        0,
        &.{ .{ .fraction = 1 }, .{ .fraction = 1 } },
        &.{.{ .fraction = 1 }},
    ));
    const left = try tree.append_child(content, LayoutElement.leaf());
    const right = try tree.append_child(content, LayoutElement.leaf());
    try evaluate(&tree, Rect.init(0, 0, 21, 10));
    try std.testing.expectEqual(Rect.init(0, 2, 10, 8), tree.get(left).?.element.rect);
    try std.testing.expectEqual(Rect.init(11, 2, 10, 8), tree.get(right).?.element.rect);
}

test "layout tree rejects mismatched children and bounded overflow" {
    var tree = LayoutTree.init();
    const root = try tree.set_root(try LayoutElement.flex(
        .row,
        0,
        &.{.{ .fraction = 1 }},
    ));
    try std.testing.expectError(
        error.ChildTrackMismatch,
        evaluate(&tree, Rect.init(0, 0, 10, 2)),
    );
    _ = try tree.append_child(root, LayoutElement.leaf());
    while (tree.node_count < limits.layout_nodes_max) {
        _ = try tree.append_child(root, LayoutElement.leaf());
    }
    try std.testing.expectError(
        error.TreeFull,
        tree.append_child(root, LayoutElement.leaf()),
    );
}
