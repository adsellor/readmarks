const std = @import("std");
const markix = @import("markix");
const terminal = markix.terminal;
const layout = markix.layout;
const application_module = @import("application.zig");
const dom_view = @import("dom_view.zig");
const theme = @import("../theme.zig");

const Rect = layout.Rect;
const Surface = terminal.Surface;
const bookmark_list_visual = dom_view.bookmark_list_visual;
const focus_finder_rect = dom_view.focus_finder_rect;

pub fn render(application: anytype, canvas: *terminal.TerminalCanvas) !void {
    application.mouse_layout = .{};
    const surface = Surface{ .canvas = canvas };
    const bounds = surface.bounds();
    const view = &application.dom_view;
    view.observe_canvas(canvas.width, canvas.height);

    // The DOM owns the whole frame. Syncing computes dirt; a rebuild means the
    // layout itself moved.
    const full = try dom_view.sync(view, application, bounds);
    var renderer = markix.render.TerminalRenderer.init(canvas, theme.background);
    renderer.begin();
    // Gaps between panes belong to no node. They only move when the layout
    // does, so one clear on rebuild covers them without touching the panes on
    // steady-state frames.
    if (full) canvas.clear_rect(bounds, theme.background);
    try renderer.paint_tree(&view.tree);
    view.last_painted = renderer.painted;

    // Hit boxes and selection regions are frame state that starting a frame
    // resets, so they are registered every frame -- including a frame on which
    // nothing repainted, where the panes are still on screen and still clickable.
    try register_regions(application, surface, view);
}

/// Hands this frame's node rects to the application as regions a pointer can
/// hit, and to the canvas as regions text can be selected in.
fn register_regions(
    application: anytype,
    surface: Surface,
    view: *dom_view.View,
) !void {
    const regions = view.regions;
    if (regions.scopes) |rect| {
        application.mouse_layout.scopes = .{
            .rect = rect,
            .scroll = application.scope_scroll,
            .row_height = 1,
        };
        try surface.selectable(rect, theme.selection_browse);
    }
    if (regions.bookmarks) |rect| {
        application.mouse_layout.bookmarks = bookmark_region(rect, application.scroll);
        try surface.selectable(rect, theme.selection_bookmarks);
    }
    if (regions.preview) |rect| {
        application.mouse_layout.preview = rect;
        try surface.selectable(rect, theme.selection_preview);
    }
    if (regions.focus) |rect| {
        application.mouse_layout.focus = bookmark_region(rect, application.scroll);
        try surface.selectable(rect, theme.selection_bookmarks);
    }
    if (regions.focus_modal) |rect| application.mouse_layout.focus_modal = rect;
    if (regions.finder_results) |rect| {
        application.mouse_layout.finder_results = bookmark_region(
            rect,
            application.scroll,
        );
        try surface.selectable(rect, theme.selection_command);
    }
    if (regions.command_results) |rect| {
        application.mouse_layout.command_results = .{
            .rect = rect,
            .scroll = application.command.scroll,
            .row_height = dom_view.command_list_visual.row_height,
        };
    }
    register_categories(application, regions);
    register_fields(application, regions);
}

fn register_categories(application: anytype, regions: dom_view.Regions) void {
    std.debug.assert(regions.category_count <= application.mouse_layout.categories.len);
    var index: u8 = 0;
    while (index < regions.category_count) : (index += 1) {
        application.mouse_layout.categories[index] = .{
            .rect = regions.categories[index].rect,
            .scope_index = regions.categories[index].scope_index,
        };
    }
    application.mouse_layout.category_count = regions.category_count;
}

fn register_fields(application: anytype, regions: dom_view.Regions) void {
    const fields = [_]application_module.Field{ .title, .url, .tags, .notes };
    std.debug.assert(regions.field_count <= fields.len);
    var index: u8 = 0;
    while (index < regions.field_count) : (index += 1) {
        application.mouse_layout.fields[index] = .{
            .rect = regions.fields[index],
            .field = fields[index],
        };
    }
    application.mouse_layout.field_count = regions.field_count;
}

fn bookmark_region(rect: Rect, scroll: u16) application_module.MouseListRegion {
    return .{
        .rect = rect,
        .scroll = scroll,
        .row_height = bookmark_list_visual.row_height,
    };
}

