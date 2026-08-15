const std = @import("std");
const document = @import("markix").document;
const limits = @import("limits.zig");
const model = @import("model.zig");

const magic = "MARKRC04";
const SaveOutcome = union(enum) { success, failure: anyerror };
const SaveResultQueue = std.Io.Queue(SaveOutcome);
const Paths = @import("data").Paths;

pub const file_name = "rss-cache.bin";

pub const Persistence = struct {
    directory: [limits.path_bytes_max]u8 = undefined,
    directory_length: u16,
    file_path: [limits.path_bytes_max]u8 = undefined,
    file_path_length: u16,
    /// The pre-XDG location. Read from once so an upgrade does not throw away
    /// a warm cache and refetch every feed.
    legacy_path: [limits.path_bytes_max]u8 = undefined,
    legacy_path_length: u16,
    buffer: [limits.cache_bytes_max]u8 = undefined,
    save_task: std.Io.Group = .init,
    save_result_buffer: [1]SaveOutcome = undefined,
    save_results: SaveResultQueue = undefined,
    save_length: u32 = 0,
    save_busy: bool = false,
    save_pending: bool = false,

    /// Fetched articles are a cache: deleting the file costs one refresh, so
    /// it belongs under the cache root a user is free to clear.
    pub fn init_in_place(self: *Persistence, paths: *const Paths) !void {
        self.save_task = .init;
        self.save_results = .init(&self.save_result_buffer);
        self.save_length = 0;
        self.save_busy = false;
        self.save_pending = false;
        const directory = try std.fmt.bufPrint(
            &self.directory,
            "{s}",
            .{paths.cache.bytes()},
        );
        self.directory_length = @intCast(directory.len);
        const path = try std.fmt.bufPrint(
            &self.file_path,
            "{s}/{s}",
            .{ directory, file_name },
        );
        self.file_path_length = @intCast(path.len);
        const legacy = try std.fmt.bufPrint(
            &self.legacy_path,
            "{s}/{s}",
            .{ paths.legacy.bytes(), file_name },
        );
        self.legacy_path_length = @intCast(legacy.len);
    }

    pub fn deinit(self: *Persistence, io: std.Io) void {
        if (self.save_busy) self.save_task.cancel(io);
        self.save_results.close(io);
    }

    pub fn finish(
        self: *Persistence,
        io: std.Io,
        feeds: *const [limits.feed_count_max]model.Feed,
        feed_count: u16,
        articles: *const [limits.article_count_max]model.Article,
        article_count: u16,
    ) !?anyerror {
        var failure: ?anyerror = null;
        var attempt: u8 = 0;
        while (self.save_busy) : (attempt += 1) {
            std.debug.assert(attempt < 2);
            try self.save_task.await(io);
            var completed: [1]SaveOutcome = undefined;
            const count = try self.save_results.get(io, &completed, 0);
            std.debug.assert(count == 1);
            self.save_busy = false;
            switch (completed[0]) {
                .success => {},
                .failure => |err| failure = err,
            }
            if (!self.save_pending) continue;
            self.save_pending = false;
            self.start_save(
                io,
                feeds,
                feed_count,
                articles,
                article_count,
            ) catch |err| {
                failure = err;
            };
        }
        return failure;
    }

    pub fn load(
        self: *Persistence,
        io: std.Io,
        feeds: *[limits.feed_count_max]model.Feed,
        feed_count: u16,
        articles: *[limits.article_count_max]model.Article,
        article_count: *u16,
    ) !?i64 {
        const current = try self.read(io, self.file_path[0..self.file_path_length]);
        const bytes = current orelse
            try self.read(io, self.legacy_path[0..self.legacy_path_length]) orelse
            return null;
        if (bytes.len == self.buffer.len) return error.CacheFileTooLarge;
        return try decode(bytes, feeds, feed_count, articles, article_count);
    }

    fn read(self: *Persistence, io: std.Io, path: []const u8) !?[]const u8 {
        return @import("data").cwd().readFile(io, path, &self.buffer) catch |err| {
            return switch (err) {
                error.FileNotFound => null,
                else => err,
            };
        };
    }

    pub fn request_save(
        self: *Persistence,
        io: std.Io,
        feeds: *const [limits.feed_count_max]model.Feed,
        feed_count: u16,
        articles: *const [limits.article_count_max]model.Article,
        article_count: u16,
    ) !void {
        if (self.save_busy) {
            self.save_pending = true;
            return;
        }
        try self.start_save(io, feeds, feed_count, articles, article_count);
    }

    pub fn poll(
        self: *Persistence,
        io: std.Io,
        feeds: *const [limits.feed_count_max]model.Feed,
        feed_count: u16,
        articles: *const [limits.article_count_max]model.Article,
        article_count: u16,
    ) !?anyerror {
        if (!self.save_busy) return null;
        var completed: [1]SaveOutcome = undefined;
        const count = self.save_results.get(io, &completed, 0) catch |err| {
            return switch (err) {
                error.Closed => null,
                error.Canceled => err,
            };
        };
        if (count == 0) return null;
        try self.save_task.await(io);
        std.debug.assert(self.save_busy);
        self.save_busy = false;
        const failure: ?anyerror = switch (completed[0]) {
            .success => null,
            .failure => |err| err,
        };
        if (self.save_pending) {
            self.save_pending = false;
            try self.start_save(io, feeds, feed_count, articles, article_count);
        }
        return failure;
    }

    fn start_save(
        self: *Persistence,
        io: std.Io,
        feeds: *const [limits.feed_count_max]model.Feed,
        feed_count: u16,
        articles: *const [limits.article_count_max]model.Article,
        article_count: u16,
    ) !void {
        std.debug.assert(!self.save_busy);
        const bytes = try encode(
            now_seconds(io),
            feeds,
            feed_count,
            articles,
            article_count,
            &self.buffer,
        );
        self.save_length = @intCast(bytes.len);
        self.save_busy = true;
        self.save_task.concurrent(io, save_task, .{ self, io }) catch |err| {
            self.save_busy = false;
            self.save_length = 0;
            return err;
        };
    }

    fn write_prepared(self: *Persistence, io: std.Io) !void {
        std.debug.assert(self.save_busy);
        std.debug.assert(self.save_length > 0);
        std.debug.assert(self.save_length <= self.buffer.len);
        try @import("data").cwd().createDirPath(
            io,
            self.directory[0..self.directory_length],
        );
        var directory = try std.Io.Dir.openDirAbsolute(
            io,
            self.directory[0..self.directory_length],
            .{},
        );
        defer directory.close(io);
        var atomic_file = try directory.createFileAtomic(
            io,
            file_name,
            .{ .replace = true },
        );
        defer atomic_file.deinit(io);
        try atomic_file.file.writeStreamingAll(io, self.buffer[0..self.save_length]);
        try atomic_file.replace(io);
    }
};

