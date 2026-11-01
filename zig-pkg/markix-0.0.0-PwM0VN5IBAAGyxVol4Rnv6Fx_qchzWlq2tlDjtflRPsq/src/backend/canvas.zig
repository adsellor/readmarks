const std = @import("std");
const tree_mod = @import("../layout/tree.zig");
const rect_mod = @import("../layout/rect.zig");
const dom = @import("../layout/element.zig");
const Units = @import("../layout/units.zig").Units;

const Tree = tree_mod.Tree;
const Index = tree_mod.Index;
const none = tree_mod.none;

pub const Rect = rect_mod.Rect;
pub const Options = struct {
    units: Units = .{ .width = 9, .height = 9 },
    background: u32 = 0,
    text_bleed_px: i32 = 3,
};

pub const Draw = struct {
    kind: Kind = .fill,
    rect: Rect = .{},
    damage: Rect = .{},
    color: u32 = 0,
    text: []const u8 = "",
    digest: u64 = 0,
    bold: bool = false,
    attributes: u32 = 0,
    node: Index = none,

    pub const Kind = enum(u8) { fill, text };

    pub fn eql(self: Draw, other: Draw) bool {
        return self.kind == other.kind and
            self.node == other.node and
            self.color == other.color and
            self.bold == other.bold and
            self.attributes == other.attributes and
            self.rect.x == other.rect.x and
            self.rect.y == other.rect.y and
            self.rect.width == other.rect.width and
            self.rect.height == other.rect.height and
            self.text.len == other.text.len and
            self.digest == other.digest;
    }
};

pub const Frame = struct {
    items: []Draw,
    len: usize = 0,
    background: u32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    truncated: bool = false,
    drawn: bool = false,

    pub fn init(storage: []Draw) Frame {
        return .{ .items = storage };
    }

    pub fn reset(self: *Frame) void {
        self.len = 0;
        self.truncated = false;
        self.drawn = true;
    }

    pub fn slice(self: *const Frame) []const Draw {
        return self.items[0..self.len];
    }

    pub fn push(self: *Frame, draw: Draw) void {
        if (self.len == self.items.len) {
            self.truncated = true;
            return;
        }
        self.items[self.len] = draw;
        self.len += 1;
    }
};

pub fn paint(frame: *Frame, tree: *const Tree, options: Options) void {
    std.debug.assert(options.units.width > 0);
    std.debug.assert(options.units.height > 0);
    frame.reset();
    frame.background = options.background;
    if (tree.len == 0) return;

    const root = tree.at(0).rect;
    frame.width = options.units.x(root.width);
    frame.height = options.units.y(root.height);

    var index: Index = 0;
    while (index < tree.len) : (index += 1) {
        const node = tree.at(index);
        if (node.is_inline()) continue;

        const box = scale(node.rect, options);
        if (node.style.background.is_set() and box.width > 0 and box.height > 0) {
            frame.push(.{
                .kind = .fill,
                .rect = box,
                .damage = box,
                .color = node.style.background.value(),
                .node = index,
            });
        }

        const text = text_of(tree, index);
        if (text.len > 0) {
            frame.push(.{
                .kind = .text,
                .rect = box,
                .damage = inflate(box, options.text_bleed_px),
                .color = if (node.style.foreground.is_set())
                    node.style.foreground.value()
                else
                    default_ink,
                .text = text,
                .digest = digest(text),
                .bold = node.style.bold,
                .node = index,
            });
        }
    }
}

pub const default_ink: u32 = 0xffffff;

pub fn digest(text: []const u8) u64 {
    return std.hash.Wyhash.hash(0, text);
}

pub fn text_of(tree: *const Tree, index: Index) []const u8 {
    const node = tree.at(index);
    if (node.text.len > 0) return node.text;
    const child = node.first_child;
    if (child == none or !tree.at(child).is_inline()) return "";
    if (tree.at(child).next_sibling != none) return "";
    return tree.at(child).text;
}

fn inflate(box: Rect, by: i32) Rect {
    return .{
        .x = box.x - by,
        .y = box.y - by,
        .width = box.width + by * 2,
        .height = box.height + by * 2,
    };
}

fn scale(box: Rect, options: Options) Rect {
    return .{
        .x = options.units.x(box.x),
        .y = options.units.y(box.y),
        .width = options.units.x(box.width),
        .height = options.units.y(box.height),
    };
}

