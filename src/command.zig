//! readmarks' command centre policy: the keys it answers to and the words it
//! wears. The component in `ui/command_center.zig` holds no opinion about
//! either; this is where the application decides, once, for both experiences.

const std = @import("std");
const markix = @import("markix");
const command_center = @import("ui/command_center.zig");

const Key = markix.layout.input.Key;

pub const bindings = command_center.Bindings{
    .previous = &.{ .up, .shift_tab },
    .next = &.{ .down, .tab },
    .previous_control = "kp",
    .next_control = "jn",
    .activate = &.{.enter},
    .close = &.{.escape},
    .quit_control = "c",
};

/// The prompt. `:` opens it in both experiences, so it reads the same in both.
pub const prompt = ": ";

pub const action_prefix = '>';

pub const deck = struct {
    pub const title = "COMMAND CENTRE";
    pub const placeholder = "Search, or > to run an action";
    pub const empty = "No matches";
    pub const idle = "Type to search, or > to run an action";
};

pub fn action_query(raw: []const u8) ?[]const u8 {
    if (raw.len == 0 or raw[0] != action_prefix) return null;
    return std.mem.trimStart(u8, raw[1..], " ");
}

/// The zen finder: the same surface, filtered by scope.
pub const finder = struct {
    pub const prompt = "/ ";
    pub const filter_label = "FILTER";
    pub const empty = "No matches";
};

/// What the marker column says a result is. Shared so a saved page looks the
/// same whether the centre was opened over feeds or over bookmarks.
pub const marker = struct {
    pub const action: u8 = '>';
    pub const item: u8 = '*';
    pub const group: u8 = '#';
};

pub fn deck_config(meta: []const u8, query: []const u8) command_center.Config {
    return .{
        .title = deck.title,
        .meta = meta,
        .prompt = prompt,
        .placeholder = deck.placeholder,
        .empty_text = if (query.len == 0) deck.idle else deck.empty,
    };
}

pub fn argument_config(
    title: []const u8,
    placeholder: []const u8,
) command_center.Config {
    return .{
        .title = title,
        .meta = "",
        .prompt = prompt,
        .placeholder = placeholder,
        .empty_text = "",
    };
}

pub fn finder_config(
    title: []const u8,
    meta: []const u8,
    placeholder: []const u8,
    filters: command_center.Filters,
) command_center.Config {
    return .{
        .title = title,
        .meta = meta,
        .prompt = finder.prompt,
        .placeholder = placeholder,
        .empty_text = finder.empty,
        .filters = filters,
    };
}

test "the bindings cover both the arrow and the control idiom" {
    try std.testing.expect(std.mem.indexOfScalar(u8, bindings.next_control, 'n') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, bindings.previous_control, 'p') != null);
    try std.testing.expectEqual(@as(usize, 2), bindings.next.len);
}