fn seeded_application() !*application_module.Application {
    const Application = application_module.Application;
    const Bookmark = @import("data").bookmarks.Bookmark;
    const application = try Application.create(
        std.testing.allocator,
        std.testing.io,
        &@import("data").paths.testing_paths,
    );
    errdefer application.destroy(std.testing.allocator);
    const titles = [_][]const u8{ "Tiger Style", "Zig News", "Sqlite Docs" };
    const urls = [_][]const u8{
        "https://tigerbeetle.com",
        "https://ziglang.org",
        "https://sqlite.org",
    };
    for (titles, urls) |title, url| {
        const bookmark = try Bookmark.init(title, url, "systems", "");
        try application.store.add(bookmark);
    }
    application.rebuild_tags();
    var index: u16 = 0;
    while (index < application.store.count) : (index += 1) {
        application.filtered[index] = index;
    }
    application.filtered_count = application.store.count;
    return application;
}

test "list panes render through the dom tree" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 120, 60);
    defer canvas.deinit();

    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "BROWSE"));
    try std.testing.expect(canvas_has_text(&canvas, "BOOKMARKS"));
    try std.testing.expect(canvas_has_text(&canvas, "Tiger Style"));
    try std.testing.expect(canvas_has_text(&canvas, "Zig News"));
    try std.testing.expect(canvas_has_text(&canvas, "All"));
    try std.testing.expect(canvas_has_text(&canvas, "Favorites"));
}

test "the header, preview and status line render through the dom tree" {
    // Everything outside the list panes is a node too, so a frame is one tree
    // rather than a tree with drawing around it.
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    try application.store.items[0].description.set("Reliable systems software.");
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 120, 60);
    defer canvas.deinit();

    try render(application, &canvas);
    // Header: title, counts and the breadcrumb.
    try std.testing.expect(canvas_has_text(&canvas, "All bookmarks"));
    try std.testing.expect(canvas_has_text(&canvas, "Browse"));
    // Preview: the selected bookmark, its link and its sections.
    try std.testing.expect(canvas_has_text(&canvas, "PREVIEW"));
    try std.testing.expect(canvas_has_text(&canvas, "https://tigerbeetle.com"));
    try std.testing.expect(canvas_has_text(&canvas, "SUMMARY"));
    try std.testing.expect(canvas_has_text(&canvas, "NOT FETCHED"));
    // Status line: the mode's hints.
    try std.testing.expect(canvas_has_text(&canvas, "quit"));
}

test "a steady frame repaints nothing and keeps its panes" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 120, 60);
    defer canvas.deinit();

    try render(application, &canvas);
    canvas.commit_frame();
    try render(application, &canvas);
    // Nothing changed, so no node repainted -- and the panes are still there,
    // carried forward from the previous frame rather than redrawn.
    try std.testing.expectEqual(@as(u16, 0), application.dom_view.last_painted);
    try std.testing.expect(canvas_has_text(&canvas, "Tiger Style"));
    try std.testing.expect(canvas_has_text(&canvas, "BOOKMARKS"));
}

test "moving the bookmark cursor repaints only the panes that changed" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 120, 60);
    defer canvas.deinit();

    try render(application, &canvas);
    const full_frame = application.dom_view.last_painted;
    canvas.commit_frame();

    _ = try application.handle_key(.{ .character = 'j' });
    try render(application, &canvas);
    // Selection lives on the list, which paints over its rows, so the bookmark
    // list and its rows repaint, and so does the preview now showing a
    // different bookmark. The scope rows and the header do not.
    const moved = application.dom_view.last_painted;
    try std.testing.expect(moved > 0);
    try std.testing.expect(moved < full_frame / 2);
    try std.testing.expect(canvas_has_text(&canvas, "Tiger Style"));
    try std.testing.expect(canvas_has_text(&canvas, "Zig News"));
    try std.testing.expect(canvas_has_text(&canvas, "All"));
}

test "switching pane focus repaints both panes" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 120, 60);
    defer canvas.deinit();

    try render(application, &canvas);
    canvas.commit_frame();

    // Focus is node state, not props. Setting it through the node alone would
    // dirty the node without the tree agreeing, and the frame would be skipped.
    application.browser_focus = .scopes;
    try render(application, &canvas);
    try std.testing.expect(application.dom_view.last_painted > 0);
    try std.testing.expect(canvas_has_text(&canvas, "All"));
    try std.testing.expect(canvas_has_text(&canvas, "Tiger Style"));
}

