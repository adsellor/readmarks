const std = @import("std");
const markix = @import("markix");

pub const Tree = markix.Tree;
pub const Node = markix.Node;
pub const Index = markix.Index;
pub const Sizing = markix.Sizing;
pub const Edges = markix.Edges;
pub const Style = markix.Style;
pub const Color = markix.Color;
pub const Rect = markix.Rect;
pub const none = markix.none;

pub const grow = Sizing{ .grow = .{} };
pub const fit = Sizing{ .fit = .{} };

pub fn fixed(cells: i32) Sizing {
    std.debug.assert(cells >= 0);
    return .{ .fixed = cells };
}

pub fn fit_at_least(cells: i32) Sizing {
    std.debug.assert(cells >= 0);
    return .{ .fit = .{ .min = cells } };
}

pub fn fit_at_most(cells: i32) Sizing {
    std.debug.assert(cells >= 0);
    return .{ .fit = .{ .max = cells } };
}

pub const Box = struct {
    direction: markix.Direction = .column,
    width: Sizing = grow,
    height: Sizing = grow,
    padding: Edges = .{},
    gap: i32 = 0,
    alignment: markix.Alignment = .{},
    background: Color = .{},
};

pub fn box(tree: *Tree, parent: Index, spec: Box) !Index {
    std.debug.assert(spec.gap >= 0);
    return tree.append(parent, .{
        .layout = .{
            .width = spec.width,
            .height = spec.height,
            .padding = spec.padding,
            .gap = spec.gap,
            .direction = spec.direction,
            .alignment = spec.alignment,
        },
        .style = .{ .background = spec.background },
    });
}

pub fn row(tree: *Tree, parent: Index, spec: Box) !Index {
    var across = spec;
    across.direction = .row;
    return box(tree, parent, across);
}

pub const Line = struct {
    width: Sizing = grow,
    style: Style = .{},
};

pub fn label(tree: *Tree, parent: Index, value: []const u8, spec: Line) !Index {
    std.debug.assert(parent != none);
    return tree.append(parent, .{
        .layout = .{ .width = spec.width, .height = fixed(1) },
        .style = spec.style,
        .element = .label,
        .text = value,
        .wrap = false,
        .clip = true,
    });
}

pub fn line(tree: *Tree, parent: Index, spec: Line) !Index {
    return label(tree, parent, "", spec);
}

pub fn run(tree: *Tree, parent: Index, value: []const u8, style: Style) !void {
    std.debug.assert(parent != none);
    if (value.len == 0) return;
    _ = try tree.append(parent, .{
        .style = style,
        .element = .text_run,
        .display = .inline_,
        .text = value,
    });
}

pub fn paragraph(tree: *Tree, parent: Index, value: []const u8, spec: Line) !Index {
    std.debug.assert(parent != none);
    return tree.append(parent, .{
        .layout = .{ .width = spec.width, .height = fit },
        .style = spec.style,
        .element = .paragraph,
        .text = value,
        .wrap = true,
        .clip = true,
    });
}

pub fn spacer(tree: *Tree, parent: Index, width: Sizing, height: Sizing) !Index {
    return box(tree, parent, .{ .width = width, .height = height });
}

pub fn fill(tree: *Tree, parent: Index, width: Sizing, height: Sizing, color: Color) !Index {
    return box(tree, parent, .{ .width = width, .height = height, .background = color });
}

pub fn columns(value: []const u8) i32 {
    return markix.measure.columns(value);
}

pub fn resolve(tree: *Tree, width: i32, height: i32) void {
    std.debug.assert(width >= 0);
    std.debug.assert(height >= 0);
    markix.resolve(tree, .{ .width = width, .height = height }, .{
        .measure = markix.measure.monospace,
    });
}

pub fn rect_of(tree: *const Tree, index: Index) Rect {
    if (index == none or index >= tree.len) return .{};
    return tree.at(index).rect;
}

pub fn inner_of(tree: *const Tree, index: Index) Rect {
    if (index == none or index >= tree.len) return .{};
    const node = tree.at(index);
    const padding = node.layout.padding;
    return .{
        .x = node.rect.x + padding.left,
        .y = node.rect.y + padding.top,
        .width = @max(0, node.rect.width - padding.horizontal()),
        .height = @max(0, node.rect.height - padding.vertical()),
    };
}

const testing = std.testing;

test "a label is one clipped row and its runs ride inside it" {
    var nodes: [8]markix.Node = undefined;
    var tree = Tree.init(&nodes);
    const root = try row(&tree, none, .{ .width = fixed(10), .height = fixed(1) });
    const title = try line(&tree, root, .{});
    try run(&tree, title, "one ", .{});
    try run(&tree, title, "two", .{ .bold = true });
    try run(&tree, title, "", .{});
    resolve(&tree, 10, 1);
    try testing.expectEqual(@as(usize, 4), tree.len);
    try testing.expect(tree.at(title).clip);
    try testing.expectEqual(@as(i32, 10), rect_of(&tree, title).width);
    try testing.expectEqual(@as(i32, 1), rect_of(&tree, title).height);
}
