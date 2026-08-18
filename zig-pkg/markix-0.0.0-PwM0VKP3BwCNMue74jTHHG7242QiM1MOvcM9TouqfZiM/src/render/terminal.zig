const std = @import("std");
const DomTree = @import("../dom/tree.zig").Tree;
const DomNode = @import("../dom/node.zig").DomNode;
const NodeKind = @import("../dom/node.zig").NodeKind;
const ButtonProps = @import("../dom/node.zig").ButtonProps;
const TerminalCanvas = @import("../backend/terminal/canvas.zig").TerminalCanvas;
const Surface = @import("../widgets/surface.zig").Surface;
const Label = @import("../widgets/label.zig").Label;
const Heading = @import("../widgets/heading.zig").Heading;
const Rule = @import("../widgets/rule.zig").Rule;
const CodeBlock = @import("../widgets/code_block.zig").CodeBlock;
const Badge = @import("../widgets/badge.zig").Badge;
const List = @import("../widgets/list.zig").List;
const Panel = @import("../widgets/panel.zig").Panel;
const Segmented = @import("../widgets/segmented.zig").Segmented;
const StatusLine = @import("../widgets/status_line.zig").StatusLine;
const Image = @import("../widgets/image.zig").Image;
const text_input = @import("../widgets/text_input.zig");
const Color = @import("../style/color.zig").Color;
const Rect = @import("../layout/rect.zig").Rect;
const Style = @import("../style/style.zig").Style;

