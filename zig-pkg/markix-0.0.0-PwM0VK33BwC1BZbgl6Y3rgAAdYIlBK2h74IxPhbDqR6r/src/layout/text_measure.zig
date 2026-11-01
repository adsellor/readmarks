const std = @import("std");
const text_width = @import("../backend/terminal/text_width.zig");
const inline_layout = @import("inline_layout.zig");

pub const Line = struct {
    /// The bytes on this line, excluding the break.
    text: []const u8,
    /// Offset the next line starts at, with the break consumed.
    next: usize,
};

/// The line beginning at `offset`, broken at the last space that fits and
/// split mid-word only when a word cannot fit on a line of its own.
pub fn next_line(value: []const u8, offset: usize, width: u16) Line {
    if (offset >= value.len or width == 0) {
        return .{ .text = value[value.len..], .next = value.len };
    }
    std.debug.assert(offset < value.len);
    std.debug.assert(width > 0);
    const remaining = value[offset..];
    // Clip by columns so a multi-byte character is never cut in half.
    const window = text_width.clip(remaining, width);
    if (window.len == remaining.len) {
        return .{ .text = remaining, .next = value.len };
    }
    var length = window.len;
    if (std.mem.lastIndexOfScalar(u8, window, ' ')) |space| {
        if (space > 0) length = space;
    }
    var next = offset + length;
    while (next < value.len and value[next] == ' ') next += 1;
    return .{ .text = value[offset .. offset + length], .next = next };
}

/// Rows `value` occupies when wrapped at `width`. Empty text still occupies a
/// row, because a blank line is a line.
pub fn wrapped_rows(value: []const u8, width: u16) u16 {
    // Delegates so that measuring and flowing can never disagree: a paragraph
    // is measured by exactly the code that later places its pieces.
    return inline_layout.rows(&.{.{ .text = value }}, width);
}

/// Longest prefix of `value` that fits in `columns`, never splitting a
/// multi-byte character.
pub fn clip_columns(value: []const u8, columns: u16) []const u8 {
    return text_width.clip(value, columns);
}

/// Rows a block of pre-formatted text occupies: its own newlines, no wrapping.
pub fn literal_rows(value: []const u8) u16 {
    var rows: u16 = 1;
    for (value) |byte| {
        if (byte == '\n') rows +|= 1;
    }
    return rows;
}

test "text shorter than the column is one line" {
    try std.testing.expectEqual(@as(u16, 1), wrapped_rows("hello", 40));
    try std.testing.expectEqual(@as(u16, 1), wrapped_rows("", 40));
}

test "breaks fall on spaces and consume them" {
    const value = "the quick brown fox";
    const first = next_line(value, 0, 10);
    try std.testing.expectEqualStrings("the quick", first.text);
    const second = next_line(value, first.next, 10);
    try std.testing.expectEqualStrings("brown fox", second.text);
    try std.testing.expectEqual(value.len, second.next);
}

test "a word longer than the column is split rather than looping" {
    const long = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expectEqual(@as(u16, 3), wrapped_rows(long, 10));
}

test "wrapping always advances" {
    const value = "the quick brown fox jumps over the lazy dog";
    var offset: usize = 0;
    var guard: u16 = 0;
    while (offset < value.len) : (guard += 1) {
        const line = next_line(value, offset, 7);
        try std.testing.expect(line.next > offset);
        offset = line.next;
        try std.testing.expect(guard < 200);
    }
}

test "zero width neither divides by zero nor loops" {
    try std.testing.expectEqual(@as(u16, 1), wrapped_rows("anything", 0));
    const line = next_line("anything", 0, 0);
    try std.testing.expectEqual(@as(usize, 8), line.next);
}

test "multi byte characters are not split" {
    // Three-byte characters: clipping by columns must land on a boundary.
    const value = "日本語テキスト";
    const line = next_line(value, 0, 4);
    try std.testing.expect(std.unicode.utf8ValidateSlice(line.text));
    try std.testing.expect(line.text.len % 3 == 0);
}

test "literal rows count newlines" {
    try std.testing.expectEqual(@as(u16, 1), literal_rows("one"));
    try std.testing.expectEqual(@as(u16, 3), literal_rows("one\ntwo\nthree"));
}
