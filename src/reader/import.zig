const std = @import("std");
const xml = @import("markix").xml;
const limits = @import("limits.zig");
const model = @import("model.zig");
const subscriptions = @import("subscriptions.zig");

// Reading other tools' subscription lists.
//
// Every format here says the same two things -- a feed URL and the group it
// belongs to -- in its own way, so each parser's whole job is to find those two
// and hand them to `subscriptions.make_feed`. Importing appends to the feed
// list already in hand and skips URLs that are in it, so running an import
// twice is not a way to end up with everything twice.

pub const Format = enum {
    /// Decided from the file's contents.
    auto,
    /// An OPML outline, which is what most readers export.
    opml,
    /// Newsboat's `urls`: a URL, then positional tags, `~` naming a title.
    newsboat,
    /// One URL per line, nothing else.
    list,
    /// readmarks' own format, for merging one feed list into another.
    readmarks,

    pub fn parse(name: []const u8) ?Format {
        inline for (@typeInfo(Format).@"enum".field_names) |field| {
            if (std.mem.eql(u8, name, field)) return @field(Format, field);
        }
        return null;
    }
};

pub const Result = struct {
    added: u16 = 0,
    /// Feeds already in the list, matched by URL.
    duplicates: u16 = 0,
    /// Entries that carried no usable feed URL.
    skipped: u16 = 0,
    format: Format = .auto,
};

/// Guesses the format from what the file starts with. OPML announces itself;
/// newsboat and a plain list differ only in whether a line says more than a
/// URL, and the newsboat parser reads a plain list correctly either way.
pub fn detect(source: []const u8) Format {
    const head = source[0..@min(source.len, 512)];
    if (xml.find_ignore_case_from(head, "<opml", 0) != null) return .opml;
    if (std.mem.startsWith(u8, std.mem.trimStart(u8, head, " \t\r\n"), "<?xml")) {
        return .opml;
    }
    if (std.mem.indexOf(u8, head, "category=") != null) return .readmarks;
    return .newsboat;
}

/// Appends the feeds `source` describes to `feeds`, which already holds
/// `feed_count` of them. Returns what it did, including what it left out.
pub fn merge(
    source: []const u8,
    format: Format,
    feeds: *[limits.feed_count_max]model.Feed,
    feed_count: *u16,
) !Result {
    const resolved = if (format == .auto) detect(source) else format;
    var result = Result{ .format = resolved };
    switch (resolved) {
        .auto => unreachable,
        .opml => try merge_opml(source, feeds, feed_count, &result),
        .newsboat, .list => try merge_newsboat(source, feeds, feed_count, &result),
        .readmarks => try merge_readmarks(source, feeds, feed_count, &result),
    }
    return result;
}

fn merge_newsboat(
    source: []const u8,
    feeds: *[limits.feed_count_max]model.Feed,
    feed_count: *u16,
    result: *Result,
) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const entry = parse_newsboat_line(line);
        const feed = subscriptions.make_feed_titled(
            entry.url,
            entry.category,
            entry.title,
        ) catch {
            result.skipped += 1;
            continue;
        };
        try append(feeds, feed_count, feed, result);
    }
}

const NewsboatEntry = struct {
    url: []const u8,
    category: []const u8 = "",
    title: []const u8 = "",
};

/// `url tag "another tag" "~Display title"`, where the first tag names the
/// group and a `~` token names the feed.
fn parse_newsboat_line(line: []const u8) NewsboatEntry {
    var entry = NewsboatEntry{ .url = "" };
    var rest = line;
    entry.url = take_token(&rest) orelse return entry;
    while (take_token(&rest)) |token| {
        if (token.len > 0 and token[0] == '~') {
            if (entry.title.len == 0) entry.title = token[1..];
            continue;
        }
        // Newsboat's own directives are not tags.
        if (std.mem.startsWith(u8, token, "!")) continue;
        if (entry.category.len == 0) entry.category = token;
    }
    return entry;
}