pub const Renderer = struct {
    canvas: *TerminalCanvas,
    background: Color,
    /// Nodes painted during the last `paint`, for tests and instrumentation.
    painted: u16 = 0,

    pub fn init(canvas: *TerminalCanvas, background: Color) Renderer {
        return .{ .canvas = canvas, .background = background };
    }

    /// Establishes this frame from the previous one.
    ///
    /// Split out from `paint` so a caller can clear regions, paint several
    /// trees, or mix in drawing the DOM does not own yet -- all against one
    /// frame. Callers doing that must `begin` exactly once per frame.
    pub fn begin(self: *Renderer) void {
        self.painted = 0;
        self.canvas.start_partial_frame(self.background);
    }

    pub fn paint(self: *Renderer, tree: *DomTree) !void {
        // The frame is established even when nothing is dirty. Committing a
        // frame that was never started would hand the canvas an empty text
        // list as the new baseline, stranding glyphs already on screen with
        // nothing left to diff them against.
        self.begin();
        try self.paint_tree(tree);
    }

    pub fn paint_tree(self: *Renderer, tree: *DomTree) !void {
        std.debug.assert(tree.node_count <= @import("../dom/tree.zig").dom_nodes_max);
        if (tree.dirty_count == 0) return;
        std.debug.assert(tree.root != null);
        // Widen dirt to children a repainting background would erase, then
        // paint only what is dirty. The canvas diffs the result against the
        // previous frame, so untouched cells cost no terminal output.
        tree.propagate_dirty();
        // Ascending index is parent-before-child (append_child asserts it), so
        // container chrome lands under the children drawn into its content box.
        var index: DomTree.NodeIndex = 0;
        while (index < tree.node_count) : (index += 1) {
            if (!tree.is_dirty(index)) continue;
            const node = tree.get(index).?;
            const rect = node.rect();
            if (rect.width == 0 or rect.height == 0) continue;
            self.canvas.clear_rect(rect, self.clear_color(tree, index));
            try self.paint_node(tree, index, node, rect);
            self.painted += 1;
        }
        // Painting consumes the dirt. Without this a node stays dirty for
        // every later frame and the tree repaints itself forever.
        tree.clear_dirty();
    }

    /// Colour a node's rect is cleared to before it paints.
    ///
    /// A node sits on whatever its ancestors laid down, so clearing to the
    /// global background would punch a hole in the panel holding it -- and
    /// repainting one node while the surface around it survives is the whole
    /// point of the tree. Widgets that fill their own rect are unaffected;
    /// the ones that only draw glyphs, a label above all, are the ones this
    /// keeps on their own background.
    fn clear_color(self: *Renderer, tree: *DomTree, index: DomTree.NodeIndex) Color {
        std.debug.assert(index < tree.node_count);
        var current = index;
        while (tree.parent_index(current)) |parent| {
            std.debug.assert(parent < current);
            if (surface_background(tree.get(parent).?)) |color| return color;
            current = parent;
        }
        return self.background;
    }

    /// The background a node lays down across its whole rect, if it lays one.
    fn surface_background(node: *DomNode) ?Color {
        return switch (node.kind) {
            .panel => node.props.panel.style.background,
            .list => node.props.list.style.background,
            else => null,
        };
    }

    fn paint_node(
        self: *Renderer,
        tree: *DomTree,
        index: DomTree.NodeIndex,
        node: *DomNode,
        rect: Rect,
    ) !void {
        std.debug.assert(index < tree.node_count);
        std.debug.assert(rect.width > 0);
        const surface = Surface{ .canvas = self.canvas };
        switch (node.kind) {
            .container => {},
            .label => try paint_label(surface, node, rect),
            .heading => try paint_heading(surface, node, rect),
            .rule => try paint_rule(surface, node, rect),
            .code_block => try paint_code_block(surface, node, rect),
            .badge => try paint_badge(surface, node, rect),
            .button => try paint_button(surface, node, rect),
            .list => try paint_list(surface, node, rect),
            .list_item => try paint_list_item(surface, tree, index, node, rect),
            .panel => try paint_panel(surface, node, rect),
            .text_input => try paint_text_input(surface, node, rect),
            .segmented => try paint_segmented(surface, node, rect),
            .status_line => try paint_status_line(surface, node, rect),
            .image => try paint_image(surface, node, rect),
        }
    }

    fn paint_label(surface: Surface, node: *DomNode, rect: Rect) !void {
        const props = node.props.label;
        try (Label{
            .text = props.text,
            .style = props.style,
            .muted = props.muted,
            .wrap = props.wrap,
        }).draw(surface, rect);
    }

    fn paint_heading(surface: Surface, node: *DomNode, rect: Rect) !void {
        const props = node.props.heading;
        try (Heading{
            .text = props.text,
            .level = props.level,
            .style = props.style,
            .visual = props.visual,
        }).draw(surface, rect);
    }

    fn paint_rule(surface: Surface, node: *DomNode, rect: Rect) !void {
        const props = node.props.rule;
        try (Rule{ .style = props.style, .visual = props.visual }).draw(surface, rect);
    }

    fn paint_code_block(surface: Surface, node: *DomNode, rect: Rect) !void {
        const props = node.props.code_block;
        try (CodeBlock{
            .text = props.text,
            .language = props.language,
            .style = props.style,
            .visual = props.visual,
        }).draw(surface, rect);
    }

    fn paint_badge(surface: Surface, node: *DomNode, rect: Rect) !void {
        const props = node.props.badge;
        _ = try (Badge{ .style = props.style }).draw(surface, rect, props.text);
    }

    fn paint_button(surface: Surface, node: *DomNode, rect: Rect) !void {
        std.debug.assert(node.kind == .button);
        std.debug.assert(rect.width > 0);
        const props = node.props.button;
        const bg = button_background(node, props);
        const fg = button_foreground(node, props);
        surface.fill(rect, bg);
        const text_len = @min(props.text.len, rect.width);
        if (text_len == 0) return;
        try surface.styled_text(
            rect.x + props.padding,
            rect.y,
            props.text[0..text_len],
            .{
                .foreground = fg,
                .background = bg,
                .attributes = props.attributes,
            },
        );
    }

    /// Paints only the list's own surface. Rows are `list_item` children and
    /// repaint independently, so a single changed row never redraws the rest.
    fn paint_list(surface: Surface, node: *DomNode, rect: Rect) !void {
        const props = node.props.list;
        surface.fill(rect, props.style.background);
        if (props.item_count > 0) return;
        try surface.text_in(
            rect,
            0,
            props.empty_text,
            props.style.muted,
            props.style.background,
        );
    }

    fn paint_list_item(
        surface: Surface,
        tree: *DomTree,
        index: DomTree.NodeIndex,
        node: *DomNode,
        rect: Rect,
    ) !void {
        std.debug.assert(node.kind == .list_item);
        std.debug.assert(index < tree.node_count);
        const props = node.props.list_item;
        const owner = list_owner(tree, index) orelse return;
        const list = owner.props.list;
        try (List{
            .style = list.style,
            .empty_text = list.empty_text,
            .highlight_query = list.highlight_query,
            .match_foreground = list.match_foreground,
            .focused = owner.focused,
            .visual = list.visual,
        }).draw_row(surface, rect, props.item(), props.selected);
    }

    /// Rows inherit presentation from the list they are mounted in.
    fn list_owner(tree: *DomTree, index: DomTree.NodeIndex) ?*DomNode {
        const parent = tree.parent_index(index) orelse return null;
        const node = tree.get(parent) orelse return null;
        if (node.kind != .list) return null;
        return node;
    }

    fn paint_panel(surface: Surface, node: *DomNode, rect: Rect) !void {
        const props = node.props.panel;
        // Children already own the content rect from layout; the panel only
        // paints its own chrome here.
        _ = try (Panel{
            .title = props.title,
            .meta = props.meta,
            .style = props.style,
            .focused = node.focused,
            .chrome = props.chrome,
        }).draw(surface, rect);
    }

    fn paint_text_input(surface: Surface, node: *DomNode, rect: Rect) !void {
        const props = node.props.text_input;
        const view = props.view();
        try text_input.draw(&view, surface, rect, props.options(node.focused));
    }

    fn paint_segmented(surface: Surface, node: *DomNode, rect: Rect) !void {
        const props = node.props.segmented;
        _ = try (Segmented{
            .active_style = props.active_style,
            .idle_style = props.idle_style,
            .gap = props.gap,
        }).draw(surface, rect, props.items, props.selected);
    }

    fn paint_status_line(surface: Surface, node: *DomNode, rect: Rect) !void {
        const props = node.props.status_line;
        try (StatusLine{
            .style = props.style,
            .visual = props.visual,
        }).draw(surface, rect, props.message, props.hints);
    }

    fn paint_image(surface: Surface, node: *DomNode, rect: Rect) !void {
        const props = node.props.image;
        if (props.path.len == 0) return;
        _ = try (Image{
            .path = props.path,
            .id = props.id,
            .crop_top_rows = props.crop_top_rows,
            .full_height_rows = if (props.full_height_rows == 0)
                rect.height
            else
                props.full_height_rows,
        }).draw(surface, rect);
    }

    fn button_background(node: *DomNode, props: ButtonProps) Color {
        if (node.focused) return props.focus_background;
        if (node.hovered) return props.hover_background;
        return props.background;
    }

    fn button_foreground(node: *DomNode, props: ButtonProps) Color {
        if (node.focused) return props.focus_foreground;
        return props.foreground;
    }
};

