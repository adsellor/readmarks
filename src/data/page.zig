const std = @import("std");
const http = @import("http.zig");
const limits = @import("limits.zig");
const FixedText = @import("bookmarks/fixed_text.zig").FixedText;

pub const PageTitle = FixedText(limits.bookmark_title_bytes_max);
pub const Description = FixedText(limits.bookmark_description_bytes_max);
pub const Preview = FixedText(limits.bookmark_preview_bytes_max);

pub const Metadata = struct {
    title: PageTitle = .{},
    description: Description = .{},
    preview: Preview = .{},
};

pub const Fetcher = struct {
    client: std.http.Client,
    response: [limits.page_response_bytes_max]u8 = undefined,
    redirect_buffer: [8 * 1_024]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Fetcher {
        return .{ .client = .{ .allocator = allocator, .io = io } };
    }

    pub fn deinit(self: *Fetcher) void {
        self.client.deinit();
    }

    pub fn fetch(self: *Fetcher, url: []const u8) !Metadata {
        if (!std.mem.startsWith(u8, url, "http://") and
            !std.mem.startsWith(u8, url, "https://"))
        {
            return error.UnsupportedPageScheme;
        }
        var writer = std.Io.Writer.fixed(&self.response);
        const result = try http.fetch(&self.client, .{
            .url = url,
            .response_writer = &writer,
            .redirect_buffer = &self.redirect_buffer,
            .user_agent = "markix/0.1",
        });
        if (result.status.class() != .success) return error.PageRequestFailed;
        return parse(writer.buffered());
    }
};

pub fn parse(html: []const u8) Metadata {
    var metadata = Metadata{};
    extract_title(html, &metadata.title);
    extract_description(html, &metadata.description);
    extract_preview(html, &metadata.preview);
    return metadata;
}

fn extract_title(html: []const u8, output: *PageTitle) void {
    const title_start = find_ignore_case(html, "<title") orelse return;
    const content_start = std.mem.indexOfScalarPos(u8, html, title_start, '>') orelse return;
    const title_end = find_ignore_case_from(html, "</title", content_start + 1) orelse return;
    extract_plain_text(html[content_start + 1 .. title_end], output);
}

fn extract_description(html: []const u8, output: *Description) void {
    var cursor: usize = 0;
    while (find_ignore_case_from(html, "<meta", cursor)) |start| {
        const end = std.mem.indexOfScalarPos(u8, html, start, '>') orelse return;
        const tag = html[start .. end + 1];
        if (is_description_meta(tag)) {
            const content = attribute_value(tag, "content") orelse return;
            extract_plain_text(content, output);
            return;
        }
        cursor = end + 1;
    }
}

fn is_description_meta(tag: []const u8) bool {
    const name = attribute_value(tag, "name");
    const property = attribute_value(tag, "property");
    if (name) |value| {
        if (std.ascii.eqlIgnoreCase(value, "description")) return true;
    }
    if (property) |value| {
        if (std.ascii.eqlIgnoreCase(value, "og:description")) return true;
    }
    return false;
}

fn attribute_value(tag: []const u8, name: []const u8) ?[]const u8 {
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
        if (index >= tag.len or (tag[index] != '"' and tag[index] != '\'')) return null;
        const quote = tag[index];
        const end = std.mem.indexOfScalarPos(u8, tag, index + 1, quote) orelse return null;
        return tag[index + 1 .. end];
    }
    return null;
}

fn extract_preview(html: []const u8, output: *Preview) void {
    const source = preferred_content(html);
    var index: usize = 0;
    var ignored_depth: u8 = 0;
    while (index < source.len and output.length < output.buffer.len) {
        if (source[index] == '<') {
            const end = std.mem.indexOfScalarPos(u8, source, index, '>') orelse break;
            const tag = source[index + 1 .. end];
            update_ignored_depth(tag, &ignored_depth);
            if (ignored_depth == 0 and is_block_tag(tag)) append_space(output);
            index = end + 1;
            continue;
        }
        if (ignored_depth > 0) {
            index += 1;
            continue;
        }
        index += append_text_byte(source[index..], output);
    }
    trim_output(output);
}

fn preferred_content(html: []const u8) []const u8 {
    const tags = [_][]const u8{ "<main", "<article", "<body" };
    for (tags) |tag| {
        const start = find_ignore_case(html, tag) orelse continue;
        const content_start = std.mem.indexOfScalarPos(u8, html, start, '>') orelse continue;
        return html[content_start + 1 ..];
    }
    return html;
}

