const std = @import("std");
const limits = @import("limits.zig");
const model = @import("model.zig");

// The feed list, in readmarks' own format.
//
// One feed per line: a URL, then optional `key=value` fields. Values may be
// quoted to carry spaces. Blank lines and `#` comments are ignored.
//
//     https://ziglang.org/devlog/index.xml   category=Zig
//     https://tigerbeetle.com/blog/feed.xml  category=Systems title="TigerBeetle"
//
// Named fields rather than newsboat's positional tags because the two things a
// feed carries beyond its URL -- the group it belongs to and a title worth
// overriding -- are not interchangeable, and a positional list cannot say which
// one it means without being read in full. A malformed line is skipped and
// counted rather than failing the load: one typo should not cost every other
// feed, and the count is reported so the typo is not silent.

/// Name of the feed list inside the configuration directory.
pub const file_name = "feeds";

const header =
    \\# readmarks feeds. One feed per line:
    \\#
    \\#   <url> [category="NAME"] [title="NAME"]
    \\#
    \\# Import from newsboat or OPML with: readmarks import <file>
    \\
    \\
;

pub const LoadResult = struct {
    count: u16 = 0,
    /// Lines that were not a feed and not a comment.
    skipped: u16 = 0,
};

pub fn load(
    io: std.Io,
    path: []const u8,
    feeds: *[limits.feed_count_max]model.Feed,
    storage: *[limits.feed_response_bytes_max]u8,
) !LoadResult {
    const bytes = try @import("data").cwd().readFile(io, path, storage);
    if (bytes.len == storage.len) return error.SubscriptionFileTooLarge;
    return parse(bytes, feeds);
}

pub fn parse(
    source: []const u8,
    feeds: *[limits.feed_count_max]model.Feed,
) !LoadResult {
    var result = LoadResult{};
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (result.count == limits.feed_count_max) return error.TooManyFeeds;
        feeds[result.count] = parse_line(line) catch {
            result.skipped += 1;
            continue;
        };
        result.count += 1;
    }
    return result;
}

pub fn make_feed(url: []const u8, category_value: []const u8) !model.Feed {
    return make_feed_titled(url, category_value, "");
}

pub fn make_feed_titled(
    url: []const u8,
    category_value: []const u8,
    title_value: []const u8,
) !model.Feed {
    if (!valid_feed_url(url)) return error.InvalidFeedUrl;
    const category = if (category_value.len == 0) "Unsorted" else category_value;
    if (std.mem.indexOfAny(u8, category, "\"\r\n") != null) {
        return error.InvalidFeedCategory;
    }
    if (std.mem.indexOfAny(u8, title_value, "\"\r\n") != null) {
        return error.InvalidFeedTitle;
    }
    const pinned = title_value.len > 0;
    return .{
        .title = try model.FeedTitle.init(if (pinned) title_value else feed_host(url)),
        .url = try model.FeedUrl.init(url),
        .category = try model.CategoryName.init(category),
        .title_pinned = pinned,
    };
}

pub fn save(
    io: std.Io,
    path: []const u8,
    feeds: *const [limits.feed_count_max]model.Feed,
    feed_count: u16,
    keep: *const [limits.feed_count_max]bool,
    storage: *[limits.feed_response_bytes_max]u8,
) !void {
    const bytes = try encode(feeds, feed_count, keep, storage);
    const directory_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    const file_name_value = std.fs.path.basename(path);
    // The configuration directory is the application's to create: a first run
    // has no ~/.config/readmarks until something is saved into it.
    try @import("data").cwd().createDirPath(io, directory_path);
    var directory = try std.Io.Dir.openDirAbsolute(io, directory_path, .{});
    defer directory.close(io);
    var atomic_file = try directory.createFileAtomic(
        io,
        file_name_value,
        .{ .replace = true },
    );
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, bytes);
    try atomic_file.replace(io);
}

