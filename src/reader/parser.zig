const std = @import("std");
const document = @import("markix").document;
const xml = @import("markix").xml;
const date = @import("date.zig");
const limits = @import("limits.zig");
const model = @import("model.zig");

pub const Update = struct {
    feed_index: u16,
    title: model.FeedTitle = .{},
    articles: [limits.feed_articles_per_update_max]model.Article = undefined,
    article_count: u16 = 0,
};

pub fn parse(source: []const u8, feed_index: u16) !Update {
    var update = Update{ .feed_index = feed_index };
    parse_feed_title(source, &update.title);
    var cursor: usize = 0;
    while (next_entry(source, cursor)) |entry| {
        if (update.article_count == limits.feed_articles_per_update_max) break;
        if (parse_article(entry.bytes, feed_index)) |article| {
            update.articles[update.article_count] = article;
            update.article_count += 1;
        }
        cursor = entry.end;
    }
    return update;
}

const Entry = struct {
    bytes: []const u8,
    end: usize,
};

fn next_entry(source: []const u8, cursor: usize) ?Entry {
    const item = xml.find_open_tag(source, cursor, "item");
    const atom = xml.find_open_tag(source, cursor, "entry");
    const start = if (item) |item_start|
        if (atom) |atom_start| @min(item_start, atom_start) else item_start
    else
        atom orelse return null;
    const tag = if (xml.starts_with_tag(source[start..], "item")) "item" else "entry";
    const open_end = std.mem.indexOfScalarPos(u8, source, start, '>') orelse return null;
    const close_start = xml.find_close_tag(source, open_end + 1, tag) orelse return null;
    const close_end = std.mem.indexOfScalarPos(u8, source, close_start, '>') orelse return null;
    return .{
        .bytes = source[open_end + 1 .. close_start],
        .end = close_end + 1,
    };
}

fn parse_feed_title(source: []const u8, target: *model.FeedTitle) void {
    const boundary = next_entry(source, 0);
    const header = if (boundary) |entry|
        source[0 .. @intFromPtr(entry.bytes.ptr) - @intFromPtr(source.ptr)]
    else
        source;
    if (xml.element_text(header, &.{"title"})) |title| {
        document.copy_plain_text(title, target);
    }
}

fn parse_article(source: []const u8, feed_index: u16) ?model.Article {
    const title_source = xml.element_text(source, &.{"title"}) orelse return null;
    const url_source = article_url(source) orelse return null;
    var article = model.Article{
        .title = .{},
        .url = .{},
        .feed_index = feed_index,
    };
    document.copy_plain_text(title_source, &article.title);
    document.copy_plain_text(url_source, &article.url);
    if (article.title.is_empty() or !valid_article_url(article.url.bytes())) return null;
    parse_content(source, &article);
    parse_published(source, &article);
    parse_image(source, &article);
    return article;
}

fn parse_content(source: []const u8, article: *model.Article) void {
    const names = [_][]const u8{
        "content:encoded",
        "content",
        "summary",
        "description",
    };
    const value = xml.element_text(source, &names) orelse return;
    model.set_truncated(&article.content, value);
    const parsed = document.parse(article.content.bytes());
    document.write_plain(&parsed, &article.summary);
    if (parsed.first_image()) |image| {
        if (valid_article_url(image)) model.set_truncated(&article.image_url, image);
    }
}

fn parse_published(source: []const u8, article: *model.Article) void {
    const names = [_][]const u8{ "published", "updated", "pubDate", "dc:date" };
    const value = xml.element_text(source, &names) orelse return;
    document.copy_plain_text(value, &article.published);
    article.published_timestamp = date.parse(article.published.bytes()) orelse 0;
}

fn parse_image(source: []const u8, article: *model.Article) void {
    if (!article.image_url.is_empty()) return;
    const names = [_][]const u8{ "media:content", "media:thumbnail", "enclosure" };
    for (names) |name| {
        const start = xml.find_open_tag(source, 0, name) orelse continue;
        const end = std.mem.indexOfScalarPos(u8, source, start, '>') orelse continue;
        const tag = source[start .. end + 1];
        const url = xml.attribute_value(tag, "url") orelse continue;
        if (valid_article_url(url)) {
            model.set_truncated(&article.image_url, url);
            return;
        }
    }
}

fn article_url(source: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (xml.find_open_tag(source, cursor, "link")) |start| {
        const end = std.mem.indexOfScalarPos(u8, source, start, '>') orelse return null;
        const tag = source[start .. end + 1];
        if (xml.attribute_value(tag, "href")) |href| {
            const relation = xml.attribute_value(tag, "rel");
            if (relation == null or std.ascii.eqlIgnoreCase(relation.?, "alternate")) {
                return href;
            }
        }
        const close = xml.find_close_tag(source, end + 1, "link");
        if (close) |close_start| return source[end + 1 .. close_start];
        cursor = end + 1;
    }
    return xml.element_text(source, &.{"guid"});
}

fn valid_article_url(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://") or
        std.mem.startsWith(u8, url, "http://");
}

test "RSS and Atom entries parse normalized rich articles" {
    const rss =
        \\<rss><channel><title>Example &amp; Co</title>
        \\<item><title> One &amp; Two </title><link>https://example.com/one</link>
        \\<description><![CDATA[<h2>Hello</h2><p>Text for <b>reader</b>.
        \\<img src="https://example.com/cover.png" alt="Cover"/></p>]]></description>
        \\<pubDate>Thu, 30 Jul 2026 10:00:00 GMT</pubDate></item></channel></rss>
    ;
    const rss_update = try parse(rss, 3);
    try std.testing.expectEqual(@as(u16, 1), rss_update.article_count);
    try std.testing.expectEqualStrings("Example & Co", rss_update.title.bytes());
    try std.testing.expectEqualStrings("One & Two", rss_update.articles[0].title.bytes());
    try std.testing.expectEqualStrings(
        "Hello Text for reader. Cover",
        rss_update.articles[0].summary.bytes(),
    );
    try std.testing.expectEqualStrings(
        "https://example.com/cover.png",
        rss_update.articles[0].image_url.bytes(),
    );

    const atom =
        \\<feed><title>Atom</title><entry><title>Entry</title>
        \\<link rel="alternate" href="https://example.com/atom"/>
        \\<summary>Useful text</summary><updated>2026-07-30</updated></entry></feed>
    ;
    const atom_update = try parse(atom, 4);
    try std.testing.expectEqual(@as(u16, 1), atom_update.article_count);
    try std.testing.expectEqualStrings(
        "https://example.com/atom",
        atom_update.articles[0].url.bytes(),
    );
}