fn save_task(persistence: *Persistence, io: std.Io) std.Io.Cancelable!void {
    const outcome: SaveOutcome = if (persistence.write_prepared(io))
        .success
    else |err|
        .{ .failure = err };
    persistence.save_results.putOne(io, outcome) catch |err| switch (err) {
        error.Closed => return,
        error.Canceled => return error.Canceled,
    };
}

pub fn is_fresh(saved_at_seconds: i64, io: std.Io) bool {
    const current = now_seconds(io);
    if (saved_at_seconds > current) return false;
    return current - saved_at_seconds <= limits.cache_fresh_seconds;
}

pub fn encode(
    saved_at_seconds: i64,
    feeds: *const [limits.feed_count_max]model.Feed,
    feed_count: u16,
    articles: *const [limits.article_count_max]model.Article,
    article_count: u16,
    output: []u8,
) ![]const u8 {
    if (feed_count > limits.feed_count_max) return error.InvalidCache;
    if (article_count > limits.article_count_max) return error.InvalidCache;
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll(magic);
    try write_integer(i64, &writer, saved_at_seconds);
    try write_integer(u16, &writer, feed_count);
    var feed_index: u16 = 0;
    while (feed_index < feed_count) : (feed_index += 1) {
        const feed = &feeds[feed_index];
        try write_field(&writer, feed.url.bytes());
        try write_field(&writer, feed.title.bytes());
    }
    try write_integer(u16, &writer, article_count);
    var article_index: u16 = 0;
    while (article_index < article_count) : (article_index += 1) {
        try write_article(&writer, &articles[article_index]);
    }
    return writer.buffered();
}

