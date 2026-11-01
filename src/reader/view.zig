const std = @import("std");
const dom_view = @import("dom_view.zig");
const Display = @import("../ui/display.zig").Display;

pub fn render(application: anytype, display: *Display) !void {
    try dom_view.sync(&application.dom_view, application, display);
    display.present();
}

fn seeded_application() !*@import("application.zig").Application {
    const Application = @import("application.zig").Application;
    const model = @import("model.zig");
    const application = try Application.create(
        std.testing.allocator,
        std.testing.io,
        &@import("data").paths.testing_paths,
    );
    errdefer application.destroy(std.testing.allocator);
    application.feeds[0] = .{
        .title = try model.FeedTitle.init("Tiger Beetle"),
        .url = try model.FeedUrl.init("https://tigerbeetle.com/feed.xml"),
        .category = try model.CategoryName.init("Systems"),
    };
    application.feeds[1] = .{
        .title = try model.FeedTitle.init("Zig News"),
        .url = try model.FeedUrl.init("https://ziglang.org/feed.xml"),
        .category = try model.CategoryName.init("Languages"),
    };
    application.feed_count = 2;
    const titles = [_][]const u8{ "Tiger Style", "Zig Release Notes" };
    for (titles, 0..) |title, index| {
        application.articles[index] = .{
            .feed_index = @intCast(index),
            .title = try model.ArticleTitle.init(title),
            .url = try model.ArticleUrl.init(
                if (index == 0) "https://tigerbeetle.com/a" else "https://ziglang.org/b",
            ),
            .summary = try model.Summary.init("<p>Reliable systems software.</p>"),
            .published = try model.Published.init("2026-01-0" ++ .{'1' + @as(u8, @intCast(index))}),
        };
    }
    application.article_count = 2;
    application.rebuild_categories();
    application.refresh_feeds();
    application.refresh_articles();
    std.debug.assert(application.feed_count == 2);
    std.debug.assert(application.article_count == titles.len);
    return application;
}

test "the workspace renders its panes through the dom tree" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    const display = try Display.create(std.testing.allocator, 130, 30, .none);
    defer display.destroy(std.testing.allocator);

    try render(application, display);
    try std.testing.expect(display.shows("CATEGORIES"));
    try std.testing.expect(display.shows("FEEDS"));
    try std.testing.expect(display.shows("ARTICLES"));
    try std.testing.expect(display.shows("READER"));
    try std.testing.expect(display.shows("Tiger Style"));
    try std.testing.expect(display.shows("Tiger Beetle"));
}

test "the header carries the same tab bar the bookmarker has" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    const display = try Display.create(std.testing.allocator, 130, 30, .none);
    defer display.destroy(std.testing.allocator);

    try render(application, display);
    try std.testing.expect(display.shows("All articles"));
    try std.testing.expect(display.shows("Categories"));
    try std.testing.expect(display.shows("Articles"));
    try std.testing.expect(display.shows("ctrl-u"));
    try std.testing.expect(display.shows("switch"));
}

test "the command centre opens over the reader" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    const display = try Display.create(std.testing.allocator, 130, 30, .none);
    defer display.destroy(std.testing.allocator);

    _ = try application.handle_key(.{ .character = ':' });
    try render(application, display);
    try std.testing.expect(display.shows("COMMAND CENTRE"));
    try std.testing.expectEqual(@as(u16, 0), application.command.count);

    for ("> refresh") |byte| _ = try application.handle_key(.{ .character = byte });
    try std.testing.expect(application.command.count > 0);
    var index: u16 = 0;
    while (index < application.command.count) : (index += 1) {
        try std.testing.expect(application.command.results[index] == .action);
    }
    while (application.command.query().len > 0) {
        _ = try application.handle_key(.backspace);
    }

    for ("zig re") |byte| _ = try application.handle_key(.{ .character = byte });
    try render(application, display);
    try std.testing.expectEqual(
        @as(u16, 1),
        application.command.selected_result().?.article,
    );
    try std.testing.expectEqualStrings(
        "Zig Release Notes",
        application.command_result_title(application.command.selected_result().?),
    );
}

test "a feed's name does not drag its articles into the results" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);

    _ = try application.handle_key(.{ .character = ':' });
    for ("tiger beetle") |byte| _ = try application.handle_key(.{ .character = byte });
    try std.testing.expectEqual(@as(u16, 1), application.command.count);
    try std.testing.expect(application.command.results[0] == .feed);
}

