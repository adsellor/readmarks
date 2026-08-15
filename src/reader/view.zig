const std = @import("std");
const markix = @import("markix");
const terminal = markix.terminal;
const theme = @import("../theme.zig");
const dom_view = @import("dom_view.zig");

const Surface = terminal.Surface;

pub fn render(application: anytype, canvas: *terminal.TerminalCanvas) !void {
    const surface = Surface{ .canvas = canvas };
    const bounds = surface.bounds();
    const view = &application.dom_view;
    view.observe_canvas(canvas.width, canvas.height);

    const full = try dom_view.sync(view, application, bounds);
    var renderer = markix.render.TerminalRenderer.init(canvas, theme.background);
    renderer.begin();
    // Gaps between panes belong to no node, so one clear on rebuild covers
    // them without touching the panes on steady-state frames.
    if (full) canvas.clear_rect(bounds, theme.background);
    try renderer.paint_tree(&view.tree);
    view.last_painted = renderer.painted;

    dom_view.register_geometry(view, application);
    try register_selection(surface, view);
}

/// Marks the regions text can be selected in. Frame state, so it is registered
/// every frame including one on which nothing repainted.
fn register_selection(surface: Surface, view: *dom_view.View) !void {
    const regions = view.regions;
    try mark(surface, regions.categories, theme.selection_browse);
    try mark(surface, regions.feeds, theme.selection_browse);
    try mark(surface, regions.articles, theme.selection_bookmarks);
    try mark(surface, regions.document, theme.selection_preview);
    try mark(surface, regions.finder_results, theme.selection_command);
    try mark(surface, regions.command_results, theme.selection_command);
}

fn mark(
    surface: Surface,
    region: ?markix.Rect,
    style: markix.TextSelectionStyle,
) !void {
    const rect = region orelse return;
    if (rect.width == 0 or rect.height == 0) return;
    try surface.selectable(rect, style);
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
    return application;
}

fn canvas_has_text(canvas: *const terminal.TerminalCanvas, text: []const u8) bool {
    var y: u16 = 0;
    while (y < @divFloor(canvas.height + 1, 2)) : (y += 1) {
        var x: u16 = 0;
        while (x < canvas.width) : (x += 1) {
            const entry = canvas.text_at(x, y) orelse continue;
            if (std.mem.eql(u8, entry.bytes(), text)) return true;
        }
    }
    return false;
}

test "the workspace renders its panes through the dom tree" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 130, 60);
    defer canvas.deinit();

    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "CATEGORIES"));
    try std.testing.expect(canvas_has_text(&canvas, "FEEDS"));
    try std.testing.expect(canvas_has_text(&canvas, "ARTICLES"));
    try std.testing.expect(canvas_has_text(&canvas, "READER"));
    try std.testing.expect(canvas_has_text(&canvas, "Tiger Style"));
    try std.testing.expect(canvas_has_text(&canvas, "Tiger Beetle"));
}

test "the header carries the same tab bar the bookmarker has" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 130, 60);
    defer canvas.deinit();

    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "All articles"));
    try std.testing.expect(canvas_has_text(&canvas, "Categories"));
    try std.testing.expect(canvas_has_text(&canvas, "Articles"));
    // And the status line advertises the two keys that are true everywhere.
    try std.testing.expect(canvas_has_text(&canvas, "ctrl-u"));
    try std.testing.expect(canvas_has_text(&canvas, "switch"));
}

test "the command centre opens over the reader" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 130, 60);
    defer canvas.deinit();

    _ = try application.handle_key(.{ .character = ':' });
    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "COMMAND CENTRE"));
    try std.testing.expectEqual(@as(u16, 0), application.command.count);
    canvas.commit_frame();

    for ("> refresh") |byte| _ = try application.handle_key(.{ .character = byte });
    try std.testing.expect(application.command.count > 0);
    var index: u16 = 0;
    while (index < application.command.count) : (index += 1) {
        try std.testing.expect(application.command.results[index] == .action);
    }
    while (application.command.query().len > 0) {
        _ = try application.handle_key(.backspace);
    }

    // Typing brings the collection in, ranked, with the best match selected.
    for ("zig re") |byte| _ = try application.handle_key(.{ .character = byte });
    try render(application, &canvas);
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
    // The feed itself, and nothing else: matching articles against their feed
    // listed every article of that feed beside it.
    try std.testing.expectEqual(@as(u16, 1), application.command.count);
    try std.testing.expect(application.command.results[0] == .feed);
}

test "ctrl-p opens the same command centre" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 130, 60);
    defer canvas.deinit();

    _ = try application.handle_key(.{ .control = 'p' });
    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "COMMAND CENTRE"));
}

test "zen mode shows the articles alone and finds within them" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 130, 60);
    defer canvas.deinit();

    _ = try application.handle_key(.{ .character = 'z' });
    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "ZEN LIBRARY"));
    try std.testing.expect(!canvas_has_text(&canvas, "CATEGORIES"));
    canvas.commit_frame();

    _ = try application.handle_key(.{ .character = '/' });
    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "FIND ARTICLES"));
    try std.testing.expect(canvas_has_text(&canvas, "FILTER"));
}

test "the help sheet reads from the shared keymap" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 130, 80);
    defer canvas.deinit();

    _ = try application.handle_key(.{ .character = '?' });
    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "KEYBOARD HELP"));
    try std.testing.expect(canvas_has_text(&canvas, "command centre"));
    try std.testing.expect(canvas_has_text(&canvas, "reader / bookmarks"));
    // And the reader's own keys, after the shared ones.
    try std.testing.expect(canvas_has_text(&canvas, "full-screen reader"));
}

test "the document renders the article body" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 130, 60);
    defer canvas.deinit();

    _ = try application.handle_key(.{ .character = 'v' });
    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "Reliable systems software."));
}