fn write_article(writer: *std.Io.Writer, article: *const model.Article) !void {
    try write_integer(u16, writer, article.feed_index);
    try write_integer(i64, writer, article.published_timestamp);
    try write_integer(u8, writer, @intFromBool(article.content_complete));
    try write_field(writer, article.title.bytes());
    try write_field(writer, article.url.bytes());
    try write_field(writer, article.content.bytes());
    try write_field(writer, article.image_url.bytes());
    try write_field(writer, article.summary.bytes());
    try write_field(writer, article.published.bytes());
}

pub fn decode(
    input: []const u8,
    feeds: *[limits.feed_count_max]model.Feed,
    feed_count: u16,
    articles: *[limits.article_count_max]model.Article,
    article_count: *u16,
) !i64 {
    if (input.len < magic.len + @sizeOf(i64)) return error.InvalidCache;
    if (!std.mem.eql(u8, input[0..magic.len], magic)) return error.InvalidCache;
    var cursor: usize = magic.len;
    const saved_at_seconds = try read_integer(i64, input, &cursor);
    var feed_map: [limits.feed_count_max]?u16 = @splat(null);
    const cached_feed_count = try read_integer(u16, input, &cursor);
    if (cached_feed_count > limits.feed_count_max) return error.InvalidCache;
    try decode_feeds(input, &cursor, feeds, feed_count, &feed_map, cached_feed_count);
    article_count.* = 0;
    const cached_article_count = try read_integer(u16, input, &cursor);
    if (cached_article_count > limits.article_count_max) return error.InvalidCache;
    try decode_articles(
        input,
        &cursor,
        articles,
        article_count,
        &feed_map,
        cached_article_count,
    );
    if (cursor != input.len) return error.InvalidCache;
    return saved_at_seconds;
}

fn decode_feeds(
    input: []const u8,
    cursor: *usize,
    feeds: *[limits.feed_count_max]model.Feed,
    feed_count: u16,
    feed_map: *[limits.feed_count_max]?u16,
    cached_feed_count: u16,
) !void {
    var cached_index: u16 = 0;
    while (cached_index < cached_feed_count) : (cached_index += 1) {
        const url = try read_field(input, cursor);
        const title = try read_field(input, cursor);
        const current_index = find_feed(feeds, feed_count, url);
        feed_map[cached_index] = current_index;
        if (current_index) |index| {
            // A title the feed list pinned outranks the one the cache saw.
            if (!feeds[index].title_pinned) {
                document.copy_plain_text(title, &feeds[index].title);
            }
            feeds[index].fetched = true;
        }
    }
}

fn decode_articles(
    input: []const u8,
    cursor: *usize,
    articles: *[limits.article_count_max]model.Article,
    article_count: *u16,
    feed_map: *const [limits.feed_count_max]?u16,
    cached_article_count: u16,
) !void {
    var cached_index: u16 = 0;
    while (cached_index < cached_article_count) : (cached_index += 1) {
        const cached_feed_index = try read_integer(u16, input, cursor);
        const published_timestamp = try read_integer(i64, input, cursor);
        const content_complete = try read_integer(u8, input, cursor);
        if (content_complete > 1) return error.InvalidCache;
        const title = try read_field(input, cursor);
        const url = try read_field(input, cursor);
        const content = try read_field(input, cursor);
        const image_url = try read_field(input, cursor);
        const summary = try read_field(input, cursor);
        const published = try read_field(input, cursor);
        if (cached_feed_index >= limits.feed_count_max) return error.InvalidCache;
        const feed_index = feed_map[cached_feed_index] orelse continue;
        const article = try decode_article(
            feed_index,
            published_timestamp,
            content_complete == 1,
            title,
            url,
            content,
            image_url,
            summary,
            published,
        );
        articles[article_count.*] = article;
        article_count.* += 1;
    }
}

