//! The application's bindings, written down once.
//!
//! `shared` is the contract: those keys do the same thing in both experiences
//! and neither may redefine them. Each experience then adds only what is
//! genuinely its own. The help sheet is rendered from these tables, so a
//! binding that is not listed here is a binding the user cannot discover.

const std = @import("std");

pub const Entry = struct {
    key: []const u8,
    label: []const u8 = "",

    fn heading(text: []const u8) Entry {
        return .{ .key = text };
    }

    pub fn is_heading(self: Entry) bool {
        return self.label.len == 0;
    }
};

const heading = Entry.heading;

/// Labels are kept inside `label_width_max` so the sheet never clips one. A
/// binding the user can only half read is barely better than an undocumented
/// one, and the key column beside it already carries most of the meaning.
pub const label_width_max: usize = 30;

pub const shared = [_]Entry{
    heading("MOVING"),
    .{ .key = "j/k, arrows", .label = "move the selection" },
    .{ .key = "h/l, tab", .label = "move between panes" },
    .{ .key = "g/G, home/end", .label = "first / last row" },
    .{ .key = "ctrl-b/f", .label = "move by a page" },
    heading("FINDING"),
    .{ .key = ":  ctrl-p", .label = "command centre" },
    .{ .key = "/", .label = "search the focused pane" },
    .{ .key = "z", .label = "zen mode" },
    .{ .key = "1 / 2", .label = "all / shortlist" },
    heading("ACTING"),
    .{ .key = "enter", .label = "open the selection" },
    .{ .key = "o", .label = "open it in the browser" },
    .{ .key = "a", .label = "add" },
    .{ .key = "r", .label = "refresh" },
    .{ .key = "d, d", .label = "delete the selection" },
    heading("EVERYWHERE"),
    .{ .key = "ctrl-u", .label = "reader / bookmarks" },
    .{ .key = "?", .label = "show this sheet" },
    .{ .key = "esc", .label = "close, or clear the search" },
    .{ .key = "q, ctrl-c", .label = "quit" },
};

pub const reader = [_]Entry{
    heading("READING"),
    .{ .key = "v", .label = "full-screen reader" },
    .{ .key = "[ / ]", .label = "previous / next page" },
    .{ .key = "i", .label = "open the article image" },
    .{ .key = "m", .label = "toggle read" },
    .{ .key = "M", .label = "mark everything read" },
    .{ .key = "b", .label = "save to bookmarks" },
    .{ .key = "c", .label = "collapse the pane" },
    heading("FEEDS"),
    .{ .key = "R", .label = "refresh every feed" },
    .{ .key = "P, P", .label = "prune failed feeds" },
};

pub const bookmarker = [_]Entry{
    heading("BOOKMARKS"),
    .{ .key = "f", .label = "toggle favourite" },
    .{ .key = "v", .label = "preview on its own" },
};

/// Rows the sheet needs for an experience, so the surface can be sized before
/// it is mounted.
pub fn row_count(own: []const Entry) u16 {
    return @intCast(shared.len + own.len);
}

test "no experience redefines a shared key" {
    for ([_][]const Entry{ &reader, &bookmarker }) |own| {
        for (own) |entry| {
            if (entry.is_heading()) continue;
            for (shared) |common| {
                if (common.is_heading()) continue;
                try std.testing.expect(!std.mem.eql(u8, entry.key, common.key));
            }
        }
    }
}

test "every non-heading entry explains itself" {
    for ([_][]const Entry{ &shared, &reader, &bookmarker }) |table| {
        for (table) |entry| {
            try std.testing.expect(entry.key.len > 0);
        }
    }
}

test "no label is wider than the sheet's column" {
    for ([_][]const Entry{ &shared, &reader, &bookmarker }) |table| {
        for (table) |entry| {
            try std.testing.expect(entry.label.len <= label_width_max);
        }
    }
}
