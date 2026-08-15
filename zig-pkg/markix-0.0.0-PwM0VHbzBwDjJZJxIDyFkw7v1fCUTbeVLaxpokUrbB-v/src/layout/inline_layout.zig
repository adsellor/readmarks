const std = @import("std");
const text_width = @import("../backend/terminal/text_width.zig");

// Wraps a run of styled text into positioned pieces.
//
// A paragraph is not one box of text: it is a sequence of runs (plain, strong,
// a link) that flows across rows, and a single run can straddle a break. This
// resolves that flow to concrete row/column pieces so no backend has to wrap
// anything itself. A terminal draws each piece where it is told, and a browser
// renders each with `white-space: pre` -- both then agree with the layout,
// which is the only way a measured height can be trusted.
//
// Styling stays opaque: a run carries a caller-defined `id`, so this knows
// nothing about colours, fonts or markup.

pub const Run = struct {
    text: []const u8,
    /// Caller-defined tag, handed back on every piece the run produces.
    id: u16 = 0,
};

pub const Piece = struct {
    row: u16,
    column: u16,
    text: []const u8,
    id: u16,
};

pub const Result = struct {
    count: usize,
    rows: u16,
};

/// Flows `runs` into `width` columns, writing pieces into `out`.
///
/// Returns how many pieces were produced and how many rows they occupy.
/// Stops early rather than overflowing when `out` runs out.
pub fn wrap(runs: []const Run, width: u16, out: []Piece) Result {
    if (width == 0 or out.len == 0) return .{ .count = 0, .rows = 1 };
    std.debug.assert(width > 0);
    std.debug.assert(out.len > 0);
    var cursor = Cursor{ .width = width };
    var count: usize = 0;
    for (runs) |run| {
        var offset: usize = 0;
        while (offset < run.text.len) {
            if (count == out.len) return cursor.finish(count);
            const piece = cursor.take(run.text, offset) orelse break;
            if (piece.text.len > 0) {
                out[count] = .{
                    .row = piece.row,
                    .column = piece.column,
                    .text = piece.text,
                    .id = run.id,
                };
                count += 1;
            }
            offset = piece.next;
        }
    }
    return cursor.finish(count);
}

/// Rows the runs occupy, without materialising the pieces.
pub fn rows(runs: []const Run, width: u16) u16 {
    if (width == 0) return 1;
    var cursor = Cursor{ .width = width };
    for (runs) |run| {
        var offset: usize = 0;
        while (offset < run.text.len) {
            const piece = cursor.take(run.text, offset) orelse break;
            offset = piece.next;
        }
    }
    return cursor.finish(0).rows;
}

const Taken = struct {
    row: u16,
    column: u16,
    text: []const u8,
    next: usize,
};

const Cursor = struct {
    width: u16,
    row: u16 = 0,
    column: u16 = 0,

    fn finish(self: *const Cursor, count: usize) Result {
        return .{ .count = count, .rows = self.row + 1 };
    }

    fn take(self: *Cursor, text: []const u8, offset: usize) ?Taken {
        std.debug.assert(self.width > 0);
        std.debug.assert(self.column <= self.width);
        std.debug.assert(offset < text.len);
        var available = self.width -| self.column;
        if (available == 0) {
            self.newline();
            available = self.width;
        }
        std.debug.assert(available > 0);
        const remaining = text[offset..];
        if (remaining[0] == ' ' and self.column == 0) {
            return .{
                .row = self.row,
                .column = self.column,
                .text = remaining[0..0],
                .next = offset + 1,
            };
        }

        const window = text_width.clip(remaining, available);
        if (window.len == remaining.len) {
            const taken = Taken{
                .row = self.row,
                .column = self.column,
                .text = remaining,
                .next = text.len,
            };
            self.advance_columns(remaining);
            return taken;
        }
        return self.take_broken(text, offset, window);
    }

    fn take_broken(
        self: *Cursor,
        text: []const u8,
        offset: usize,
        window: []const u8,
    ) ?Taken {
        std.debug.assert(offset < text.len);
        std.debug.assert(window.len < text.len - offset);
        const remaining = text[offset..];
        var length = window.len;
        var consumed = length;
        var broke = false;
        if (std.mem.lastIndexOfScalar(u8, window, ' ')) |space| {
            length = space;
            consumed = space;
            while (offset + consumed < text.len and text[offset + consumed] == ' ') {
                consumed += 1;
            }
            broke = true;
        } else if (self.column > 0) {
            self.newline();
            return .{
                .row = self.row,
                .column = 0,
                .text = remaining[0..0],
                .next = offset,
            };
        }

        if (length == 0 and consumed == 0) {
            length = window.len;
            consumed = window.len;
            broke = false;
        }
        std.debug.assert(consumed > 0);

        const taken = Taken{
            .row = self.row,
            .column = self.column,
            .text = remaining[0..length],
            .next = offset + consumed,
        };

        if (broke) self.newline() else self.advance_columns(remaining[0..length]);
        return taken;
    }

    fn advance_columns(self: *Cursor, text: []const u8) void {
        std.debug.assert(self.column <= self.width);
        self.column +|= text_width.columns(text);
        if (self.column > self.width) self.column = self.width;
        std.debug.assert(self.column <= self.width);
    }

    fn newline(self: *Cursor) void {
        std.debug.assert(self.column <= self.width);
        self.row +|= 1;
        self.column = 0;
    }
};

test "a short run is one piece on one row" {
    var out: [8]Piece = undefined;
    const result = wrap(&.{.{ .text = "hello" }}, 20, &out);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqual(@as(u16, 1), result.rows);
    try std.testing.expectEqualStrings("hello", out[0].text);
    try std.testing.expectEqual(@as(u16, 0), out[0].column);
}

