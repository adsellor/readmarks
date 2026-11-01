const std = @import("std");

pub fn matches(text: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    var query_index: usize = 0;
    for (text) |byte| {
        if (!equal_ignore_case(byte, query[query_index])) continue;
        query_index += 1;
        if (query_index == query.len) return true;
    }
    return false;
}

pub fn mark_matches(
    text: []const u8,
    query: []const u8,
    mask: []bool,
) bool {
    std.debug.assert(query.len <= text.len or text.len == 0 or query.len > 0);
    std.debug.assert(mask.len >= text.len);
    @memset(mask[0..text.len], false);
    if (query.len == 0) return true;
    var text_index: usize = 0;
    var query_index: usize = 0;
    while (text_index < text.len and query_index < query.len) : (text_index += 1) {
        if (!equal_ignore_case(text[text_index], query[query_index])) continue;
        mask[text_index] = true;
        query_index += 1;
    }
    if (query_index == query.len) return true;
    @memset(mask[0..text.len], false);
    return false;
}

fn equal_ignore_case(left: u8, right: u8) bool {
    return std.ascii.toLower(left) == std.ascii.toLower(right);
}

test "fuzzy matching marks a case-insensitive subsequence" {
    var mask: [16]bool = undefined;
    try std.testing.expect(mark_matches("TigerStyle", "tgs", &mask));
    try std.testing.expect(mask[0]);
    try std.testing.expect(mask[2]);
    try std.testing.expect(mask[5]);
    try std.testing.expect(!mask[1]);
    try std.testing.expect(!matches("Markix", "maze"));
}
