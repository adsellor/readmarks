const std = @import("std");

pub fn element_text(
    source: []const u8,
    names: []const []const u8,
) ?[]const u8 {
    for (names) |name| {
        const start = find_open_tag(source, 0, name) orelse continue;
        const content_start = std.mem.indexOfScalarPos(u8, source, start, '>') orelse continue;
        const end = find_close_tag(source, content_start + 1, name) orelse continue;
        return source[content_start + 1 .. end];
    }
    return null;
}

pub fn find_open_tag(
    source: []const u8,
    start: usize,
    name: []const u8,
) ?usize {
    var cursor = start;
    while (find_ignore_case_from(source, "<", cursor)) |index| {
        if (starts_with_tag(source[index..], name)) return index;
        cursor = index + 1;
    }
    return null;
}

pub fn starts_with_tag(source: []const u8, name: []const u8) bool {
    if (source.len < name.len + 1) return false;
    if (source[0] != '<') return false;
    if (!std.ascii.startsWithIgnoreCase(source[1..], name)) return false;
    if (source.len == name.len + 1) return true;
    return std.ascii.isWhitespace(source[name.len + 1]) or
        source[name.len + 1] == '>' or
        source[name.len + 1] == '/';
}

pub fn find_close_tag(
    source: []const u8,
    start: usize,
    name: []const u8,
) ?usize {
    var pattern: [64]u8 = undefined;
    const close = std.fmt.bufPrint(&pattern, "</{s}", .{name}) catch return null;
    return find_ignore_case_from(source, close, start);
}

pub fn attribute_value(tag: []const u8, name: []const u8) ?[]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(tag.len <= std.math.maxInt(u32));
    var cursor: usize = 0;
    while (find_ignore_case_from(tag, name, cursor)) |start| {
        var index = start + name.len;
        while (index < tag.len and std.ascii.isWhitespace(tag[index])) index += 1;
        if (index >= tag.len or tag[index] != '=') {
            cursor = start + name.len;
            continue;
        }
        index += 1;
        while (index < tag.len and std.ascii.isWhitespace(tag[index])) index += 1;
        if (index >= tag.len) return null;
        if (tag[index] != '"' and tag[index] != '\'') return null;
        const quote = tag[index];
        const end = std.mem.indexOfScalarPos(u8, tag, index + 1, quote) orelse return null;
        return tag[index + 1 .. end];
    }
    return null;
}

pub fn find_ignore_case_from(
    source: []const u8,
    needle: []const u8,
    start: usize,
) ?usize {
    if (needle.len == 0) return start;
    if (start >= source.len) return null;
    var index = start;
    while (index + needle.len <= source.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(source[index..][0..needle.len], needle)) return index;
    }
    return null;
}

test "XML navigation handles elements, namespaces, and attributes" {
    const source =
        \\<entry><content:encoded><![CDATA[Hello]]></content:encoded>
        \\<link rel="alternate" href="https://example.com"/></entry>
    ;
    const content = element_text(source, &.{"content:encoded"}).?;
    try std.testing.expectEqualStrings("<![CDATA[Hello]]>", content);
    const link_start = find_open_tag(source, 0, "link").?;
    const link_end = std.mem.indexOfScalarPos(u8, source, link_start, '>').?;
    const link = source[link_start .. link_end + 1];
    try std.testing.expectEqualStrings(
        "https://example.com",
        attribute_value(link, "href").?,
    );
}