test "a long running loop keeps text entries bounded" {
    // Mirrors the real event loop: render then commit, over and over. Partial
    // frames carry the previous frame forward, so anything that leaves dead
    // text records behind overflows the canvas after a few hundred frames.
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 120, 60);
    defer canvas.deinit();

    var frame: u16 = 0;
    var settled: usize = 0;
    while (frame < 300) : (frame += 1) {
        try render(application, &canvas);
        canvas.commit_frame();
        if (frame == 20) settled = canvas.previous_text_entries.items.len;
    }
    try std.testing.expect(settled > 0);
    try std.testing.expectEqual(settled, canvas.previous_text_entries.items.len);
    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "Tiger Style"));
    try std.testing.expect(canvas_has_text(&canvas, "BOOKMARKS"));
}

test "scrolling the preview over many frames stays bounded" {
    // The crash came through the preview, which emits an entry per row every
    // frame it repaints.
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 120, 60);
    defer canvas.deinit();
    try application.store.items[0].preview.set(
        "Reliable systems software with explicit operational limits, written " ++
            "down so the whole team can check them against the machine.",
    );

    var frame: u16 = 0;
    while (frame < 200) : (frame += 1) {
        _ = try application.handle_key(.{ .character = if (frame % 2 == 0) 'j' else 'k' });
        try render(application, &canvas);
        canvas.commit_frame();
    }
    try std.testing.expect(canvas.previous_text_entries.items.len < 1024);
}

test "the selection lands in the frame that moved it" {
    // Viewport sizing clamps scroll to keep the selection visible. Applying it
    // after the paint left the marker a frame behind, so it only caught up on
    // the next keypress.
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    // Two visible rows, so selecting the third has to scroll.
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 120, 14);
    defer canvas.deinit();

    try render(application, &canvas);
    canvas.commit_frame();
    _ = try application.handle_key(.{ .character = 'j' });
    _ = try application.handle_key(.{ .character = 'j' });
    try render(application, &canvas);
    // The scroll the frame painted with is the corrected one, not last frame's.
    try std.testing.expectEqual(@as(u16, 2), application.selected);
    try std.testing.expect(canvas_has_text(&canvas, "Sqlite Docs"));
}

test "a lost surface repaints the whole bookmarker" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 120, 60);
    defer canvas.deinit();

    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "Zig News"));
    canvas.commit_frame();

    // Stand in for the reader experience taking over the canvas: wipe it and
    // make that blank frame the baseline the next partial frame builds on.
    canvas.start_frame(theme.background);
    canvas.commit_frame();

    // Dirty flags track the tree against its own last paint, so it believes it
    // is still on screen and paints nothing. This is the artifact: panes stay
    // blank until a scroll or keypress happens to dirty them.
    try render(application, &canvas);
    try std.testing.expectEqual(@as(u16, 0), application.dom_view.last_painted);
    try std.testing.expect(!canvas_has_text(&canvas, "Zig News"));
    try std.testing.expect(!canvas_has_text(&canvas, "BOOKMARKS"));
    canvas.commit_frame();

    application.dom_view.invalidate_surface();
    try render(application, &canvas);
    try std.testing.expect(application.dom_view.last_painted > 0);
    try std.testing.expect(canvas_has_text(&canvas, "Zig News"));
    try std.testing.expect(canvas_has_text(&canvas, "BOOKMARKS"));
    try std.testing.expect(canvas_has_text(&canvas, "BROWSE"));
}

test "a resize that keeps the row count still repaints" {
    // resize wipes the canvas. 40 and 41 pixels are both 20 rows, so the shape
    // alone would call this frame unchanged and leave the panes blank.
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 120, 40);
    defer canvas.deinit();
    canvas.resizable = true;

    try render(application, &canvas);
    canvas.commit_frame();
    try canvas.resize(120, 41);
    try render(application, &canvas);
    try std.testing.expect(application.dom_view.last_painted > 0);
    try std.testing.expect(canvas_has_text(&canvas, "Zig News"));
    try std.testing.expect(canvas_has_text(&canvas, "BOOKMARKS"));
}

test "switching experience marks the bookmarker surface lost" {
    const RootApplication = @import("../application.zig").Application;
    const application = try RootApplication.create(
        std.testing.allocator,
        std.testing.io,
        &@import("data").paths.testing_paths,
    );
    defer application.destroy(std.testing.allocator);
    application.bookmarker.dom_view.surface_lost = false;
    _ = try application.handle_key(.{ .control = 'u' });
    try std.testing.expect(application.bookmarker.dom_view.surface_lost);

    application.bookmarker.dom_view.surface_lost = false;
    _ = try application.handle_key(.{ .control = 'u' });
    try std.testing.expect(application.bookmarker.dom_view.surface_lost);
}