const testing = std.testing;
const el = @import("../layout/dsl.zig");
const layout = @import("../layout/resolve.zig");
const measure = @import("../layout/measure.zig");
const style_mod = @import("../layout/style.zig");

fn resolve(tree: *Tree, width: i32) void {
    layout.resolve(tree, .{ .width = width, .height = layout.unbounded }, .{
        .measure = measure.monospace,
    });
}

test "a filled box becomes a rectangle in pixels" {
    var storage: [8]tree_mod.Node = undefined;
    var tree = Tree.init(&storage);
    _ = try el.mount_under(&tree, none, el.column(.{
        .width = .{ .fixed = 10 },
        .height = .{ .fixed = 4 },
        .style = .{ .background = style_mod.Color.rgb(0x203040) },
    }, .{}));
    resolve(&tree, 10);

    var draws: [8]Draw = undefined;
    var frame = Frame.init(&draws);
    paint(&frame, &tree, .{ .units = .{ .width = 9, .height = 9 } });

    try testing.expectEqual(@as(usize, 1), frame.len);
    const drawn = frame.slice()[0];
    try testing.expectEqual(Draw.Kind.fill, drawn.kind);
    try testing.expectEqual(@as(u32, 0x203040), drawn.color);
    try testing.expectEqual(@as(i32, 90), drawn.rect.width);
    try testing.expectEqual(@as(i32, 36), drawn.rect.height);
    try testing.expectEqual(@as(i32, 90), frame.width);
}

test "a parent is drawn before what sits on it" {
    var storage: [8]tree_mod.Node = undefined;
    var tree = Tree.init(&storage);
    const panel = try el.mount_under(&tree, none, el.column(.{
        .width = .{ .fixed = 10 },
        .height = .{ .fixed = 4 },
        .style = .{ .background = style_mod.Color.rgb(0x111111) },
    }, .{}));
    _ = try el.mount_under(&tree, panel, el.column(.{
        .width = .{ .fixed = 2 },
        .height = .{ .fixed = 1 },
        .style = .{ .background = style_mod.Color.rgb(0x222222) },
    }, .{}));
    resolve(&tree, 10);

    var draws: [8]Draw = undefined;
    var frame = Frame.init(&draws);
    paint(&frame, &tree, .{});

    try testing.expectEqual(@as(usize, 2), frame.len);
    try testing.expectEqual(@as(u32, 0x111111), frame.slice()[0].color);
    try testing.expectEqual(@as(u32, 0x222222), frame.slice()[1].color);
}

test "text is drawn once, not once per inline run" {
    var storage: [8]tree_mod.Node = undefined;
    var tree = Tree.init(&storage);
    const line = try el.mount_under(&tree, none, el.column(.{
        .width = .{ .fixed = 20 },
        .style = .{ .foreground = style_mod.Color.rgb(0xeeeeee) },
    }, .{}));
    _ = try el.mount_under(&tree, line, el.run("hello", .{}));
    resolve(&tree, 20);

    var draws: [8]Draw = undefined;
    var frame = Frame.init(&draws);
    paint(&frame, &tree, .{});

    try testing.expectEqual(@as(usize, 1), frame.len);
    try testing.expectEqualStrings("hello", frame.slice()[0].text);
    try testing.expectEqual(@as(u32, 0xeeeeee), frame.slice()[0].color);
}

test "storage that runs out truncates rather than running past its end" {
    var storage: [8]tree_mod.Node = undefined;
    var tree = Tree.init(&storage);
    const root = try el.mount_under(&tree, none, el.row(.{
        .width = .{ .fixed = 8 },
        .height = .{ .fixed = 1 },
    }, .{}));
    var made: usize = 0;
    while (made < 4) : (made += 1) {
        _ = try el.mount_under(&tree, root, el.column(.{
            .width = .{ .fixed = 2 },
            .height = .{ .fixed = 1 },
            .style = .{ .background = style_mod.Color.rgb(0x010203) },
        }, .{}));
    }
    resolve(&tree, 8);

    var draws: [2]Draw = undefined;
    var frame = Frame.init(&draws);
    paint(&frame, &tree, .{});
    try testing.expect(frame.truncated);
    try testing.expectEqual(@as(usize, 2), frame.len);
}
