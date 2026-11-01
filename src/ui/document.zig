const std = @import("std");
const markix = @import("markix");
const document = @import("../reader/document.zig");
const theme = @import("../theme.zig");
const node = @import("node.zig");

const Tree = node.Tree;
const Index = node.Index;
const Style = node.Style;

pub const gutter_width: i32 = 2;
pub const image_rows: i32 = 10;
pub const nodes_max: usize = 4 * @as(usize, document.block_count_max) + 8;

pub fn measure_for(inner_width: i32, measure_max: i32) i32 {
    std.debug.assert(measure_max > gutter_width);
    return @max(0, @min(inner_width, measure_max));
}

pub fn build(tree: *Tree, parsed: *const document.Document, width: i32, image: ?[]const u8) !void {
    std.debug.assert(tree.len == 0);
    std.debug.assert(parsed.count <= document.block_count_max);
    const root = try node.box(tree, node.none, .{ .width = node.fixed(width), .height = node.fit });
    if (image) |path| {
        _ = try tree.append(root, .{
            .layout = .{ .width = node.grow, .height = node.fixed(image_rows) },
            .element = .image,
            .href = path,
        });
    }
    for (parsed.blocks[0..parsed.count], 0..) |*block, index| {
        if (index > 0) _ = try node.spacer(tree, root, node.grow, node.fixed(1));
        const look = presentation(block.kind);
        try emit(tree, root, look.prefix, block.text.bytes(), look.style);
        if (block.url.is_empty()) continue;
        const link = link_presentation();
        try emit(tree, root, link.prefix, block.url.bytes(), link.style);
    }
}

pub fn message(tree: *Tree, text: []const u8, width: i32) !void {
    std.debug.assert(tree.len == 0);
    const root = try node.box(tree, node.none, .{ .width = node.fixed(width), .height = node.fit });
    _ = try node.label(tree, root, text, .{ .style = theme.ink(theme.palette.muted) });
}

pub fn height(tree: *const Tree) i32 {
    return markix.backend.cells.height_of(tree);
}

fn emit(tree: *Tree, root: Index, prefix: []const u8, text: []const u8, style: Style) !void {
    const strip = try node.row(tree, root, .{ .height = node.fit });
    _ = try node.label(tree, strip, prefix, .{ .width = node.fixed(gutter_width), .style = style });
    _ = try node.paragraph(tree, strip, text, .{ .style = style });
}

const Presentation = struct {
    prefix: []const u8,
    style: Style,
};

fn presentation(kind: document.Kind) Presentation {
    const palette = theme.palette;
    return switch (kind) {
        .paragraph => .{ .prefix = "", .style = theme.ink(palette.foreground) },
        .heading => .{ .prefix = "# ", .style = theme.strong(palette.accent_warm) },
        .list_item => .{ .prefix = "- ", .style = theme.ink(palette.foreground) },
        .quote => .{ .prefix = "| ", .style = theme.ink(palette.accent_cool) },
        .code => .{ .prefix = "  ", .style = code_style() },
        .link => link_presentation(),
        .image => .{ .prefix = "[]", .style = theme.strong(palette.accent) },
    };
}

fn code_style() Style {
    return .{ .foreground = theme.palette.command, .background = theme.palette.panel_alt };
}

fn link_presentation() Presentation {
    return .{ .prefix = "  ", .style = theme.ink(theme.palette.accent_cool) };
}

const testing = std.testing;

fn page(tree: *Tree, parsed: *const document.Document, width: i32, image: ?[]const u8) !void {
    try build(tree, parsed, width, image);
    node.resolve(tree, width, markix.unbounded);
}

test "a block's prefix lands in the gutter and its text beside it" {
    var nodes: [32]markix.Node = undefined;
    var tree = Tree.init(&nodes);
    const parsed = document.parse("<h1>Heading</h1><p>Body text.</p>");
    try page(&tree, &parsed, 40, null);
    try testing.expectEqualStrings("# ", tree.at(2).text);
    try testing.expectEqualStrings("Heading", tree.at(3).text);
    try testing.expectEqual(@as(i32, 2), tree.at(3).rect.x);
    try testing.expectEqual(@as(i32, 3), height(&tree));
}

test "an image reserves its rows at the top of the page" {
    var nodes: [32]markix.Node = undefined;
    var tree = Tree.init(&nodes);
    const parsed = document.parse("<p>Body text.</p>");
    try page(&tree, &parsed, 40, "/tmp/cover.png");
    try testing.expectEqual(markix.Element.image, tree.at(1).element);
    try testing.expectEqual(image_rows + 1, height(&tree));
}

test "a narrow page wraps a block across rows" {
    var nodes: [32]markix.Node = undefined;
    var tree = Tree.init(&nodes);
    const parsed = document.parse(
        "<p>Reliable systems software with explicit operational limits.</p>",
    );
    try page(&tree, &parsed, 20, null);
    try testing.expect(height(&tree) > 1);
    try testing.expectEqual(@as(i32, 18), tree.at(3).rect.width);
}