fn encode(
    feeds: *const [limits.feed_count_max]model.Feed,
    feed_count: u16,
    keep: *const [limits.feed_count_max]bool,
    storage: *[limits.feed_response_bytes_max]u8,
) ![]const u8 {
    if (feed_count > limits.feed_count_max) return error.TooManyFeeds;
    var writer = std.Io.Writer.fixed(storage);
    try writer.writeAll(header);
    var index: u16 = 0;
    while (index < feed_count) : (index += 1) {
        if (!keep[index]) continue;
        const feed = &feeds[index];
        if (std.mem.indexOfAny(u8, feed.category.bytes(), "\"\r\n") != null) {
            return error.InvalidFeedCategory;
        }
        try writer.print(
            "{s} category=\"{s}\"",
            .{ feed.url.bytes(), feed.category.bytes() },
        );
        // Only a title the user pinned is written back. A title the feed
        // supplied belongs to the feed, and the cache already holds it.
        if (feed.title_pinned) {
            if (std.mem.indexOfAny(u8, feed.title.bytes(), "\"\r\n") != null) {
                return error.InvalidFeedTitle;
            }
            try writer.print(" title=\"{s}\"", .{feed.title.bytes()});
        }
        try writer.writeAll("\n");
    }
    return writer.buffered();
}

fn parse_line(line: []const u8) !model.Feed {
    var fields = Fields{ .rest = line };
    const url = fields.take_word() orelse return error.InvalidFeedUrl;
    var category: []const u8 = "";
    var title: []const u8 = "";
    while (try fields.next()) |field| {
        if (std.mem.eql(u8, field.key, "category")) {
            category = field.value;
        } else if (std.mem.eql(u8, field.key, "title")) {
            title = field.value;
        } else {
            return error.UnknownFeedField;
        }
    }
    return make_feed_titled(url, category, title);
}

const Field = struct {
    key: []const u8,
    value: []const u8,
};

/// Walks a line's `key=value` fields, honouring quotes around a value.
const Fields = struct {
    rest: []const u8,

    fn take_word(self: *Fields) ?[]const u8 {
        self.skip_spaces();
        if (self.rest.len == 0) return null;
        const end = std.mem.indexOfAny(u8, self.rest, " \t") orelse self.rest.len;
        const word = self.rest[0..end];
        self.rest = self.rest[end..];
        return word;
    }

    fn next(self: *Fields) !?Field {
        self.skip_spaces();
        if (self.rest.len == 0) return null;
        const separator = std.mem.indexOfScalar(u8, self.rest, '=') orelse
            return error.MalformedFeedField;
        const key = self.rest[0..separator];
        if (key.len == 0) return error.MalformedFeedField;
        if (std.mem.indexOfAny(u8, key, " \t") != null) return error.MalformedFeedField;
        self.rest = self.rest[separator + 1 ..];
        return .{ .key = key, .value = try self.take_value() };
    }

    fn take_value(self: *Fields) ![]const u8 {
        if (self.rest.len > 0 and self.rest[0] == '"') {
            const end = std.mem.indexOfScalarPos(u8, self.rest, 1, '"') orelse
                return error.UnterminatedFeedValue;
            const value = self.rest[1..end];
            self.rest = self.rest[end + 1 ..];
            return value;
        }
        return self.take_word() orelse "";
    }

    fn skip_spaces(self: *Fields) void {
        var index: usize = 0;
        while (index < self.rest.len and
            (self.rest[index] == ' ' or self.rest[index] == '\t')) : (index += 1)
        {}
        self.rest = self.rest[index..];
    }
};

pub fn valid_feed_url(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://") or
        std.mem.startsWith(u8, url, "http://") or
        std.mem.startsWith(u8, url, "file://");
}

pub fn feed_host(url: []const u8) []const u8 {
    const scheme = std.mem.indexOf(u8, url, "://") orelse return url;
    const start = scheme + 3;
    const end = std.mem.indexOfScalarPos(u8, url, start, '/') orelse url.len;
    return url[start..end];
}

test "a feed line carries a url and named fields" {
    const source =
        \\# A group.
        \\https://example.com/feed.xml category="Technology"
        \\http://math.test/rss category=Maths
        \\https://pinned.test/rss category="Long Reads" title="A Better Name"
        \\https://bare.test/rss
        \\
    ;
    var feeds: [limits.feed_count_max]model.Feed = undefined;
    const result = try parse(source, &feeds);
    try std.testing.expectEqual(@as(u16, 4), result.count);
    try std.testing.expectEqual(@as(u16, 0), result.skipped);
    try std.testing.expectEqualStrings("Technology", feeds[0].category.bytes());
    try std.testing.expectEqualStrings("example.com", feeds[0].title.bytes());
    try std.testing.expect(!feeds[0].title_pinned);
    try std.testing.expectEqualStrings("Maths", feeds[1].category.bytes());
    try std.testing.expectEqualStrings("Long Reads", feeds[2].category.bytes());
    try std.testing.expectEqualStrings("A Better Name", feeds[2].title.bytes());
    try std.testing.expect(feeds[2].title_pinned);
    // No category means the catch-all group.
    try std.testing.expectEqualStrings("Unsorted", feeds[3].category.bytes());
}