test "an in place store edit is invalidated explicitly" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 120, 60);
    defer canvas.deinit();

    try render(application, &canvas);
    canvas.commit_frame();

    // Same length, same buffer: the node's old value aliases the new one, so
    // no comparison can see this. invalidate is how the store says so.
    try application.store.items[1].title.set("Zig Newz");
    application.dom_view.invalidate();
    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "Zig Newz"));
    try std.testing.expect(!canvas_has_text(&canvas, "Zig News"));
}

test "bookmark view renders scopes content and responsive layouts" {
    const Application = @import("application.zig").Application;
    const Bookmark = @import("data").bookmarks.Bookmark;
    const application = try Application.create(
        std.testing.allocator,
        std.testing.io,
        &@import("data").paths.testing_paths,
    );
    defer application.destroy(std.testing.allocator);
    var bookmark = try Bookmark.init("", "https://tigerbeetle.com", "systems", "Read later");
    try bookmark.preview.set("Reliable systems software with explicit operational limits.");
    try application.store.add(bookmark);
    application.rebuild_tags();
    application.filtered[0] = 0;
    application.filtered_count = 1;

    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 120, 40);
    defer canvas.deinit();
    canvas.resizable = true;
    try render(application, &canvas);
    canvas.text_entries.clearRetainingCapacity();
    try canvas.resize(80, 20);
    try render(application, &canvas);
    canvas.text_entries.clearRetainingCapacity();
    try canvas.resize(40, 16);
    try render(application, &canvas);
}

test "the add form renders its fields through the dom tree" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    _ = try application.handle_key(.{ .character = ':' });
    for ("> with details") |byte| _ = try application.handle_key(.{ .character = byte });
    _ = try application.handle_key(.enter);

    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 120, 40);
    defer canvas.deinit();
    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "NEW BOOKMARK"));
    try std.testing.expect(canvas_has_text(&canvas, "TITLE"));
    // The URL field has the focus, so it shows a cursor rather than its
    // placeholder; the fields behind it still show theirs.
    try std.testing.expect(canvas_has_text(&canvas, "Page title"));
    try std.testing.expect(canvas_has_text(&canvas, "cancel"));
    // Every field is clickable, at the cell the grid put it in.
    try std.testing.expectEqual(@as(u8, 4), application.mouse_layout.field_count);
}

test "command deck renders as a responsive sidecar" {
    const Application = @import("application.zig").Application;
    const Bookmark = @import("data").bookmarks.Bookmark;
    const application = try Application.create(
        std.testing.allocator,
        std.testing.io,
        &@import("data").paths.testing_paths,
    );
    defer application.destroy(std.testing.allocator);
    try application.store.add(
        try Bookmark.init("Tiger Style", "https://tigerbeetle.com", "systems", ""),
    );
    application.rebuild_tags();
    application.filtered[0] = 0;
    application.filtered_count = 1;
    _ = try application.handle_key(.{ .character = ':' });
    for ("> add bookmark") |byte| _ = try application.handle_key(.{ .character = byte });

    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 120, 40);
    defer canvas.deinit();
    canvas.resizable = true;
    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "COMMAND CENTRE"));
    try std.testing.expect(application.command.count > 0);
    try std.testing.expect(application.mouse_layout.command_results != null);
    canvas.text_entries.clearRetainingCapacity();
    try canvas.resize(80, 20);
    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "COMMAND CENTRE"));
    canvas.text_entries.clearRetainingCapacity();
    try canvas.resize(40, 16);
    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "COMMAND CENTRE"));
}

