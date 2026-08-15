//! The status bar and the vocabulary of hints it draws. Both experiences build
//! their hint rows from `hint`, so the same key is never advertised two ways.

const std = @import("std");
const markix = @import("markix");
const dom = markix.dom;
const layout = markix.layout;
const widgets = markix.widgets;
const theme = @import("../theme.zig");
const tokens = @import("tokens.zig");

const NodeIndex = dom.DomTree.NodeIndex;
const Hint = widgets.StatusHint;

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

/// Hint rows every mode shares. A mode names its own keys and then ends with
/// the two that are always true, so switching experiences and quitting are
/// advertised on every screen of the application.
pub const trailer = [_]Hint{ hint.switch_experience, hint.quit };

/// The rows a fuzzy prompt advertises, wherever one is open.
pub const prompt_hints = [_]Hint{
    hint.fuzzy,
    hint.step,
    hint.run,
    hint.close,
};

pub const search_hints = [_]Hint{ hint.keep, hint.clear };

pub const Config = struct {
    message: []const u8 = "",
    hints: []const Hint = &.{},
    /// Draws the bar in the danger palette, for a confirmation.
    warning: bool = false,
};

pub fn mount(tree: *dom.DomTree, parent: NodeIndex) !NodeIndex {
    return tree.append_child(parent, .{
        .kind = .status_line,
        .props = .{ .status_line = .{
            .style = theme.base,
            .visual = tokens.status_visual,
        } },
        .layout = layout.LayoutElement.leaf(),
    });
}

pub fn update(tree: *dom.DomTree, node: NodeIndex, config: Config) void {
    tree.set_props(node, .{ .status_line = .{
        .style = if (config.warning) theme.warning else theme.base,
        .visual = tokens.status_visual,
        .message = config.message,
        .hints = config.hints,
    } });
}

/// Joins a mode's own hints with the trailer into `buffer`.
pub fn with_trailer(
    buffer: []Hint,
    hints: []const Hint,
) []const Hint {
    std.debug.assert(buffer.len >= hints.len + trailer.len);
    @memcpy(buffer[0..hints.len], hints);
    @memcpy(buffer[hints.len..][0..trailer.len], &trailer);
    return buffer[0 .. hints.len + trailer.len];
}

test "the trailer is appended after a mode's own hints" {
    var buffer: [8]Hint = undefined;
    const own = [_]Hint{ hint.move, hint.command };
    const joined = with_trailer(&buffer, &own);
    try std.testing.expectEqual(@as(usize, 4), joined.len);
    try std.testing.expectEqualStrings("j/k", joined[0].key);
    try std.testing.expectEqualStrings("ctrl-u", joined[2].key);
    try std.testing.expectEqualStrings("q", joined[3].key);
}
