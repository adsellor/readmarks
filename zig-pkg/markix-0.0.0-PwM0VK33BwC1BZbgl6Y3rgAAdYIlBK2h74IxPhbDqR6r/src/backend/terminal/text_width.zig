const std = @import("std");

pub fn clip(text: []const u8, max_columns: u16) []const u8 {
    std.debug.assert(text.len <= std.math.maxInt(u32));
    std.debug.assert(max_columns <= std.math.maxInt(u16));
    if (max_columns == 0 or text.len == 0) return text[0..0];
    var columns_used: u16 = 0;
    var index: usize = 0;
    var boundary: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte < 0x80) {
            if (columns_used == max_columns) break;
            columns_used += 1;
            index += 1;
            boundary = index;
            continue;
        }
        const sequence = std.unicode.utf8ByteSequenceLength(byte) catch break;
        if (index + sequence > text.len) break;
        const codepoint = std.unicode.utf8Decode(text[index..][0..sequence]) catch break;
        const width = codepoint_width(codepoint);
        if (columns_used + width > max_columns) break;
        columns_used += width;
        index += sequence;
        boundary = index;
    }
    return text[0..boundary];
}

pub fn columns(text: []const u8) u16 {
    std.debug.assert(text.len <= std.math.maxInt(u32));
    std.debug.assert(std.unicode.utf8ValidateSlice(text) or text.len > 0 or text.len == 0);
    var count: u16 = 0;
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte < 0x80) {
            count += 1;
            index += 1;
            continue;
        }
        const sequence = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        if (index + sequence > text.len) {
            count += 1;
            index += 1;
            continue;
        }
        const codepoint = std.unicode.utf8Decode(text[index..][0..sequence]) catch {
            count += 1;
            index += 1;
            continue;
        };
        count += codepoint_width(codepoint);
        index += sequence;
    }
    return count;
}

fn codepoint_width(codepoint: u21) u16 {
    if (is_combining(codepoint)) return 0;
    if (is_wide(codepoint)) return 2;
    return 1;
}

fn is_combining(codepoint: u21) bool {
    std.debug.assert(codepoint <= 0x10FFFF);
    std.debug.assert(codepoint >= 0);
    return in_range(codepoint, 0x0300, 0x036F) or
        in_range(codepoint, 0x0483, 0x0489) or
        in_range(codepoint, 0x0591, 0x05BD) or
        in_range(codepoint, 0x064B, 0x065F) or
        in_range(codepoint, 0x0670, 0x0670) or
        in_range(codepoint, 0x06D6, 0x06ED) or
        in_range(codepoint, 0x0711, 0x0711) or
        in_range(codepoint, 0x0730, 0x074A) or
        in_range(codepoint, 0x07A6, 0x07B0) or
        in_range(codepoint, 0x0816, 0x082D) or
        in_range(codepoint, 0x1AB0, 0x1AFF) or
        in_range(codepoint, 0x1DC0, 0x1DFF) or
        in_range(codepoint, 0x20D0, 0x20FF) or
        in_range(codepoint, 0xFE20, 0xFE2F) or
        in_range(codepoint, 0x3099, 0x309A);
}

fn is_wide(codepoint: u21) bool {
    std.debug.assert(codepoint <= 0x10FFFF);
    std.debug.assert(codepoint >= 0);
    return in_range(codepoint, 0x1100, 0x115F) or
        in_range(codepoint, 0x2E80, 0x303E) or
        in_range(codepoint, 0x3041, 0x33FF) or
        in_range(codepoint, 0x3400, 0x4DBF) or
        in_range(codepoint, 0x4E00, 0x9FFF) or
        in_range(codepoint, 0xA000, 0xA4CF) or
        in_range(codepoint, 0xA960, 0xA97F) or
        in_range(codepoint, 0xAC00, 0xD7A3) or
        in_range(codepoint, 0xF900, 0xFAFF) or
        in_range(codepoint, 0xFE30, 0xFE4F) or
        in_range(codepoint, 0xFF00, 0xFF60) or
        in_range(codepoint, 0xFFE0, 0xFFE6) or
        in_range(codepoint, 0x20000, 0x2FFFD) or
        in_range(codepoint, 0x30000, 0x3FFFD);
}

fn in_range(codepoint: u21, start: u21, end: u21) bool {
    return codepoint >= start and codepoint <= end;
}

test "ascii text fits exactly" {
    try std.testing.expectEqualStrings("hello", clip("hello world", 5));
    try std.testing.expectEqualStrings("hello world", clip("hello world", 11));
}

test "clip never splits a codepoint" {
    try std.testing.expectEqualStrings("curly ’", clip("curly ’quote’", 7));
    try std.testing.expectEqualStrings("’", clip("’", 1));
    try std.testing.expectEqualStrings("", clip("’", 0));
}

test "combining characters occupy no columns" {
    try std.testing.expectEqual(@as(u16, 1), columns("e\u{0301}"));
    try std.testing.expectEqualStrings("e\u{0301}", clip("e\u{0301}x", 1));
}

test "cjk characters occupy two columns" {
    try std.testing.expectEqual(@as(u16, 2), columns("文"));
    try std.testing.expectEqualStrings("", clip("文", 1));
    try std.testing.expectEqualStrings("a文", clip("a文b", 3));
    try std.testing.expectEqualStrings("a文b", clip("a文b", 4));
}

test "em dash and smart quotes are single width" {
    try std.testing.expectEqual(@as(u16, 1), columns("—"));
    try std.testing.expectEqual(@as(u16, 1), columns("”"));
    try std.testing.expectEqualStrings("a—b", clip("a—bcd", 3));
}

test "columns counts codepoints not bytes" {
    try std.testing.expectEqual(@as(u16, 4), columns("café"));
    try std.testing.expectEqual(@as(u16, 3), columns("abc"));
}