/// The next whitespace-separated token, with a quoted token taken whole.
fn take_token(rest: *[]const u8) ?[]const u8 {
    var index: usize = 0;
    while (index < rest.len and (rest.*[index] == ' ' or rest.*[index] == '\t')) {
        index += 1;
    }
    rest.* = rest.*[index..];
    if (rest.len == 0) return null;
    if (rest.*[0] == '"') {
        const end = std.mem.indexOfScalarPos(u8, rest.*, 1, '"') orelse {
            const token = rest.*[1..];
            rest.* = rest.*[rest.len..];
            return token;
        };
        const token = rest.*[1..end];
        rest.* = rest.*[end + 1 ..];
        return token;
    }
    const end = std.mem.indexOfAny(u8, rest.*, " \t") orelse rest.len;
    const token = rest.*[0..end];
    rest.* = rest.*[end..];
    return token;
}

fn merge_readmarks(
    source: []const u8,
    feeds: *[limits.feed_count_max]model.Feed,
    feed_count: *u16,
    result: *Result,
) !void {
    var parsed: [limits.feed_count_max]model.Feed = undefined;
    const loaded = try subscriptions.parse(source, &parsed);
    result.skipped += loaded.skipped;
    var index: u16 = 0;
    while (index < loaded.count) : (index += 1) {
        try append(feeds, feed_count, parsed[index], result);
    }
}

/// OPML nests feeds under group outlines: an outline with an `xmlUrl` is a
/// feed, and one without opens a group that names the feeds inside it until it
/// closes. Anything deeper than a group is flattened into the group holding
/// it, because a category here is one name, not a path.
fn merge_opml(
    source: []const u8,
    feeds: *[limits.feed_count_max]model.Feed,
    feed_count: *u16,
    result: *Result,
) !void {
    var groups: [group_depth_max][]const u8 = @splat("");
    var depth: u8 = 0;
    var cursor: usize = 0;
    while (next_tag(source, cursor)) |tag| {
        cursor = tag.end;
        if (tag.closing) {
            if (depth > 0) depth -= 1;
            continue;
        }
        const url = attribute(tag.bytes, &.{ "xmlUrl", "xmlurl", "url" });
        if (url) |value| {
            const title = attribute(tag.bytes, &.{ "title", "text" }) orelse "";
            const feed = subscriptions.make_feed_titled(
                std.mem.trim(u8, value, " \t"),
                current_group(&groups, depth),
                opml_title(title, value),
            ) catch {
                result.skipped += 1;
                continue;
            };
            try append(feeds, feed_count, feed, result);
            continue;
        }
        // A group outline. A self-closing one holds nothing, so it opens
        // nothing either.
        if (tag.self_closing) continue;
        const name = attribute(tag.bytes, &.{ "title", "text" }) orelse "";
        if (depth < group_depth_max) groups[depth] = name;
        depth +|= 1;
    }
}

const group_depth_max: u8 = 8;

fn current_group(groups: *const [group_depth_max][]const u8, depth: u8) []const u8 {
    var level = @min(depth, group_depth_max);
    while (level > 0) {
        level -= 1;
        if (groups[level].len > 0) return groups[level];
    }
    return "";
}

/// A title equal to the URL says nothing the feed does not already say, so it
/// is not worth pinning.
fn opml_title(title: []const u8, url: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, title, " \t");
    if (std.mem.eql(u8, trimmed, std.mem.trim(u8, url, " \t"))) return "";
    return trimmed;
}

fn attribute(tag: []const u8, names: []const []const u8) ?[]const u8 {
    for (names) |name| {
        if (xml.attribute_value(tag, name)) |value| {
            if (value.len > 0) return value;
        }
    }
    return null;
}

const Tag = struct {
    bytes: []const u8,
    end: usize,
    closing: bool,
    self_closing: bool,
};

/// The next `<outline ...>` or `</outline>`, whichever comes first.
fn next_tag(source: []const u8, start: usize) ?Tag {
    var cursor = start;
    while (std.mem.indexOfScalarPos(u8, source, cursor, '<')) |open| {
        const end = std.mem.indexOfScalarPos(u8, source, open, '>') orelse return null;
        const bytes = source[open .. end + 1];
        cursor = end + 1;
        const closing = bytes.len > 1 and bytes[1] == '/';
        const name_start: usize = if (closing) 2 else 1;
        if (!std.ascii.startsWithIgnoreCase(bytes[name_start..], "outline")) continue;
        return .{
            .bytes = bytes,
            .end = cursor,
            .closing = closing,
            .self_closing = bytes.len > 2 and bytes[bytes.len - 2] == '/',
        };
    }
    return null;
}