test "runs flow one after another on the same row" {
    var out: [8]Piece = undefined;
    const result = wrap(&.{
        .{ .text = "see ", .id = 0 },
        .{ .text = "the docs", .id = 1 },
        .{ .text = " now", .id = 0 },
    }, 40, &out);
    try std.testing.expectEqual(@as(usize, 3), result.count);
    try std.testing.expectEqual(@as(u16, 1), result.rows);
    try std.testing.expectEqual(@as(u16, 0), out[0].column);
    try std.testing.expectEqual(@as(u16, 4), out[1].column);
    try std.testing.expectEqual(@as(u16, 1), out[1].id);
    try std.testing.expectEqual(@as(u16, 12), out[2].column);
}

test "a run that straddles a break becomes two pieces" {
    var out: [8]Piece = undefined;
    const result = wrap(&.{.{ .text = "the quick brown fox", .id = 7 }}, 10, &out);
    try std.testing.expect(result.rows >= 2);
    try std.testing.expectEqual(@as(u16, 0), out[0].row);
    try std.testing.expectEqual(@as(u16, 1), out[1].row);
    try std.testing.expectEqual(@as(u16, 0), out[1].column);
    // Style survives the break.
    for (out[0..result.count]) |piece| {
        try std.testing.expectEqual(@as(u16, 7), piece.id);
    }
}

test "no piece ever exceeds the column budget" {
    var out: [64]Piece = undefined;
    const result = wrap(&.{
        .{ .text = "the quick brown fox jumps over the lazy dog and keeps going" },
    }, 12, &out);
    for (out[0..result.count]) |piece| {
        try std.testing.expect(piece.column + piece.text.len <= 12);
    }
}

test "rows agrees with the pieces produced" {
    const runs = [_]Run{
        .{ .text = "some text that will " },
        .{ .text = "definitely" },
        .{ .text = " need to wrap more than once at this width" },
    };
    var out: [64]Piece = undefined;
    const result = wrap(&runs, 16, &out);
    try std.testing.expectEqual(result.rows, rows(&runs, 16));
    var highest: u16 = 0;
    for (out[0..result.count]) |piece| highest = @max(highest, piece.row);
    try std.testing.expectEqual(result.rows, highest + 1);
}

test "a word longer than the width is split rather than looping" {
    var out: [32]Piece = undefined;
    const result = wrap(&.{.{ .text = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }}, 10, &out);
    try std.testing.expectEqual(@as(u16, 3), result.rows);
    try std.testing.expectEqual(@as(usize, 3), result.count);
}

test "output that runs out stops instead of overflowing" {
    var out: [2]Piece = undefined;
    const result = wrap(&.{
        .{ .text = "one two three four five six seven eight nine ten eleven" },
    }, 8, &out);
    try std.testing.expect(result.count <= out.len);
}

test "multi byte text advances by columns, not bytes" {
    // Clipping measures display width while the cursor used to advance by
    // byte length, so a curly apostrophe -- three bytes, one column -- drove
    // the cursor past the end of the row and the next subtraction underflowed.
    var out: [64]Piece = undefined;
    const text = "it\u{2019}s a test of text that is long enough to wrap twice over";
    const result = wrap(&.{.{ .text = text }}, 20, &out);
    try std.testing.expect(result.rows >= 3);
    for (out[0..result.count]) |piece| {
        try std.testing.expect(piece.column < 20);
        try std.testing.expect(piece.column + text_width.columns(piece.text) <= 20);
    }
}

test "a run of wide characters stays inside the row" {
    var out: [64]Piece = undefined;
    const wide = "日本語のテキスト";
    const result = wrap(&.{.{ .text = wide }}, 12, &out);
    try std.testing.expect(result.count > 0);
    for (out[0..result.count]) |piece| {
        try std.testing.expect(piece.column <= 12);
        try std.testing.expect(std.unicode.utf8ValidateSlice(piece.text));
    }
}

test "wrapping loses no word and fuses none together" {
    const text = "to me. For me it is simple: I hate being the worst at" ++
        " something, and I cannot stand the idea of being the best either.";
    var out: [64]Piece = undefined;
    const longest_word = 10;
    var width: u16 = longest_word + 1;
    while (width <= 63) : (width += 1) {
        const result = wrap(&.{.{ .text = text }}, width, &out);

        var rebuilt: [512]u8 = undefined;
        var length: usize = 0;
        var previous: ?u16 = null;
        for (out[0..result.count]) |piece| {
            // NOTE: A row change is where a space was consumed; put it back.
            if (previous) |row| {
                if (piece.row != row) {
                    rebuilt[length] = ' ';
                    length += 1;
                }
            }
            @memcpy(rebuilt[length..][0..piece.text.len], piece.text);
            length += piece.text.len;
            previous = piece.row;
        }
        try std.testing.expectEqualStrings(text, rebuilt[0..length]);
    }
}

test "a run is one piece per row, never two side by side" {
    var out: [64]Piece = undefined;
    const result = wrap(&.{
        .{ .text = "one two three four five six seven eight nine ten eleven twelve" },
    }, 20, &out);
    try std.testing.expect(result.count > 2);
    var previous: ?u16 = null;
    for (out[0..result.count]) |piece| {
        if (previous) |row| try std.testing.expectEqual(row + 1, piece.row);
        previous = piece.row;
    }
}

test "zero width is handled" {
    var out: [4]Piece = undefined;
    const result = wrap(&.{.{ .text = "text" }}, 0, &out);
    try std.testing.expectEqual(@as(usize, 0), result.count);
    try std.testing.expectEqual(@as(u16, 1), rows(&.{.{ .text = "text" }}, 0));
}