fn update_ignored_depth(tag: []const u8, depth: *u8) void {
    const name = tag_name(tag);
    if (!is_ignored_tag(name.value)) return;
    if (name.closing) {
        depth.* -|= 1;
    } else if (!name.self_closing) {
        depth.* +|= 1;
    }
}

const TagName = struct {
    value: []const u8,
    closing: bool,
    self_closing: bool,
};

fn tag_name(tag: []const u8) TagName {
    var start: usize = 0;
    while (start < tag.len and std.ascii.isWhitespace(tag[start])) start += 1;
    const closing = start < tag.len and tag[start] == '/';
    if (closing) start += 1;
    const end = std.mem.indexOfAnyPos(u8, tag, start, " \t\r\n/>") orelse tag.len;
    return .{
        .value = tag[start..end],
        .closing = closing,
        .self_closing = tag.len > 0 and tag[tag.len - 1] == '/',
    };
}

fn is_ignored_tag(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "script") or
        std.ascii.eqlIgnoreCase(name, "style") or
        std.ascii.eqlIgnoreCase(name, "noscript") or
        std.ascii.eqlIgnoreCase(name, "svg");
}

fn is_block_tag(tag: []const u8) bool {
    const name = tag_name(tag).value;
    const blocks = [_][]const u8{
        "p",  "div", "br", "li", "article", "section", "header", "footer",
        "h1", "h2",  "h3", "h4", "h5",      "h6",      "tr",
    };
    for (blocks) |block| {
        if (std.ascii.eqlIgnoreCase(name, block)) return true;
    }
    return false;
}

fn extract_plain_text(source: []const u8, output: anytype) void {
    var index: usize = 0;
    while (index < source.len and output.length < output.buffer.len) {
        if (source[index] == '<') {
            const end = std.mem.indexOfScalarPos(u8, source, index, '>') orelse break;
            index = end + 1;
            continue;
        }
        index += append_text_byte(source[index..], output);
    }
    trim_output(output);
}

fn append_text_byte(source: []const u8, output: anytype) usize {
    std.debug.assert(source.len > 0);
    if (source[0] == '&') {
        if (decode_entity(source)) |entity| {
            append_normalized(output, entity.byte);
            return entity.consumed;
        }
    }
    append_normalized(output, source[0]);
    return 1;
}

const Entity = struct { byte: u8, consumed: usize };

fn decode_entity(source: []const u8) ?Entity {
    const entities = [_]struct { encoded: []const u8, decoded: u8 }{
        .{ .encoded = "&amp;", .decoded = '&' },
        .{ .encoded = "&lt;", .decoded = '<' },
        .{ .encoded = "&gt;", .decoded = '>' },
        .{ .encoded = "&quot;", .decoded = '"' },
        .{ .encoded = "&#39;", .decoded = '\'' },
        .{ .encoded = "&nbsp;", .decoded = ' ' },
    };
    for (entities) |entity| {
        if (std.mem.startsWith(u8, source, entity.encoded)) {
            return .{ .byte = entity.decoded, .consumed = entity.encoded.len };
        }
    }
    return null;
}

fn append_normalized(output: anytype, byte: u8) void {
    if (std.ascii.isWhitespace(byte)) {
        append_space(output);
    } else if (output.length < output.buffer.len) {
        output.buffer[output.length] = byte;
        output.length += 1;
    }
}

fn append_space(output: anytype) void {
    if (output.length == 0) return;
    if (output.buffer[output.length - 1] == ' ') return;
    if (output.length >= output.buffer.len) return;
    output.buffer[output.length] = ' ';
    output.length += 1;
}

fn trim_output(output: anytype) void {
    while (output.length > 0 and output.buffer[output.length - 1] == ' ') {
        output.length -= 1;
    }
}

fn find_ignore_case(haystack: []const u8, needle: []const u8) ?usize {
    return find_ignore_case_from(haystack, needle, 0);
}

fn find_ignore_case_from(
    haystack: []const u8,
    needle: []const u8,
    start: usize,
) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var index = start;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index..][0..needle.len], needle)) {
            return index;
        }
    }
    return null;
}

test "page parser extracts title description and readable content" {
    const html =
        \\<html><head><title> Tiger &amp; Style </title>
        \\<meta name="description" content="Safety before speed."></head>
        \\<body><nav>Skip nav</nav><main><h1>Rules</h1>
        \\<p>Do the work.</p><script>ignore()</script></main></body></html>
    ;
    const metadata = parse(html);
    try std.testing.expectEqualStrings("Tiger & Style", metadata.title.bytes());
    try std.testing.expectEqualStrings("Safety before speed.", metadata.description.bytes());
    try std.testing.expectEqualStrings("Rules Do the work.", metadata.preview.bytes());
}
