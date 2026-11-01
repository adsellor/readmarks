const std = @import("std");
const markix = @import("markix");
const theme = @import("../theme.zig");
const node = @import("node.zig");

const Tree = node.Tree;
const Index = node.Index;
const Color = node.Color;

pub const Look = struct {
    prompt_color: Color,
    foreground: Color,
    ground: Color,
    cursor_foreground: Color,
    cursor_ground: Color,
};

pub fn focused_look() Look {
    const palette = theme.palette;
    return .{
        .prompt_color = palette.accent_warm,
        .foreground = palette.foreground_strong,
        .ground = palette.panel_alt,
        .cursor_foreground = palette.inverse_foreground,
        .cursor_ground = palette.accent_warm,
    };
}

pub fn command_look() Look {
    var look = focused_look();
    look.prompt_color = theme.palette.command;
    look.cursor_ground = theme.palette.command_row;
    return look;
}

pub const Field = struct {
    prompt: []const u8 = "",
    placeholder: []const u8 = "",
    value: []const u8 = "",
    cursor: u16 = 0,
    focused: bool = true,
    look: Look,
};

pub fn field(tree: *Tree, parent: Index, spec: Field, width: i32) !Index {
    std.debug.assert(spec.cursor <= spec.value.len);
    std.debug.assert(width >= 0);
    const look = spec.look;
    const strip = try node.line(tree, parent, .{ .style = .{ .background = look.ground } });
    try node.run(tree, strip, spec.prompt, .{ .foreground = look.prompt_color, .bold = true });
    const room = @max(0, width - node.columns(spec.prompt));
    const muted = theme.faint(theme.palette.muted);
    if (!spec.focused) {
        if (spec.value.len == 0) {
            try node.run(tree, strip, spec.placeholder, muted);
        } else {
            try node.run(tree, strip, spec.value, theme.ink(look.foreground));
        }
        return strip;
    }
    const visible: u16 = @intCast(@min(room, std.math.maxInt(u16)));
    const split = markix.widgets.split_text(spec.value, spec.cursor, visible);
    try node.run(tree, strip, split.before, theme.ink(look.foreground));
    try node.run(tree, strip, split.at, .{
        .foreground = look.cursor_foreground,
        .background = look.cursor_ground,
        .bold = true,
    });
    try node.run(tree, strip, split.after, theme.ink(look.foreground));
    if (spec.value.len == 0) try node.run(tree, strip, spec.placeholder, muted);
    return strip;
}

const testing = std.testing;

test "a focused field gives the cursor a cell of its own" {
    var nodes: [16]node.Node = undefined;
    var tree = Tree.init(&nodes);
    const root = try node.box(&tree, node.none, .{});
    _ = try field(&tree, root, .{
        .prompt = ": ",
        .placeholder = "Search",
        .value = "",
        .look = command_look(),
    }, 20);
    try testing.expectEqualStrings(": ", tree.at(2).text);
    try testing.expectEqualStrings(" ", tree.at(3).text);
    try testing.expect(tree.at(3).style.background.eql(theme.palette.command_row));
    try testing.expectEqualStrings("Search", tree.at(4).text);
}