const test_foreground = Color.from_rgb(230, 230, 230);
const test_background = Color.from_rgb(20, 22, 24);

fn test_style() Style {
    return Style.monochrome(test_foreground, test_background);
}

fn leaf_at(rect: Rect) @import("../layout/tree.zig").LayoutElement {
    return .{ .kind = .{ .leaf = {} }, .rect = rect };
}

test "renderer skips when no dirty nodes" {
    var canvas = try TerminalCanvas.init(std.testing.allocator, 20, 4);
    defer canvas.deinit();
    var tree = DomTree.init();
    _ = try tree.set_root(.{
        .kind = .label,
        .props = .{ .label = .{ .text = "hi" } },
        .layout = leaf_at(Rect.init(0, 0, 5, 1)),
    });
    tree.clear_dirty();
    var renderer = Renderer.init(&canvas, test_background);
    try renderer.paint(&tree);
    try std.testing.expectEqual(@as(usize, 0), canvas.text_entries.items.len);
}

test "renderer paints dirty label" {
    var canvas = try TerminalCanvas.init(std.testing.allocator, 20, 4);
    defer canvas.deinit();
    var tree = DomTree.init();
    _ = try tree.set_root(.{
        .kind = .label,
        .props = .{ .label = .{ .text = "hello", .style = test_style() } },
        .layout = leaf_at(Rect.init(0, 0, 10, 1)),
    });
    var renderer = Renderer.init(&canvas, test_background);
    try renderer.paint(&tree);
    try std.testing.expect(canvas.text_entries.items.len > 0);
}

test "renderer paints dirty button with focus" {
    var canvas = try TerminalCanvas.init(std.testing.allocator, 20, 4);
    defer canvas.deinit();
    var tree = DomTree.init();
    _ = try tree.set_root(.{
        .kind = .button,
        .props = .{ .button = .{ .text = "OK" } },
        .layout = leaf_at(Rect.init(0, 0, 6, 1)),
        .interactable = true,
        .focused = true,
    });
    var renderer = Renderer.init(&canvas, test_background);
    try renderer.paint(&tree);
    try std.testing.expect(canvas.text_entries.items.len > 0);
}