test "a malformed line is skipped and counted, not fatal" {
    // The middle line is newsboat's positional form, which this format does
    // not accept -- that is what `readmarks import` is for.
    const source =
        \\https://one.test/rss category=Tech
        \\https://two.test/rss Tech extra
        \\not-a-url category=Tech
        \\https://three.test/rss colour=blue
        \\https://four.test/rss category=Tech
        \\
    ;
    var feeds: [limits.feed_count_max]model.Feed = undefined;
    const result = try parse(source, &feeds);
    try std.testing.expectEqual(@as(u16, 2), result.count);
    try std.testing.expectEqual(@as(u16, 3), result.skipped);
    try std.testing.expectEqualStrings("https://one.test/rss", feeds[0].url.bytes());
    try std.testing.expectEqualStrings("https://four.test/rss", feeds[1].url.bytes());
}

test "encoding round trips through the parser" {
    var feeds: [limits.feed_count_max]model.Feed = undefined;
    feeds[0] = try make_feed("https://one.test/rss", "Tech");
    feeds[1] = try make_feed_titled("https://two.test/rss", "Long Reads", "Two");
    var keep: [limits.feed_count_max]bool = @splat(true);
    var storage: [limits.feed_response_bytes_max]u8 = undefined;
    const bytes = try encode(&feeds, 2, &keep, &storage);

    var reloaded: [limits.feed_count_max]model.Feed = undefined;
    const result = try parse(bytes, &reloaded);
    try std.testing.expectEqual(@as(u16, 2), result.count);
    try std.testing.expectEqual(@as(u16, 0), result.skipped);
    try std.testing.expectEqualStrings("https://one.test/rss", reloaded[0].url.bytes());
    try std.testing.expectEqualStrings("Tech", reloaded[0].category.bytes());
    try std.testing.expectEqualStrings("Long Reads", reloaded[1].category.bytes());
    try std.testing.expectEqualStrings("Two", reloaded[1].title.bytes());
    try std.testing.expect(reloaded[1].title_pinned);
}

test "a feed list round trips through the configuration directory" {
    // The path the application will actually use, built the way it builds it.
    const paths = try @import("data").Paths.under_home("/tmp/readmarks-test-home");
    var path_buffer: [@import("data").limits.path_bytes_max]u8 = undefined;
    const path = try @import("data").paths.file(
        &path_buffer,
        paths.config.bytes(),
        file_name,
    );
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, path) catch {};

    var feeds: [limits.feed_count_max]model.Feed = undefined;
    feeds[0] = try make_feed("https://one.test/rss", "Tech");
    feeds[1] = try make_feed_titled("https://two.test/rss", "News", "Two");
    const keep: [limits.feed_count_max]bool = @splat(true);
    var storage: [limits.feed_response_bytes_max]u8 = undefined;
    // Saving creates the configuration directory: a first run has none.
    try save(std.testing.io, path, &feeds, 2, &keep, &storage);

    var reloaded: [limits.feed_count_max]model.Feed = undefined;
    const result = try load(std.testing.io, path, &reloaded, &storage);
    try std.testing.expectEqual(@as(u16, 2), result.count);
    try std.testing.expectEqualStrings("https://one.test/rss", reloaded[0].url.bytes());
    try std.testing.expectEqualStrings("Tech", reloaded[0].category.bytes());
    try std.testing.expectEqualStrings("Two", reloaded[1].title.bytes());
}

test "encoding applies a bounded keep set" {
    var feeds: [limits.feed_count_max]model.Feed = undefined;
    feeds[0] = try make_feed("https://one.test/rss", "Tech");
    feeds[1] = try make_feed("https://two.test/rss", "News");
    var keep: [limits.feed_count_max]bool = @splat(false);
    keep[1] = true;
    var storage: [limits.feed_response_bytes_max]u8 = undefined;
    const bytes = try encode(&feeds, 2, &keep, &storage);
    try std.testing.expect(std.mem.endsWith(
        u8,
        bytes,
        "https://two.test/rss category=\"News\"\n",
    ));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "one.test") == null);
}
