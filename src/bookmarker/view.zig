const std = @import("std");
const markix = @import("markix");
const dom_view = @import("dom_view.zig");
const command_center = @import("../ui/command_center.zig");
const Display = @import("../ui/display.zig").Display;
const application_module = @import("application.zig");

pub fn render(application: anytype, display: *Display) !void {
    try dom_view.sync(&application.dom_view, application, display);
    display.present();
}

const testing = std.testing;

fn seeded_application() !*application_module.Application {
    const Application = application_module.Application;
    const Bookmark = @import("data").bookmarks.Bookmark;
    const application = try Application.create(
        testing.allocator,
        testing.io,
        &@import("data").paths.testing_paths,
    );
    errdefer application.destroy(testing.allocator);
    const titles = [_][]const u8{ "Tiger Style", "Zig News", "Sqlite Docs" };
    const urls = [_][]const u8{
        "https://tigerbeetle.com",
        "https://ziglang.org",
        "https://sqlite.org",
    };
    for (titles, urls) |title, url| {
        try application.store.add(try Bookmark.init(title, url, "systems", ""));
    }
    application.rebuild_tags();
    var index: u16 = 0;
    while (index < application.store.count) : (index += 1) {
        application.filtered[index] = index;
    }
    application.filtered_count = application.store.count;
    std.debug.assert(application.store.count == titles.len);
    std.debug.assert(application.filtered_count == titles.len);
    return application;
}

fn single_application(bookmark: anytype) !*application_module.Application {
    const application = try application_module.Application.create(
        testing.allocator,
        testing.io,
        &@import("data").paths.testing_paths,
    );
    errdefer application.destroy(testing.allocator);
    try application.store.add(bookmark);
    application.rebuild_tags();
    application.filtered[0] = 0;
    application.filtered_count = 1;
    return application;
}

fn type_text(application: anytype, text: []const u8) !void {
    for (text) |byte| _ = try application.handle_key(.{ .character = byte });
}

test "list panes render through the tree" {
    const application = try seeded_application();
    defer application.destroy(testing.allocator);
    const display = try Display.create(testing.allocator, 120, 30, .none);
    defer display.destroy(testing.allocator);

    try render(application, display);
    try testing.expect(display.shows("BROWSE"));
    try testing.expect(display.shows("BOOKMARKS"));
    try testing.expect(display.shows("Tiger Style"));
    try testing.expect(display.shows("Zig News"));
    try testing.expect(display.shows("All"));
    try testing.expect(display.shows("Favorites"));
}

test "the header, preview and status line render through the tree" {
    const application = try seeded_application();
    defer application.destroy(testing.allocator);
    try application.store.items[0].description.set("Reliable systems software.");
    const display = try Display.create(testing.allocator, 120, 30, .none);
    defer display.destroy(testing.allocator);

    try render(application, display);
    try testing.expect(display.shows("All bookmarks"));
    try testing.expect(display.shows("Browse"));
    try testing.expect(display.shows("PREVIEW"));
    try testing.expect(display.shows("https://tigerbeetle.com"));
    try testing.expect(display.shows("SUMMARY"));
    try testing.expect(display.shows("Reliable systems software."));
    try testing.expect(display.shows("NOT FETCHED"));
    try testing.expect(display.shows("quit"));
}

test "a steady frame repaints nothing and keeps its panes" {
    const application = try seeded_application();
    defer application.destroy(testing.allocator);
    const display = try Display.create(testing.allocator, 120, 30, .none);
    defer display.destroy(testing.allocator);

    try render(application, display);
    try render(application, display);
    try testing.expectEqual(@as(i32, 0), display.painted_area());
    try testing.expect(display.shows("Tiger Style"));
    try testing.expect(display.shows("BOOKMARKS"));
}

test "moving the bookmark cursor repaints only what changed" {
    const application = try seeded_application();
    defer application.destroy(testing.allocator);
    const display = try Display.create(testing.allocator, 120, 30, .none);
    defer display.destroy(testing.allocator);

    try render(application, display);
    const full_frame = display.painted_area();
    _ = try application.handle_key(.{ .character = 'j' });
    try render(application, display);
    const moved = display.painted_area();
    try testing.expect(moved > 0);
    try testing.expect(moved < @divFloor(full_frame, 2));
    try testing.expect(display.shows("Tiger Style"));
    try testing.expect(display.shows("Zig News"));
    try testing.expect(display.shows("All"));
}