/// Scans live cells rather than `text_entries`, which retains stale records
/// for text that has since been cleared.
fn canvas_has_text(canvas: *const TerminalCanvas, needle: []const u8) bool {
    var y: u16 = 0;
    while (y < @divFloor(canvas.height + 1, 2)) : (y += 1) {
        var x: u16 = 0;
        while (x < canvas.width) : (x += 1) {
            const entry = canvas.text_at(x, y) orelse continue;
            if (std.mem.eql(u8, entry.bytes(), needle)) return true;
        }
    }
    return false;
}

test "renderer paints every node kind through its widget" {
    // The contract: a node of any kind renders from props alone. Kinds that
    // fall through the switch would silently draw nothing.
    // Canvas height is in half-block pixels: 40 pixels is 20 addressable rows.
    var canvas = try TerminalCanvas.init(std.testing.allocator, 40, 40);
    defer canvas.deinit();
    var tree = DomTree.init();
    const root = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = leaf_at(Rect.init(0, 0, 40, 20)),
    });

    const items = [_]@import("../dom/node.zig").ListItem{
        .{ .title = "alpha" },
        .{ .title = "beta" },
    };
    const hints = [_]@import("../dom/node.zig").StatusHint{
        .{ .key = "q", .label = "quit" },
    };
    const segments = [_]@import("../dom/node.zig").SegmentItem{
        .{ .label = "one" },
        .{ .label = "two" },
    };

    const list = try tree.append_child(root, .{
        .kind = .list,
        .props = .{ .list = .{ .style = test_style(), .item_count = items.len } },
        .layout = leaf_at(Rect.init(0, 0, 40, 4)),
    });
    for (items, 0..) |row, row_index| {
        _ = try tree.append_child(list, .{
            .kind = .list_item,
            .props = .{ .list_item = .{ .title = row.title } },
            .layout = leaf_at(Rect.init(0, @intCast(row_index), 40, 1)),
        });
    }
    _ = try tree.append_child(root, .{
        .kind = .panel,
        .props = .{ .panel = .{ .style = test_style(), .title = "Feeds" } },
        .layout = leaf_at(Rect.init(0, 4, 40, 4)),
    });
    _ = try tree.append_child(root, .{
        .kind = .text_input,
        .props = .{ .text_input = .{ .style = test_style(), .value = "typed" } },
        .layout = leaf_at(Rect.init(0, 8, 40, 1)),
    });
    _ = try tree.append_child(root, .{
        .kind = .segmented,
        .props = .{ .segmented = .{ .items = &segments, .selected = 1 } },
        .layout = leaf_at(Rect.init(0, 10, 40, 1)),
    });
    _ = try tree.append_child(root, .{
        .kind = .status_line,
        .props = .{ .status_line = .{
            .style = test_style(),
            .message = "ready",
            .hints = &hints,
        } },
        .layout = leaf_at(Rect.init(0, 12, 40, 1)),
    });
    _ = try tree.append_child(root, .{
        .kind = .badge,
        .props = .{ .badge = .{ .text = "new" } },
        .layout = leaf_at(Rect.init(0, 14, 10, 1)),
    });

    var renderer = Renderer.init(&canvas, test_background);
    try renderer.paint(&tree);

    try std.testing.expect(canvas_has_text(&canvas, "alpha"));
    try std.testing.expect(canvas_has_text(&canvas, "Feeds"));
    try std.testing.expect(canvas_has_text(&canvas, "typed"));
    try std.testing.expect(canvas_has_text(&canvas, "two"));
    try std.testing.expect(canvas_has_text(&canvas, "ready"));
    try std.testing.expect(canvas_has_text(&canvas, "quit"));
    try std.testing.expect(canvas_has_text(&canvas, "new"));
}

test "renderer feeds node focus into list and panel widgets" {
    var canvas = try TerminalCanvas.init(std.testing.allocator, 30, 6);
    defer canvas.deinit();
    var style = test_style();
    const accent = Color.from_rgb(78, 211, 174);
    style.accent = accent;
    style.border = Color.from_rgb(52, 59, 67);
    var tree = DomTree.init();
    _ = try tree.set_root(.{
        .kind = .panel,
        .props = .{ .panel = .{ .style = style, .title = "Pane" } },
        .layout = leaf_at(Rect.init(0, 0, 30, 6)),
        .focused = true,
    });
    var renderer = Renderer.init(&canvas, test_background);
    try renderer.paint(&tree);
    // A focused panel paints its rail with the accent rather than the border.
    try std.testing.expect(canvas.get_pixel(0, 0).?.equals(accent));
}