test "ctrl-p opens the same command centre" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    const display = try Display.create(std.testing.allocator, 130, 30, .none);
    defer display.destroy(std.testing.allocator);

    _ = try application.handle_key(.{ .control = 'p' });
    try render(application, display);
    try std.testing.expect(display.shows("COMMAND CENTRE"));
}

test "zen mode shows the articles alone and finds within them" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    const display = try Display.create(std.testing.allocator, 130, 30, .none);
    defer display.destroy(std.testing.allocator);

    _ = try application.handle_key(.{ .character = 'z' });
    try render(application, display);
    try std.testing.expect(display.shows("ZEN LIBRARY"));
    try std.testing.expect(!display.shows("CATEGORIES"));

    _ = try application.handle_key(.{ .character = '/' });
    try render(application, display);
    try std.testing.expect(display.shows("FIND ARTICLES"));
    try std.testing.expect(display.shows("FILTER"));
}

test "the help sheet reads from the shared keymap" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    const display = try Display.create(std.testing.allocator, 130, 40, .none);
    defer display.destroy(std.testing.allocator);

    _ = try application.handle_key(.{ .character = '?' });
    try render(application, display);
    try std.testing.expect(display.shows("KEYBOARD HELP"));
    try std.testing.expect(display.shows("command centre"));
    try std.testing.expect(display.shows("reader / bookmarks"));
    try std.testing.expect(display.shows("full-screen reader"));
}

test "the document renders the article body" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    const display = try Display.create(std.testing.allocator, 130, 30, .none);
    defer display.destroy(std.testing.allocator);

    _ = try application.handle_key(.{ .character = 'v' });
    try render(application, display);
    try std.testing.expect(display.shows("Reliable systems software."));
}

test "search narrows the list as it is typed" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    const display = try Display.create(std.testing.allocator, 130, 30, .none);
    defer display.destroy(std.testing.allocator);

    _ = try application.handle_key(.{ .character = '/' });
    _ = try application.handle_key(.{ .character = 'Z' });
    _ = try application.handle_key(.{ .character = 'i' });
    _ = try application.handle_key(.{ .character = 'g' });
    try std.testing.expectEqual(@as(u16, 1), application.filtered_article_count);
    try render(application, display);
    try std.testing.expect(display.shows("Zig News"));
    try std.testing.expect(!display.shows("Tiger Style"));
}

test "a steady frame repaints nothing and keeps its panes" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    const display = try Display.create(std.testing.allocator, 130, 30, .none);
    defer display.destroy(std.testing.allocator);

    try render(application, display);
    try render(application, display);
    try std.testing.expectEqual(@as(i32, 0), display.painted_area());
    try std.testing.expect(display.shows("Tiger Style"));
    try std.testing.expect(display.shows("ARTICLES"));
}

test "moving the article cursor repaints less than a full frame" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    const display = try Display.create(std.testing.allocator, 130, 30, .none);
    defer display.destroy(std.testing.allocator);

    try render(application, display);
    const full_frame = display.painted_area();

    _ = try application.handle_key(.{ .character = 'j' });
    try render(application, display);
    const moved = display.painted_area();
    try std.testing.expect(moved > 0);
    try std.testing.expect(moved < full_frame);
}

test "narrow and medium widths still render" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    const display = try Display.create(std.testing.allocator, 130, 30, .none);
    defer display.destroy(std.testing.allocator);

    try render(application, display);
    display.resize(90, 20);
    try render(application, display);
    try std.testing.expect(display.shows("ARTICLES"));
    display.resize(50, 15);
    try render(application, display);
    try std.testing.expect(display.shows("ARTICLES"));
}

test "M marks only what the current scope is showing" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 2), application.unread_count());

    application.active_feed = 0;
    application.refresh_articles();
    try std.testing.expectEqual(@as(u16, 1), application.filtered_article_count);

    _ = try application.handle_key(.{ .character = 'M' });
    try std.testing.expectEqual(@as(u16, 1), application.unread_count());
    try std.testing.expectEqual(@as(u16, 0), application.feed_unread_count(0));
    try std.testing.expectEqual(@as(u16, 1), application.feed_unread_count(1));
}

test "M with no feed focused clears everything shown" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);

    _ = try application.handle_key(.{ .character = 'M' });
    try std.testing.expectEqual(@as(u16, 0), application.unread_count());
    try std.testing.expect(std.mem.indexOf(
        u8,
        application.message.bytes(),
        "Marked 2",
    ) != null);
}