test "switching pane focus repaints" {
    const application = try seeded_application();
    defer application.destroy(testing.allocator);
    const display = try Display.create(testing.allocator, 120, 30, .none);
    defer display.destroy(testing.allocator);

    try render(application, display);
    application.browser_focus = .scopes;
    try render(application, display);
    try testing.expect(display.painted_area() > 0);
    try testing.expect(display.shows("All"));
    try testing.expect(display.shows("Tiger Style"));
}

test "a long running loop settles" {
    const application = try seeded_application();
    defer application.destroy(testing.allocator);
    try application.store.items[0].preview.set(
        "Reliable systems software with explicit operational limits, written " ++
            "down so the whole team can check them against the machine.",
    );
    const display = try Display.create(testing.allocator, 120, 30, .none);
    defer display.destroy(testing.allocator);

    var frame: u16 = 0;
    while (frame < 300) : (frame += 1) {
        _ = try application.handle_key(.{ .character = if (frame % 2 == 0) 'j' else 'k' });
        try render(application, display);
    }
    try render(application, display);
    try testing.expectEqual(@as(i32, 0), display.painted_area());
    try testing.expect(display.shows("Tiger Style"));
    try testing.expect(display.shows("CONTENT"));
}

test "the selection lands in the frame that moved it" {
    const application = try seeded_application();
    defer application.destroy(testing.allocator);
    const display = try Display.create(testing.allocator, 120, 8, .none);
    defer display.destroy(testing.allocator);

    try render(application, display);
    _ = try application.handle_key(.{ .character = 'j' });
    _ = try application.handle_key(.{ .character = 'j' });
    try render(application, display);
    try testing.expectEqual(@as(u16, 2), application.selected);
    try testing.expect(display.shows("Sqlite Docs"));
}

test "an in place store edit shows on the next frame" {
    const application = try seeded_application();
    defer application.destroy(testing.allocator);
    const display = try Display.create(testing.allocator, 120, 30, .none);
    defer display.destroy(testing.allocator);

    try render(application, display);
    try application.store.items[1].title.set("Zig Newz");
    try render(application, display);
    try testing.expect(display.shows("Zig Newz"));
    try testing.expect(!display.shows("Zig News"));
}

test "a preview scrolls through its fetched content" {
    const Bookmark = @import("data").bookmarks.Bookmark;
    const application = try single_application(
        try Bookmark.init("Tiger Style", "https://tigerbeetle.com", "systems", ""),
    );
    defer application.destroy(testing.allocator);
    try application.store.items[0].preview.set(
        "one two three four five six seven eight nine ten eleven twelve " ++
            "thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty",
    );
    const display = try Display.create(testing.allocator, 40, 16, .none);
    defer display.destroy(testing.allocator);
    application.narrow_preview = true;

    try render(application, display);
    try testing.expect(display.shows("CONTENT"));
    try testing.expect(application.preview_line_count > 1);
    try testing.expect(display.shows("1/"));
}

test "bookmark view renders responsive layouts" {
    const Bookmark = @import("data").bookmarks.Bookmark;
    var bookmark = try Bookmark.init("", "https://tigerbeetle.com", "systems", "Read later");
    try bookmark.preview.set("Reliable systems software with explicit operational limits.");
    const application = try single_application(bookmark);
    defer application.destroy(testing.allocator);
    const display = try Display.create(testing.allocator, 120, 20, .none);
    defer display.destroy(testing.allocator);

    try render(application, display);
    try testing.expect(display.shows("PREVIEW"));
    display.resize(80, 10);
    try render(application, display);
    try testing.expect(display.shows("PREVIEW"));
    display.resize(40, 8);
    try render(application, display);
    try testing.expect(display.shows("BOOKMARKS"));
}

test "the add form renders its fields" {
    const application = try seeded_application();
    defer application.destroy(testing.allocator);
    _ = try application.handle_key(.{ .character = ':' });
    try type_text(application, "> with details");
    _ = try application.handle_key(.enter);
    const display = try Display.create(testing.allocator, 120, 20, .none);
    defer display.destroy(testing.allocator);

    try render(application, display);
    try testing.expect(display.shows("NEW BOOKMARK"));
    try testing.expect(display.shows("TITLE"));
    try testing.expect(display.shows("Page title"));
    try testing.expect(display.shows("cancel"));
    try testing.expectEqual(@as(u8, 4), application.mouse_layout.field_count);
    const url = application.mouse_layout.fields[1];
    try testing.expectEqual(application_module.Field.url, url.field);
    try testing.expect(url.rect.width > 0);
}