fn append(
    feeds: *[limits.feed_count_max]model.Feed,
    feed_count: *u16,
    feed: model.Feed,
    result: *Result,
) !void {
    var index: u16 = 0;
    while (index < feed_count.*) : (index += 1) {
        if (std.mem.eql(u8, feeds[index].url.bytes(), feed.url.bytes())) {
            result.duplicates += 1;
            return;
        }
    }
    if (feed_count.* == limits.feed_count_max) return error.TooManyFeeds;
    feeds[feed_count.*] = feed;
    feed_count.* += 1;
    result.added += 1;
}

test "newsboat urls import with tags and display titles" {
    const source =
        \\# comment
        \\https://one.test/rss Tech "Long Reads"
        \\https://two.test/rss "Zig Weekly" "~Zig Weekly Digest"
        \\https://three.test/rss
        \\not-a-feed Tech
        \\
    ;
    var feeds: [limits.feed_count_max]model.Feed = undefined;
    var count: u16 = 0;
    const result = try merge(source, .auto, &feeds, &count);
    try std.testing.expectEqual(Format.newsboat, result.format);
    try std.testing.expectEqual(@as(u16, 3), result.added);
    try std.testing.expectEqual(@as(u16, 1), result.skipped);
    try std.testing.expectEqualStrings("Tech", feeds[0].category.bytes());
    try std.testing.expectEqualStrings("Zig Weekly", feeds[1].category.bytes());
    try std.testing.expectEqualStrings("Zig Weekly Digest", feeds[1].title.bytes());
    try std.testing.expect(feeds[1].title_pinned);
    try std.testing.expectEqualStrings("Unsorted", feeds[2].category.bytes());
}

test "opml import takes groups as categories" {
    const source =
        \\<?xml version="1.0"?>
        \\<opml version="1.0"><body>
        \\  <outline text="Tech">
        \\    <outline type="rss" text="Zig" xmlUrl="https://one.test/rss"/>
        \\    <outline type="rss" title="Beetle" xmlUrl="https://two.test/rss"/>
        \\  </outline>
        \\  <outline text="Loose" xmlUrl="https://three.test/rss"/>
        \\  <outline text="Empty Group"/>
        \\</body></opml>
        \\
    ;
    var feeds: [limits.feed_count_max]model.Feed = undefined;
    var count: u16 = 0;
    const result = try merge(source, .auto, &feeds, &count);
    try std.testing.expectEqual(Format.opml, result.format);
    try std.testing.expectEqual(@as(u16, 3), result.added);
    try std.testing.expectEqualStrings("Tech", feeds[0].category.bytes());
    try std.testing.expectEqualStrings("Zig", feeds[0].title.bytes());
    try std.testing.expectEqualStrings("Tech", feeds[1].category.bytes());
    try std.testing.expectEqualStrings("Beetle", feeds[1].title.bytes());
    // A feed outside every group keeps its own name and the catch-all group.
    try std.testing.expectEqualStrings("Unsorted", feeds[2].category.bytes());
    try std.testing.expectEqualStrings("Loose", feeds[2].title.bytes());
}

test "importing the same list twice adds nothing the second time" {
    const source =
        \\https://one.test/rss Tech
        \\https://two.test/rss News
        \\
    ;
    var feeds: [limits.feed_count_max]model.Feed = undefined;
    var count: u16 = 0;
    _ = try merge(source, .newsboat, &feeds, &count);
    const again = try merge(source, .newsboat, &feeds, &count);
    try std.testing.expectEqual(@as(u16, 2), count);
    try std.testing.expectEqual(@as(u16, 0), again.added);
    try std.testing.expectEqual(@as(u16, 2), again.duplicates);
}

test "a readmarks feed list merges into another" {
    const source =
        \\https://one.test/rss category="Tech"
        \\https://two.test/rss category="News" title="Two"
        \\
    ;
    var feeds: [limits.feed_count_max]model.Feed = undefined;
    var count: u16 = 0;
    const result = try merge(source, .auto, &feeds, &count);
    try std.testing.expectEqual(Format.readmarks, result.format);
    try std.testing.expectEqual(@as(u16, 2), result.added);
    try std.testing.expectEqualStrings("Two", feeds[1].title.bytes());
}

test "format names map to the flag values" {
    try std.testing.expectEqual(Format.opml, Format.parse("opml").?);
    try std.testing.expectEqual(Format.newsboat, Format.parse("newsboat").?);
    try std.testing.expect(Format.parse("csv") == null);
}