test "M on an already-read list says so instead of claiming work" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);

    _ = try application.handle_key(.{ .character = 'M' });
    _ = try application.handle_key(.{ .character = 'M' });
    try std.testing.expectEqualStrings(
        "Everything here is already read",
        application.message.bytes(),
    );
}

test "a search narrows what M clears" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);

    _ = try application.handle_key(.{ .character = '/' });
    for ("zig") |byte| _ = try application.handle_key(.{ .character = byte });
    _ = try application.handle_key(.enter);
    try std.testing.expectEqual(@as(u16, 1), application.filtered_article_count);

    _ = try application.handle_key(.{ .character = 'M' });
    try std.testing.expectEqual(@as(u16, 1), application.unread_count());
}

test "the command centre offers marking everything read" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    const display = try Display.create(std.testing.allocator, 130, 30, .none);
    defer display.destroy(std.testing.allocator);

    _ = try application.handle_key(.{ .character = ':' });
    for ("> mark every") |byte| _ = try application.handle_key(.{ .character = byte });
    try render(application, display);
    try std.testing.expectEqualStrings(
        "Mark everything shown as read",
        application.command_result_title(application.command.selected_result().?),
    );
    _ = try application.handle_key(.enter);
    try std.testing.expectEqual(@as(u16, 0), application.unread_count());
}

test "adding a feed is the command centre asking for a URL" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    const display = try Display.create(std.testing.allocator, 130, 30, .none);
    defer display.destroy(std.testing.allocator);

    application.subscription_path = try @import("model.zig").FeedUrl.init(
        "/tmp/readmarks-add-probe/feeds",
    );
    _ = try application.handle_key(.{ .character = 'a' });
    try std.testing.expect(application.command.is_collecting());
    try render(application, display);
    try std.testing.expect(display.shows("Add a feed"));
    try std.testing.expect(!display.shows("Refresh every feed"));

    for ("https://example.com/rss.xml") |byte| {
        _ = try application.handle_key(.{ .character = byte });
    }
    _ = try application.handle_key(.enter);

    try std.testing.expect(application.command.is_collecting());
    for ("Systems") |byte| _ = try application.handle_key(.{ .character = byte });
    _ = try application.handle_key(.enter);

    try std.testing.expect(!application.command.is_open());
    try std.testing.expectEqual(@as(u16, 3), application.feed_count);
    try std.testing.expectEqualStrings(
        "https://example.com/rss.xml",
        application.feeds[2].url.bytes(),
    );
    try std.testing.expectEqualStrings("Systems", application.feeds[2].category.bytes());
}

test "a blank category falls back to Unsorted" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    application.subscription_path = try @import("model.zig").FeedUrl.init(
        "/tmp/readmarks-add-probe/feeds",
    );

    _ = try application.handle_key(.{ .character = 'a' });
    for ("https://example.com/plain.xml") |byte| {
        _ = try application.handle_key(.{ .character = byte });
    }
    _ = try application.handle_key(.enter);
    _ = try application.handle_key(.enter);
    try std.testing.expectEqualStrings("Unsorted", application.feeds[2].category.bytes());
}

test "the same feed action is reachable from the command centre itself" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);

    _ = try application.handle_key(.{ .character = ':' });
    for ("> add a feed") |byte| _ = try application.handle_key(.{ .character = byte });
    _ = try application.handle_key(.enter);
    try std.testing.expect(application.command.is_collecting());
    try std.testing.expectEqualStrings("Add a feed", application.active_label());
}

test "search runs as an action and clears when the centre is dismissed" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);

    _ = try application.handle_key(.{ .character = '/' });
    try std.testing.expect(application.command.is_collecting());
    try std.testing.expectEqualStrings("Search articles", application.active_label());

    for ("zig") |byte| _ = try application.handle_key(.{ .character = byte });
    try std.testing.expectEqual(@as(u16, 1), application.filtered_article_count);

    _ = try application.handle_key(.enter);
    try std.testing.expect(!application.command.is_open());
    try std.testing.expectEqual(@as(u16, 1), application.filtered_article_count);

    _ = try application.handle_key(.{ .character = '/' });
    _ = try application.handle_key(.escape);
    try std.testing.expectEqual(@as(u16, 2), application.filtered_article_count);
}