test "the command centre floats over the workspace at every width" {
    const Bookmark = @import("data").bookmarks.Bookmark;
    const application = try single_application(
        try Bookmark.init("Tiger Style", "https://tigerbeetle.com", "systems", ""),
    );
    defer application.destroy(testing.allocator);
    _ = try application.handle_key(.{ .character = ':' });
    try type_text(application, "> add bookmark");
    const display = try Display.create(testing.allocator, 120, 20, .none);
    defer display.destroy(testing.allocator);

    try render(application, display);
    try testing.expect(display.shows("COMMAND CENTRE"));
    try testing.expect(application.command.count > 0);
    try testing.expect(application.mouse_layout.command_results != null);
    display.resize(80, 10);
    try render(application, display);
    try testing.expect(display.shows("COMMAND CENTRE"));
    display.resize(40, 8);
    try render(application, display);
    try testing.expect(display.shows("COMMAND CENTRE"));
}

test "focus mode renders a list and a floating finder" {
    const Bookmark = @import("data").bookmarks.Bookmark;
    const application = try single_application(
        try Bookmark.init("Tiger Style", "https://tigerbeetle.com", "systems", ""),
    );
    defer application.destroy(testing.allocator);
    _ = try application.handle_key(.{ .character = 'z' });
    const display = try Display.create(testing.allocator, 120, 20, .none);
    defer display.destroy(testing.allocator);

    try render(application, display);
    try testing.expect(display.shows("ZEN LIBRARY"));
    try testing.expect(!display.shows("PREVIEW"));
    try testing.expect(application.mouse_layout.focus != null);

    _ = try application.handle_key(.{ .character = '/' });
    display.resize(80, 24);
    try render(application, display);
    try testing.expect(display.shows("FIND BOOKMARKS"));
    try testing.expect(display.shows("FILTER"));
    try testing.expect(display.shows("ZEN LIBRARY"));
    try testing.expect(application.mouse_layout.focus_modal != null);
    try testing.expect(application.mouse_layout.finder_results != null);
    try testing.expect(application.mouse_layout.category_count > 0);
    const finder = command_center.rect_for(markix.Rect.init(0, 2, 80, 21));
    try testing.expect(display.shows_in("Tiger Style", finder));

    display.resize(40, 8);
    try render(application, display);
    try testing.expect(display.shows("FIND BOOKMARKS"));
}

test "the help sheet floats over the workspace from one keymap" {
    const application = try seeded_application();
    defer application.destroy(testing.allocator);
    const display = try Display.create(testing.allocator, 120, 40, .none);
    defer display.destroy(testing.allocator);

    _ = try application.handle_key(.{ .character = '?' });
    try render(application, display);
    try testing.expect(display.shows("KEYBOARD HELP"));
    try testing.expect(display.shows("command centre"));
    try testing.expect(display.shows("reader / bookmarks"));
    try testing.expect(display.shows("toggle favourite"));

    _ = try application.handle_key(.escape);
    try render(application, display);
    try testing.expect(!display.shows("KEYBOARD HELP"));
    try testing.expect(display.shows("Tiger Style"));
}

test "the status line advertises switching experiences everywhere" {
    const application = try seeded_application();
    defer application.destroy(testing.allocator);
    const display = try Display.create(testing.allocator, 120, 20, .none);
    defer display.destroy(testing.allocator);

    try render(application, display);
    try testing.expect(display.shows("ctrl-u"));
    try testing.expect(display.shows("switch"));
}

test "the command centre opens on ctrl-p as well as colon" {
    const application = try seeded_application();
    defer application.destroy(testing.allocator);
    const display = try Display.create(testing.allocator, 120, 20, .none);
    defer display.destroy(testing.allocator);

    _ = try application.handle_key(.{ .control = 'p' });
    try render(application, display);
    try testing.expect(display.shows("COMMAND CENTRE"));
}

test "adding a bookmark asks for the URL then its tags" {
    const application = try seeded_application();
    defer application.destroy(testing.allocator);

    _ = try application.handle_key(.{ .character = 'a' });
    try testing.expect(application.command.is_collecting());
    try testing.expectEqualStrings("Add bookmark", application.active_label());
    try type_text(application, "https://example.com/one");
    _ = try application.handle_key(.enter);
    try testing.expect(application.command.is_collecting());
    try type_text(application, "reading, zig");
    _ = try application.handle_key(.enter);

    try testing.expect(!application.command.is_open());
    const added = application.store.items[application.store.count - 1];
    try testing.expectEqualStrings("https://example.com/one", added.url.bytes());
    try testing.expectEqualStrings("reading, zig", added.tags.bytes());
}