test "a label repainted inside a panel keeps the panel's background" {
    // The label draws glyphs and nothing else, so the clear before it decides
    // what the rest of its row looks like. Clearing to the renderer background
    // would cut a hole through the panel the label is sitting on.
    var canvas = try TerminalCanvas.init(std.testing.allocator, 30, 12);
    defer canvas.deinit();
    var style = test_style();
    const panel_background = Color.from_rgb(22, 25, 29);
    style.background = panel_background;
    var tree = DomTree.init();
    const panel = try tree.set_root(.{
        .kind = .panel,
        .props = .{ .panel = .{ .style = style, .title = "Pane" } },
        .layout = leaf_at(Rect.init(0, 0, 30, 6)),
    });
    const label = try tree.append_child(panel, .{
        .kind = .label,
        .props = .{ .label = .{ .text = "first", .style = style } },
        .layout = leaf_at(Rect.init(0, 2, 30, 1)),
    });
    var renderer = Renderer.init(&canvas, test_background);
    try renderer.paint(&tree);
    canvas.commit_frame();

    tree.clear_dirty();
    tree.set_props(label, .{ .label = .{ .text = "second", .style = style } });
    try renderer.paint(&tree);
    try std.testing.expectEqual(@as(u16, 1), renderer.painted);
    try std.testing.expect(canvas_has_text(&canvas, "second"));
    // Past the end of the text, on the label's own row.
    try std.testing.expect(canvas.get_pixel(20, 4).?.equals(panel_background));
}

test "renderer paints empty list placeholder" {
    var canvas = try TerminalCanvas.init(std.testing.allocator, 20, 4);
    defer canvas.deinit();
    var tree = DomTree.init();
    _ = try tree.set_root(.{
        .kind = .list,
        .props = .{ .list = .{ .style = test_style(), .empty_text = "Nothing here" } },
        .layout = leaf_at(Rect.init(0, 0, 20, 4)),
    });
    var renderer = Renderer.init(&canvas, test_background);
    try renderer.paint(&tree);
    try std.testing.expect(canvas_has_text(&canvas, "Nothing here"));
}

fn mount_list(tree: *DomTree, titles: []const []const u8) !void {
    std.debug.assert(titles.len > 0);
    std.debug.assert(tree.node_count == 0);
    const list = try tree.set_root(.{
        .kind = .list,
        .props = .{ .list = .{
            .style = test_style(),
            .item_count = @intCast(titles.len),
        } },
        .layout = .{ .kind = .{ .leaf = {} }, .rect = Rect.init(0, 0, 20, 8) },
    });
    for (titles) |title| {
        _ = try tree.append_child(list, .{
            .kind = .list_item,
            .props = .{ .list_item = .{ .title = title } },
            .layout = .{ .kind = .{ .leaf = {} } },
        });
    }
    try tree.evaluate(Rect.init(0, 0, 20, 8));
}

test "changing one row repaints one node, not the list" {
    // The point of mounting rows as nodes: editing row three must not cost a
    // redraw of rows one, two and four.
    var canvas = try TerminalCanvas.init(std.testing.allocator, 20, 16);
    defer canvas.deinit();
    var tree = DomTree.init();
    try mount_list(&tree, &.{ "alpha", "beta", "gamma", "delta" });

    var renderer = Renderer.init(&canvas, test_background);
    try renderer.paint(&tree);
    try std.testing.expectEqual(@as(u16, 5), renderer.painted);
    canvas.commit_frame();

    tree.clear_dirty();
    tree.set_props(3, .{ .list_item = .{ .title = "changed" } });
    try renderer.paint(&tree);
    try std.testing.expectEqual(@as(u16, 1), renderer.painted);
    try std.testing.expect(canvas_has_text(&canvas, "changed"));
    // Siblings survive because the list itself never repainted over them.
    try std.testing.expect(canvas_has_text(&canvas, "alpha"));
    try std.testing.expect(canvas_has_text(&canvas, "beta"));
    try std.testing.expect(canvas_has_text(&canvas, "delta"));
    try std.testing.expect(!canvas_has_text(&canvas, "gamma"));
}

test "repainting a list restores every row" {
    var canvas = try TerminalCanvas.init(std.testing.allocator, 20, 16);
    defer canvas.deinit();
    var tree = DomTree.init();
    try mount_list(&tree, &.{ "alpha", "beta", "gamma" });
    var renderer = Renderer.init(&canvas, test_background);
    try renderer.paint(&tree);
    canvas.commit_frame();

    tree.clear_dirty();
    // A selection change belongs to the list, which paints over its rows.
    tree.set_props(0, .{ .list = .{
        .style = test_style(),
        .item_count = 3,
        .selected = 1,
    } });
    try renderer.paint(&tree);
    try std.testing.expectEqual(@as(u16, 4), renderer.painted);
    try std.testing.expect(canvas_has_text(&canvas, "alpha"));
    try std.testing.expect(canvas_has_text(&canvas, "beta"));
    try std.testing.expect(canvas_has_text(&canvas, "gamma"));
}