test "focus mode renders a list and responsive floating finder" {
    const Application = @import("application.zig").Application;
    const Bookmark = @import("data").bookmarks.Bookmark;
    const application = try Application.create(
        std.testing.allocator,
        std.testing.io,
        &@import("data").paths.testing_paths,
    );
    defer application.destroy(std.testing.allocator);
    try application.store.add(
        try Bookmark.init("Tiger Style", "https://tigerbeetle.com", "systems", ""),
    );
    application.rebuild_tags();
    application.filtered[0] = 0;
    application.filtered_count = 1;
    _ = try application.handle_key(.{ .character = 'z' });

    var focus_canvas = try terminal.TerminalCanvas.init(
        std.testing.allocator,
        120,
        40,
    );
    defer focus_canvas.deinit();
    try render(application, &focus_canvas);
    try std.testing.expect(canvas_has_text(&focus_canvas, "ZEN LIBRARY"));
    try std.testing.expect(!canvas_has_text(&focus_canvas, "PREVIEW"));
    try std.testing.expect(application.mouse_layout.focus != null);

    _ = try application.handle_key(.{ .character = '/' });
    var finder_canvas = try terminal.TerminalCanvas.init(
        std.testing.allocator,
        80,
        48,
    );
    defer finder_canvas.deinit();
    try render(application, &finder_canvas);
    try std.testing.expect(canvas_has_text(&finder_canvas, "FIND BOOKMARKS"));
    try std.testing.expect(canvas_has_text(&finder_canvas, "FILTER"));
    try std.testing.expect(canvas_has_text(&finder_canvas, "ZEN LIBRARY"));
    try std.testing.expect(application.mouse_layout.focus_modal != null);
    try std.testing.expect(application.mouse_layout.finder_results != null);
    try std.testing.expect(application.mouse_layout.category_count > 0);
    const finder = focus_finder_rect(Rect.init(0, 2, 80, 21));
    try std.testing.expect(canvas_has_text_in(&finder_canvas, "Tiger Style", finder));

    var narrow_canvas = try terminal.TerminalCanvas.init(
        std.testing.allocator,
        40,
        16,
    );
    defer narrow_canvas.deinit();
    try render(application, &narrow_canvas);
    try std.testing.expect(canvas_has_text(&narrow_canvas, "FIND BOOKMARKS"));
}

/// Scans live cells rather than `text_entries`, which retains records for text
/// that has since been cleared.
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

fn canvas_has_text_in(
    canvas: *const terminal.TerminalCanvas,
    text: []const u8,
    rect: Rect,
) bool {
    for (canvas.text_entries.items) |entry| {
        if (!std.mem.eql(u8, entry.bytes(), text)) continue;
        if (entry.x < rect.x or entry.x >= rect.right()) continue;
        if (entry.y < rect.y or entry.y >= rect.y + rect.height) continue;
        return true;
    }
    return false;
}

test "the help sheet floats over the workspace from one keymap" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 120, 80);
    defer canvas.deinit();

    _ = try application.handle_key(.{ .character = '?' });
    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "KEYBOARD HELP"));
    // Shared bindings come first, then the ones only this experience has.
    try std.testing.expect(canvas_has_text(&canvas, "command centre"));
    try std.testing.expect(canvas_has_text(&canvas, "reader / bookmarks"));
    try std.testing.expect(canvas_has_text(&canvas, "toggle favourite"));

    canvas.commit_frame();
    _ = try application.handle_key(.escape);
    try render(application, &canvas);
    try std.testing.expect(!canvas_has_text(&canvas, "KEYBOARD HELP"));
}

test "the status line advertises switching experiences everywhere" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 120, 40);
    defer canvas.deinit();

    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "ctrl-u"));
    try std.testing.expect(canvas_has_text(&canvas, "switch"));
}

test "the command centre opens on ctrl-p as well as colon" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 120, 40);
    defer canvas.deinit();

    _ = try application.handle_key(.{ .control = 'p' });
    try render(application, &canvas);
    try std.testing.expect(canvas_has_text(&canvas, "COMMAND CENTRE"));
}

test "adding a bookmark asks for the URL then its tags" {
    const application = try seeded_application();
    defer application.destroy(std.testing.allocator);

    _ = try application.handle_key(.{ .character = 'a' });
    try std.testing.expect(application.command.is_collecting());
    try std.testing.expectEqualStrings("Add bookmark", application.active_label());

    for ("https://example.com/one") |byte| {
        _ = try application.handle_key(.{ .character = byte });
    }
    _ = try application.handle_key(.enter);
    try std.testing.expect(application.command.is_collecting());

    for ("reading, zig") |byte| _ = try application.handle_key(.{ .character = byte });
    _ = try application.handle_key(.enter);

    try std.testing.expect(!application.command.is_open());
    const added = application.store.items[application.store.count - 1];
    try std.testing.expectEqualStrings("https://example.com/one", added.url.bytes());
    try std.testing.expectEqualStrings("reading, zig", added.tags.bytes());
}
