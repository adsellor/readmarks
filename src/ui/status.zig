const std = @import("std");
const theme = @import("../theme.zig");
const tokens = @import("tokens.zig");
const node = @import("node.zig");

const Tree = node.Tree;
const Index = node.Index;

pub const Hint = struct {
    key: []const u8,
    label: []const u8,

    fn columns(self: Hint) i32 {
        return node.columns(self.key) + 1 + node.columns(self.label);
    }
};

pub const hint = struct {
    pub const help = Hint{ .key = "?", .label = "keys" };
    pub const move = Hint{ .key = "j/k", .label = "move" };
    pub const focus = Hint{ .key = "h/l", .label = "focus" };
    pub const activate = Hint{ .key = "enter", .label = "open" };
    pub const apply = Hint{ .key = "enter", .label = "apply" };
    pub const run = Hint{ .key = "enter", .label = "run" };
    pub const save = Hint{ .key = "enter", .label = "next/save" };
    pub const browser = Hint{ .key = "o", .label = "browser" };
    pub const search = Hint{ .key = "/", .label = "search" };
    pub const find = Hint{ .key = "/", .label = "find" };
    pub const command = Hint{ .key = ":", .label = "command" };
    pub const zen = Hint{ .key = "z", .label = "zen" };
    pub const add = Hint{ .key = "a", .label = "add" };
    pub const refresh = Hint{ .key = "r", .label = "refresh" };
    pub const scopes = Hint{ .key = "1/2", .label = "scope" };
    pub const fuzzy = Hint{ .key = "type", .label = "fuzzy find" };
    pub const step = Hint{ .key = "ctrl-n/p", .label = "move" };
    pub const field = Hint{ .key = "tab", .label = "next field" };
    pub const category = Hint{ .key = "tab", .label = "next category" };
    pub const switch_experience = Hint{ .key = "ctrl-u", .label = "switch" };
    pub const close = Hint{ .key = "esc", .label = "close" };
    pub const clear = Hint{ .key = "esc", .label = "clear" };
    pub const cancel = Hint{ .key = "esc", .label = "cancel" };
    pub const keep = Hint{ .key = "enter", .label = "keep" };
    pub const quit = Hint{ .key = "q", .label = "quit" };
};

pub const trailer = [_]Hint{ hint.switch_experience, hint.quit };

pub const prompt_hints = [_]Hint{ hint.fuzzy, hint.step, hint.run, hint.close };

pub const search_hints = [_]Hint{ hint.keep, hint.clear };

pub const Config = struct {
    message: []const u8 = "",
    hints: []const Hint = &.{},
    warning: bool = false,
};

pub fn with_trailer(buffer: []Hint, hints: []const Hint) []const Hint {
    std.debug.assert(buffer.len >= hints.len + trailer.len);
    @memcpy(buffer[0..hints.len], hints);
    @memcpy(buffer[hints.len..][0..trailer.len], &trailer);
    return buffer[0 .. hints.len + trailer.len];
}

pub fn build(tree: *Tree, parent: Index, config: Config, width: i32) !void {
    std.debug.assert(width >= 0);
    const palette = theme.palette;
    const ground = if (config.warning) palette.danger else palette.background;
    const ink = if (config.warning) palette.inverse_foreground else palette.foreground;
    const strip = try node.row(tree, parent, .{ .height = node.fixed(1), .background = ground });
    _ = try node.label(tree, strip, config.message, .{ .style = theme.strong(ink) });
    const shown = fitting(config.hints, width);
    if (shown.len == 0) return;
    std.debug.assert(span(shown) < width);
    const hints = try node.line(tree, strip, .{ .width = node.fixed(span(shown)) });
    const key_style = if (config.warning)
        theme.chip(palette.inverse_foreground, palette.danger)
    else
        theme.chip(palette.foreground_strong, palette.panel_alt);
    const label_style = theme.faint(if (config.warning) palette.foreground else palette.muted);
    for (shown, 0..) |entry, index| {
        try node.run(tree, hints, entry.key, key_style);
        try node.run(tree, hints, " ", label_style);
        try node.run(tree, hints, entry.label, label_style);
        if (index + 1 < shown.len) try node.run(tree, hints, &gap, label_style);
    }
}

const gap: [tokens.hint_gap]u8 = @splat(' ');

fn span(hints: []const Hint) i32 {
    var total: i32 = 0;
    for (hints) |entry| total += entry.columns();
    if (hints.len > 1) total += @as(i32, @intCast(hints.len - 1)) * tokens.hint_gap;
    return total;
}

fn fitting(hints: []const Hint, width: i32) []const Hint {
    var count = hints.len;
    while (count > 0 and span(hints[0..count]) >= width) count -= 1;
    return hints[0..count];
}

const testing = std.testing;

test "the trailer is appended after a mode's own hints" {
    var buffer: [8]Hint = undefined;
    const own = [_]Hint{ hint.move, hint.command };
    const joined = with_trailer(&buffer, &own);
    try testing.expectEqual(@as(usize, 4), joined.len);
    try testing.expectEqualStrings("j/k", joined[0].key);
    try testing.expectEqualStrings("ctrl-u", joined[2].key);
    try testing.expectEqualStrings("q", joined[3].key);
}

test "hints that do not fit beside the message are dropped from the end" {
    const own = [_]Hint{ hint.move, hint.command, hint.quit };
    try testing.expectEqual(@as(i32, 8 + 2 + 9 + 2 + 6), span(&own));
    try testing.expectEqual(@as(usize, 2), fitting(&own, 27).len);
    try testing.expectEqual(@as(usize, 0), fitting(&own, 4).len);
}