test "a clean frame paints nothing but keeps its content" {
    var canvas = try TerminalCanvas.init(std.testing.allocator, 20, 16);
    defer canvas.deinit();
    var tree = DomTree.init();
    try mount_list(&tree, &.{ "alpha", "beta" });
    var renderer = Renderer.init(&canvas, test_background);
    try renderer.paint(&tree);
    canvas.commit_frame();

    tree.clear_dirty();
    try renderer.paint(&tree);
    try std.testing.expectEqual(@as(u16, 0), renderer.painted);
    // Nothing was repainted, yet the frame still carries the previous content
    // forward so committing it does not strand what is on screen.
    try std.testing.expect(canvas_has_text(&canvas, "alpha"));
    try std.testing.expect(canvas_has_text(&canvas, "beta"));
}

test "rows scrolled out of view are not painted" {
    var canvas = try TerminalCanvas.init(std.testing.allocator, 20, 8);
    defer canvas.deinit();
    var tree = DomTree.init();
    const list = try tree.set_root(.{
        .kind = .list,
        .props = .{ .list = .{ .style = test_style(), .item_count = 8 } },
        .layout = .{ .kind = .{ .leaf = {} } },
    });
    const titles = [_][]const u8{ "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7" };
    for (titles) |title| {
        _ = try tree.append_child(list, .{
            .kind = .list_item,
            .props = .{ .list_item = .{ .title = title } },
            .layout = .{ .kind = .{ .leaf = {} } },
        });
    }
    // Four rows of height one fit; the rest collapse to zero size.
    try tree.evaluate(Rect.init(0, 0, 20, 4));
    var renderer = Renderer.init(&canvas, test_background);
    try renderer.paint(&tree);
    try std.testing.expectEqual(@as(u16, 5), renderer.painted);
    try std.testing.expect(canvas_has_text(&canvas, "r3"));
    try std.testing.expect(!canvas_has_text(&canvas, "r4"));
}

test "repeated frames do not accumulate text entries" {
    // A partial frame carries the previous frame forward. If it copied dead
    // records too, a long running loop would overflow text_entries -- which is
    // exactly how this surfaced: a crash after a few hundred frames.
    var canvas = try TerminalCanvas.init(std.testing.allocator, 40, 16);
    defer canvas.deinit();
    var tree = DomTree.init();
    try mount_list(&tree, &.{ "alpha", "beta", "gamma" });
    var renderer = Renderer.init(&canvas, test_background);

    var frame: u16 = 0;
    var settled: usize = 0;
    while (frame < 200) : (frame += 1) {
        renderer.begin();
        // Stand in for drawing the DOM does not own: clear a strip and redraw
        // it every frame, the pattern that leaves dead records behind.
        const strip = Rect.init(0, 6, 40, 1);
        canvas.clear_rect(strip, test_background);
        try canvas.add_styled_text(0, 6, "status", test_foreground, null, .{});
        try renderer.paint_tree(&tree);
        canvas.commit_frame();
        if (frame == 10) settled = canvas.previous_text_entries.items.len;
    }
    try std.testing.expect(settled > 0);
    try std.testing.expectEqual(settled, canvas.previous_text_entries.items.len);
    // Re-establish a frame: commit swaps the position map out, and that map is
    // what says which cells are live.
    renderer.begin();
    try std.testing.expect(canvas_has_text(&canvas, "alpha"));
    try std.testing.expect(canvas_has_text(&canvas, "gamma"));
    try std.testing.expect(canvas_has_text(&canvas, "status"));
}

test "renderer skips image nodes without a path" {
    var canvas = try TerminalCanvas.init(std.testing.allocator, 20, 6);
    defer canvas.deinit();
    var tree = DomTree.init();
    _ = try tree.set_root(.{
        .kind = .image,
        .props = .{ .image = .{} },
        .layout = leaf_at(Rect.init(0, 0, 20, 6)),
    });
    var renderer = Renderer.init(&canvas, test_background);
    try renderer.paint(&tree);
    try std.testing.expect(canvas.image_placement == null);
}