fn decode_article(
    feed_index: u16,
    published_timestamp: i64,
    content_complete: bool,
    title: []const u8,
    url: []const u8,
    content: []const u8,
    image_url: []const u8,
    summary: []const u8,
    published: []const u8,
) !model.Article {
    var article = model.Article{
        .title = .{},
        .url = model.ArticleUrl.init(url) catch return error.InvalidCache,
        .feed_index = feed_index,
        .published_timestamp = published_timestamp,
        .content_complete = content_complete,
    };
    document.copy_plain_text(title, &article.title);
    if (article.title.is_empty()) return error.InvalidCache;
    article.content.set(content) catch return error.InvalidCache;
    article.image_url.set(image_url) catch return error.InvalidCache;
    article.summary.set(summary) catch return error.InvalidCache;
    article.published.set(published) catch return error.InvalidCache;
    return article;
}

fn find_feed(
    feeds: *const [limits.feed_count_max]model.Feed,
    feed_count: u16,
    url: []const u8,
) ?u16 {
    var index: u16 = 0;
    while (index < feed_count) : (index += 1) {
        if (std.mem.eql(u8, feeds[index].url.bytes(), url)) return index;
    }
    return null;
}

fn now_seconds(io: std.Io) i64 {
    const nanoseconds = std.Io.Clock.real.now(io).nanoseconds;
    return @intCast(@divFloor(nanoseconds, std.time.ns_per_s));
}

fn write_field(writer: *std.Io.Writer, value: []const u8) !void {
    try write_integer(u16, writer, @intCast(value.len));
    try writer.writeAll(value);
}

fn read_field(input: []const u8, cursor: *usize) ![]const u8 {
    const length = try read_integer(u16, input, cursor);
    if (length > input.len -| cursor.*) return error.InvalidCache;
    const value = input[cursor.*..][0..length];
    cursor.* += length;
    return value;
}

fn write_integer(comptime T: type, writer: *std.Io.Writer, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

fn read_integer(comptime T: type, input: []const u8, cursor: *usize) !T {
    if (@sizeOf(T) > input.len -| cursor.*) return error.InvalidCache;
    const bytes = input[cursor.*..][0..@sizeOf(T)];
    cursor.* += @sizeOf(T);
    return std.mem.readInt(T, bytes, .little);
}

test "cache maps articles across subscription reorder" {
    var source_feeds: [limits.feed_count_max]model.Feed = undefined;
    source_feeds[0] = test_feed("One", "https://one.test/rss");
    source_feeds[1] = test_feed("Two", "https://two.test/rss");
    const source_articles = try std.testing.allocator.create(
        [limits.article_count_max]model.Article,
    );
    defer std.testing.allocator.destroy(source_articles);
    source_articles[0] = test_article(0, "First", "https://one.test/first");
    var buffer: [16_384]u8 = undefined;
    const encoded = try encode(
        42,
        &source_feeds,
        2,
        source_articles,
        1,
        &buffer,
    );

    var target_feeds: [limits.feed_count_max]model.Feed = undefined;
    target_feeds[0] = test_feed("Two", "https://two.test/rss");
    target_feeds[1] = test_feed("One", "https://one.test/rss");
    const target_articles = try std.testing.allocator.create(
        [limits.article_count_max]model.Article,
    );
    defer std.testing.allocator.destroy(target_articles);
    var target_count: u16 = 0;
    const saved = try decode(
        encoded,
        &target_feeds,
        2,
        target_articles,
        &target_count,
    );
    try std.testing.expectEqual(@as(i64, 42), saved);
    try std.testing.expectEqual(@as(u16, 1), target_count);
    try std.testing.expectEqual(@as(u16, 1), target_articles[0].feed_index);
    try std.testing.expectEqualStrings(
        "<h2>Cached</h2>",
        target_articles[0].content.bytes(),
    );
    try std.testing.expectEqualStrings(
        "https://one.test/image.png",
        target_articles[0].image_url.bytes(),
    );
}

fn test_feed(title: []const u8, url: []const u8) model.Feed {
    return .{
        .title = model.FeedTitle.init(title) catch unreachable,
        .url = model.FeedUrl.init(url) catch unreachable,
        .category = model.CategoryName.init("Test") catch unreachable,
    };
}

fn test_article(feed_index: u16, title: []const u8, url: []const u8) model.Article {
    var article = model.Article{
        .title = model.ArticleTitle.init(title) catch unreachable,
        .url = model.ArticleUrl.init(url) catch unreachable,
        .feed_index = feed_index,
    };
    article.content.set("<h2>Cached</h2>") catch unreachable;
    article.image_url.set("https://one.test/image.png") catch unreachable;
    return article;
}