test "a paste longer than the field fills it instead of crashing" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);

    _ = try application.handle_key(.{ .character = 'a' });
    var pasted: usize = 0;
    while (pasted < 4000) : (pasted += 1) {
        _ = try application.handle_key(.{ .character = 'x' });
    }
    try std.testing.expect(application.command.is_collecting());
    try std.testing.expectEqual(
        @as(usize, 512),
        application.command.query().len,
    );
}

test "the prompt shows its placeholder until something is typed" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    const display = try Display.create(std.testing.allocator, 120, 20, .none);
    defer display.destroy(std.testing.allocator);

    _ = try application.handle_key(.{ .character = 'a' });
    try render(application, display);
    try std.testing.expect(display.shows("https://example.com/feed.xml"));

    _ = try application.handle_key(.{ .character = 'h' });
    try render(application, display);
    try std.testing.expect(!display.shows("https://example.com/feed.xml"));
}

test "searching in the command centre over a full workspace does not collide" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    const model = @import("model.zig");
    var index: u16 = 2;
    while (index < 40) : (index += 1) {
        application.articles[index] = .{
            .feed_index = 0,
            .title = try model.ArticleTitle.init("Zig release candidate notes"),
            .url = try model.ArticleUrl.init("https://ziglang.org/x"),
        };
    }
    application.article_count = 40;
    application.refresh_articles();

    const display = try Display.create(std.testing.allocator, 120, 30, .none);
    defer display.destroy(std.testing.allocator);
    try render(application, display);

    _ = try application.handle_key(.{ .character = ':' });
    for ("zig") |byte| {
        _ = try application.handle_key(.{ .character = byte });
        try render(application, display);
    }
    try std.testing.expect(application.command.count > 0);
}

test "the centre searches by default and keeps actions behind >" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);

    _ = try application.handle_key(.{ .character = ':' });
    try std.testing.expectEqual(@as(u16, 0), application.command.count);

    for ("zig") |byte| _ = try application.handle_key(.{ .character = byte });
    try std.testing.expect(application.command.count > 0);
    var index: u16 = 0;
    while (index < application.command.count) : (index += 1) {
        try std.testing.expect(application.command.results[index] != .action);
    }

    while (application.command.query().len > 0) {
        _ = try application.handle_key(.backspace);
    }
    for ("> zig") |byte| _ = try application.handle_key(.{ .character = byte });
    index = 0;
    while (index < application.command.count) : (index += 1) {
        try std.testing.expect(application.command.results[index] == .action);
    }
}

test "a non-ascii title does not crash the highlighted results" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    const model = @import("model.zig");
    application.articles[0] = .{
        .feed_index = 0,
        .title = try model.ArticleTitle.init(
            "GenRec: Towards LLM\u{2011}Native Recommendation at Netflix",
        ),
        .url = try model.ArticleUrl.init("https://netflixtechblog.com/a"),
    };
    application.articles[1] = .{
        .feed_index = 1,
        .title = try model.ArticleTitle.init(
            "Probabilistc models of cognition \u{2013} chapter three",
        ),
        .url = try model.ArticleUrl.init("https://probmods.org/"),
    };
    application.refresh_articles();

    const display = try Display.create(std.testing.allocator, 100, 20, .none);
    defer display.destroy(std.testing.allocator);

    _ = try application.handle_key(.{ .character = ':' });
    for ("ne") |byte| {
        _ = try application.handle_key(.{ .character = byte });
        try render(application, display);
    }
    try std.testing.expect(application.command.count > 0);

    _ = try application.handle_key(.escape);
    _ = try application.handle_key(.{ .character = '/' });
    for ("the") |byte| {
        _ = try application.handle_key(.{ .character = byte });
        try render(application, display);
    }
}

test "the help sheet covers what it opens over" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    const display = try Display.create(std.testing.allocator, 110, 30, .none);
    defer display.destroy(std.testing.allocator);

    try render(application, display);
    try std.testing.expect(display.shows("Tiger Style"));

    _ = try application.handle_key(.{ .character = '?' });
    try render(application, display);
    try std.testing.expect(display.shows("KEYBOARD HELP"));
    try std.testing.expect(!display.shows("Tiger Style"));
    try std.testing.expect(!display.shows("Zig Release Notes"));

    _ = try application.handle_key(.escape);
    try render(application, display);
    try std.testing.expect(display.shows("Tiger Style"));
}