test "search narrows the list as it is typed" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 130, 60);
    defer canvas.deinit();

    _ = try application.handle_key(.{ .character = '/' });
    _ = try application.handle_key(.{ .character = 'Z' });
    _ = try application.handle_key(.{ .character = 'i' });
    _ = try application.handle_key(.{ .character = 'g' });
    // No Enter: the filter is already applied.
    try std.testing.expectEqual(@as(u16, 1), application.filtered_article_count);
    try render(application, &canvas);
    // The surviving row's feed is drawn. Its title is split into runs by the
    // match highlight, so it is the subtitle that compares whole; the article
    // that no longer matches is gone from the list entirely.
    try std.testing.expect(canvas_has_text(&canvas, "Zig News"));
    try std.testing.expect(!canvas_has_text(&canvas, "Tiger Style"));
}

test "a steady frame repaints nothing and keeps its panes" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 130, 60);
    defer canvas.deinit();

    try render(application, &canvas);
    canvas.commit_frame();
    try render(application, &canvas);
    try std.testing.expectEqual(@as(u16, 0), application.dom_view.last_painted);
    try std.testing.expect(canvas_has_text(&canvas, "Tiger Style"));
    try std.testing.expect(canvas_has_text(&canvas, "ARTICLES"));
}

test "moving the article cursor repaints less than a full frame" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 130, 60);
    defer canvas.deinit();

    try render(application, &canvas);
    const full_frame = application.dom_view.last_painted;
    canvas.commit_frame();

    _ = try application.handle_key(.{ .character = 'j' });
    try render(application, &canvas);
    const moved = application.dom_view.last_painted;
    try std.testing.expect(moved > 0);
    try std.testing.expect(moved < full_frame);
}

test "narrow and medium widths still render" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 130, 60);
    defer canvas.deinit();
    canvas.resizable = true;

    try render(application, &canvas);
    canvas.commit_frame();
    try canvas.resize(90, 40);
    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "ARTICLES"));
    canvas.commit_frame();
    try canvas.resize(50, 30);
    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "ARTICLES"));
}

test "M marks only what the current scope is showing" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 2), application.unread_count());

    // Focus one feed, so the list shows that feed's articles alone.
    application.active_feed = 0;
    application.refresh_articles();
    try std.testing.expectEqual(@as(u16, 1), application.filtered_article_count);

    _ = try application.handle_key(.{ .character = 'M' });
    // The focused feed is cleared; the other feed's article is untouched.
    try std.testing.expectEqual(@as(u16, 1), application.unread_count());
    try std.testing.expectEqual(@as(u16, 0), application.feed_unread_count(0));
    try std.testing.expectEqual(@as(u16, 1), application.feed_unread_count(1));
}

test "M with no feed focused clears everything shown" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);

    _ = try application.handle_key(.{ .character = 'M' });
    try std.testing.expectEqual(@as(u16, 0), application.unread_count());
    // Saying so, rather than leaving the reader to guess what happened.
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
    // Only the article the search left visible was marked.
    try std.testing.expectEqual(@as(u16, 1), application.unread_count());
}

test "the command centre offers marking everything read" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 130, 60);
    defer canvas.deinit();

    _ = try application.handle_key(.{ .character = ':' });
    for ("> mark every") |byte| _ = try application.handle_key(.{ .character = byte });
    try render(application, &canvas);
    // The title is drawn in runs by the match highlight, so the result itself
    // is what gets compared rather than the pixels.
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
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 130, 60);
    defer canvas.deinit();

    application.subscription_path = try @import("model.zig").FeedUrl.init(
        "/tmp/readmarks-add-probe/feeds",
    );
    _ = try application.handle_key(.{ .character = 'a' });
    try std.testing.expect(application.command.is_collecting());
    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "Add a feed"));
    try std.testing.expect(!canvas_has_text(&canvas, "Refresh every feed"));

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
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 120, 40);
    defer canvas.deinit();

    _ = try application.handle_key(.{ .character = 'a' });
    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "https://example.com/feed.xml"));
    canvas.commit_frame();

    _ = try application.handle_key(.{ .character = 'h' });
    try render(application, &canvas);
    try std.testing.expect(!canvas_has_text(&canvas, "https://example.com/feed.xml"));
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

    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 120, 60);
    defer canvas.deinit();
    try render(application, &canvas);
    canvas.commit_frame();

    _ = try application.handle_key(.{ .character = ':' });
    for ("zig") |byte| {
        _ = try application.handle_key(.{ .character = byte });
        try render(application, &canvas);
        canvas.commit_frame();
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

    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 100, 40);
    defer canvas.deinit();

    _ = try application.handle_key(.{ .character = ':' });
    for ("ne") |byte| {
        _ = try application.handle_key(.{ .character = byte });
        try render(application, &canvas);
        canvas.commit_frame();
    }
    try std.testing.expect(application.command.count > 0);

    _ = try application.handle_key(.escape);
    _ = try application.handle_key(.{ .character = '/' });
    for ("the") |byte| {
        _ = try application.handle_key(.{ .character = byte });
        try render(application, &canvas);
        canvas.commit_frame();
    }
}

test "the help sheet covers what it opens over" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 110, 60);
    defer canvas.deinit();

    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "Tiger Style"));
    canvas.commit_frame();

    _ = try application.handle_key(.{ .character = '?' });
    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "KEYBOARD HELP"));
    // Nothing from the workspace shows through the gaps in the sheet.
    try std.testing.expect(!canvas_has_text(&canvas, "Tiger Style"));
    try std.testing.expect(!canvas_has_text(&canvas, "ARTICLES"));
    canvas.commit_frame();

    _ = try application.handle_key(.escape);
    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "Tiger Style"));
}
