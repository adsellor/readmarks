//! The reader's frame, built from the shared components. Same tree, same
//! panes, same command centre and help sheet as the bookmarker; only what goes
//! in them differs.

const std = @import("std");
const markix = @import("markix");
const layout = markix.layout;
const dom = markix.dom;
const widgets = markix.widgets;
const theme = @import("../theme.zig");
const ui = @import("../ui/tokens.zig");
const ui_pane = @import("../ui/pane.zig");
const ui_header = @import("../ui/header.zig");
const ui_status = @import("../ui/status.zig");
const ui_help = @import("../ui/help.zig");
const ui_document = @import("../ui/document.zig");
const command_center = @import("../ui/command_center.zig");
const command_policy = @import("../command.zig");
const keymap = @import("../keymap.zig");
const application_module = @import("application.zig");
const limits = @import("limits.zig");

const Rect = layout.Rect;
const LayoutElement = layout.LayoutElement;
const NodeIndex = dom.DomTree.NodeIndex;
const Track = layout.flex.Track;
const Focus = application_module.Focus;

pub const rows_max = ui_pane.rows_max;
const hint = ui_status.hint;

const image_rows: u16 = 10;

const reader_measure_max: u16 = 72;

const browse_hints = [_]widgets.StatusHint{
    hint.help,
    hint.focus,
    hint.move,
    hint.activate,
    hint.search,
    hint.command,
    hint.zen,
    hint.browser,
};

const zen_hints = [_]widgets.StatusHint{
    hint.move,
    hint.find,
    hint.activate,
    hint.command,
    .{ .key = "b", .label = "save" },
    .{ .key = "z", .label = "workspace" },
};

const document_hints = [_]widgets.StatusHint{
    hint.move,
    hint.browser,
    .{ .key = "b", .label = "save" },
    .{ .key = "m", .label = "read" },
    .{ .key = "v/esc", .label = "close" },
};

const help_hints = [_]widgets.StatusHint{hint.close};
const feed_form_hints = [_]widgets.StatusHint{ hint.save, hint.field, hint.cancel };
const confirm_hints = [_]widgets.StatusHint{
    .{ .key = "again", .label = "confirm" },
    .{ .key = "other", .label = "cancel" },
};

const workspace_tabs = [_]widgets.SegmentItem{
    .{ .label = "Categories" },
    .{ .label = "Feeds" },
    .{ .label = "Articles" },
};

const zen_label = " ZEN ";

const ContentKind = enum { workspace, document, zen };
const HeaderKind = enum { breadcrumb, search, scope };
const PaneKind = enum { categories, feeds, articles };

const Shape = struct {
    width: u16 = 0,
    height: u16 = 0,
    content: ContentKind = .workspace,
    header: HeaderKind = .breadcrumb,
    scope_length: u16 = 0,
    pane_count: u8 = 0,
    panes: [3]PaneKind = .{ .categories, .feeds, .articles },
    collapsed: [3]bool = @splat(false),
    category_rows: u16 = 0,
    feed_rows: u16 = 0,
    article_rows: u16 = 0,
    zen_rows: u16 = 0,
    document_rows: u16 = 0,
    document_width: u16 = 0,
    document_image: ui_document.ImageWindow = .{},
    command: bool = false,
    command_rows: u16 = 0,
    command_rect: Rect = Rect.init(0, 0, 0, 0),
    finder: bool = false,
    finder_rows: u16 = 0,
    finder_rect: Rect = Rect.init(0, 0, 0, 0),
    help: ui_help.Layout = .{},
    help_rect: Rect = Rect.init(0, 0, 0, 0),

    fn equals(self: Shape, other: Shape) bool {
        return std.meta.eql(self, other);
    }
};

const Text = struct {
    bytes: [64]u8 = undefined,
    length: u8 = 0,

    fn set(self: *Text, comptime format: []const u8, args: anytype) []const u8 {
        const written = std.fmt.bufPrint(&self.bytes, format, args) catch
            self.bytes[0..0];
        self.length = @intCast(written.len);
        return self.bytes[0..self.length];
    }
};

pub const Regions = struct {
    categories: ?Rect = null,
    feeds: ?Rect = null,
    articles: ?Rect = null,
    document: ?Rect = null,
    command_results: ?Rect = null,
    finder_results: ?Rect = null,
    finder_modal: ?Rect = null,
};

pub const View = struct {
    tree: dom.DomTree = dom.DomTree.init(),
    shape: Shape = .{},
    built: bool = false,

    root: NodeIndex = 0,
    content: NodeIndex = 0,
    workspace: NodeIndex = 0,
    status: NodeIndex = 0,

    header: ui_header.Slot = .{},
    categories: ui_pane.Slot = .{},
    feeds: ui_pane.Slot = .{},
    articles: ui_pane.Slot = .{},
    zen: ui_pane.Slot = .{},
    document: ui_document.Slot = .{},
    command: command_center.Slot = .{},
    finder: command_center.Slot = .{},
    help: ui_help.Slot = .{},
    regions: Regions = .{},

    last_painted: u16 = 0,
    stale: bool = false,
    surface_lost: bool = true,
    canvas_width: u16 = 0,
    canvas_height: u16 = 0,

    header_meta: Text = .{},
    header_count: Text = .{},
    categories_meta: Text = .{},
    feeds_meta: Text = .{},
    articles_meta: Text = .{},
    command_meta: Text = .{},
    document_meta: Text = .{},
    category_counts: [rows_max]Text = @splat(.{}),
    feed_counts: [rows_max]Text = @splat(.{}),
    hint_buffer: [16]widgets.StatusHint = undefined,
    lines: [ui_document.rows_max]ui_document.Line = undefined,
    filters: [3]widgets.SegmentItem = @splat(.{ .label = "" }),
    filter_count: u8 = 0,

    pub fn invalidate(self: *View) void {
        self.stale = true;
    }

    pub fn invalidate_surface(self: *View) void {
        self.surface_lost = true;
    }

    pub fn observe_canvas(self: *View, width: u16, height: u16) void {
        if (self.canvas_width == width and self.canvas_height == height) return;
        self.canvas_width = width;
        self.canvas_height = height;
        self.surface_lost = true;
    }

    fn node_rect(self: *View, index: NodeIndex) Rect {
        const node = self.tree.get(index) orelse return Rect.init(0, 0, 0, 0);
        return node.rect();
    }
};

pub fn sync(view: *View, application: anytype, bounds: Rect) !bool {
    const shape = measure(application, bounds);
    const rebuilt = !view.built or !view.shape.equals(shape);
    if (rebuilt) {
        try build(view, shape);
        view.shape = shape;
        view.built = true;
    }
    try view.tree.evaluate(bounds);
    capture_rects(view);
    apply_viewport(view, application);

    if (view.stale) {
        ui_pane.mark_rows_dirty(&view.tree, &view.categories);
        ui_pane.mark_rows_dirty(&view.tree, &view.feeds);
        ui_pane.mark_rows_dirty(&view.tree, &view.articles);
        ui_pane.mark_rows_dirty(&view.tree, &view.zen);
        view.stale = false;
    }
    const full = rebuilt or view.surface_lost;
    if (view.surface_lost) {
        view.tree.mark_all_dirty();
        view.surface_lost = false;
    }
    update(view, application);
    capture_regions(view);
    return full;
}

// Measuring.

fn measure(application: anytype, bounds: Rect) Shape {
    var shape = Shape{
        .width = bounds.width,
        .height = bounds.height,
        .content = content_kind(application),
        .header = header_kind(application),
        .scope_length = @intCast(scope_name(application).len),
    };
    const content = frame_rows(bounds)[1];
    switch (shape.content) {
        .workspace => measure_workspace(&shape, application, content),
        .zen => measure_zen(&shape, application, content),
        .document => measure_document(&shape, application, content),
    }
    if (application.command.is_open()) {
        shape.command = true;
        shape.command_rect = command_center.rect_for(content);
        shape.command_rows = command_center.rows_for(shape.command_rect, false);
    }
    if (application.help_open) {
        shape.help_rect = ui_help.rect_for(content);
        shape.help = ui_help.layout_for(
            shape.help_rect,
            keymap.row_count(&keymap.reader),
        );
    }
    return shape;
}

fn measure_workspace(shape: *Shape, application: anytype, content: Rect) void {
    shape.pane_count = workspace_panes(application, content.width, &shape.panes);
    for (shape.panes[0..shape.pane_count], 0..) |kind, index| {
        shape.collapsed[index] = application.is_collapsed(focus_of(kind));
    }
    var rects: [3]Rect = @splat(Rect.init(0, 0, 0, 0));
    var tracks: [3]Track = undefined;
    layout.flex.layout(
        content,
        .row,
        1,
        workspace_tracks(shape, &tracks),
        rects[0..shape.pane_count],
    ) catch return;
    for (shape.panes[0..shape.pane_count], 0..) |kind, index| {
        if (shape.collapsed[index]) continue;
        const rows = ui_pane.visible_rows(rects[index], row_height(kind));
        switch (kind) {
            .categories => shape.category_rows = rows,
            .feeds => shape.feed_rows = rows,
            .articles => shape.article_rows = rows,
        }
    }
}

fn measure_zen(shape: *Shape, application: anytype, content: Rect) void {
    shape.zen_rows = ui_pane.visible_rows(content, ui.item_list_visual.row_height);
    if (!application.zen.finding) return;
    const rect = command_center.rect_for(content);
    if (rect.width == 0 or rect.height == 0) return;
    shape.finder = true;
    shape.finder_rect = rect;
    shape.finder_rows = command_center.rows_for(rect, true);
}

fn measure_document(shape: *Shape, application: anytype, content: Rect) void {
    const inner = widgets.panel_content_rect(ui.pane_chrome, content);
    shape.document_rows = @min(inner.height, ui_document.rows_max);
    shape.document_width = ui_document.measure_for(inner.width, reader_measure_max);
    shape.document_image = image_window(application, inner.height);
}

/// How much of the article image is on screen. It moves the text rows under
/// it, so it belongs to the shape: scrolling through an image relays the pane,
/// scrolling through text does not.
fn image_window(application: anytype, height: u16) ui_document.ImageWindow {
    if (application.selected_image_path() == null) return .{};
    const scroll = application.reader_scroll;
    if (scroll >= image_rows) return .{ .rows = image_rows };
    const visible = @min(image_rows - scroll, height);
    return .{
        .rows = image_rows,
        .visible_rows = visible,
        .crop_top = scroll,
    };
}

fn frame_rows(bounds: Rect) [3]Rect {
    var tracks = [_]Track{ .{ .cells = 2 }, .{ .fraction = 1 }, .{ .cells = 1 } };
    var rows: [3]Rect = @splat(Rect.init(0, 0, 0, 0));
    layout.flex.layout(bounds, .column, 0, tracks[0..], rows[0..]) catch return rows;
    return rows;
}

fn content_band(shape: Shape) Rect {
    return frame_rows(Rect.init(0, 0, shape.width, shape.height))[1];
}

fn content_kind(application: anytype) ContentKind {
    if (application.reader_only) return .document;
    if (application.zen.active) return .zen;
    return .workspace;
}

fn header_kind(application: anytype) HeaderKind {
    if (application.search_open) return .search;
    if (application.zen.active) return .scope;
    return .breadcrumb;
}

fn workspace_panes(application: anytype, width: u16, out: *[3]PaneKind) u8 {
    if (width >= 120) {
        out.* = .{ .categories, .feeds, .articles };
        return 3;
    }
    if (width >= 80) {
        out[0] = if (application.focus == .categories) .categories else .feeds;
        out[1] = .articles;
        return 2;
    }
    out[0] = switch (application.focus) {
        .categories => .categories,
        .feeds => .feeds,
        .articles, .reader => .articles,
    };
    return 1;
}

fn workspace_tracks(shape: *const Shape, tracks: *[3]Track) []Track {
    const expanded = [3]Track{
        .{ .cells = 18 },
        .{ .cells = 30 },
        .{ .fraction = 1 },
    };
    var index: u8 = 0;
    while (index < shape.pane_count) : (index += 1) {
        if (shape.collapsed[index]) {
            tracks[index] = .{ .cells = 3 };
            continue;
        }
        tracks[index] = if (shape.pane_count == 3)
            expanded[index]
        else if (shape.pane_count == 2)
            (if (index == 0) Track{ .cells = 28 } else Track{ .fraction = 1 })
        else
            .{ .fraction = 1 };
    }
    return tracks[0..shape.pane_count];
}

fn row_height(kind: PaneKind) u8 {
    return switch (kind) {
        .categories, .feeds => ui.row_list_visual.row_height,
        .articles => ui.item_list_visual.row_height,
    };
}

fn visual_of(kind: PaneKind) widgets.ListVisual {
    return switch (kind) {
        .categories, .feeds => ui.row_list_visual,
        .articles => ui.item_list_visual,
    };
}

fn focus_of(kind: PaneKind) Focus {
    return switch (kind) {
        .categories => .categories,
        .feeds => .feeds,
        .articles => .articles,
    };
}

fn role_of(kind: PaneKind) ui_pane.Role {
    return switch (kind) {
        .categories, .feeds => .filter,
        .articles => .collection,
    };
}

// Building.

fn build(view: *View, shape: Shape) !void {
    view.tree.reset();
    view.header = .{};
    view.categories = .{};
    view.feeds = .{};
    view.articles = .{};
    view.zen = .{};
    view.document = .{};
    view.command = .{};
    view.finder = .{};
    view.help = .{};

    view.root = try view.tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = try LayoutElement.flex(.column, 0, &.{
            .{ .cells = 2 },
            .{ .fraction = 1 },
            .{ .cells = 1 },
        }),
    });
    view.header = try ui_header.mount(
        &view.tree,
        view.root,
        header_slot_kind(shape.header),
        shape.width,
        shape.scope_length,
        @intCast(zen_label.len),
    );
    view.content = try view.tree.append_child(view.root, .{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.free(),
    });
    view.status = try ui_status.mount(&view.tree, view.root);

    // The sheet covers the band rather than floating over it. A panel fills
    // its rect with colour but does not unregister the text already painted
    // underneath, so anything left below shows through wherever the sheet has
    // no text of its own.
    if (shape.help.rows > 0) {
        try build_help(view, shape);
        return;
    }
    switch (shape.content) {
        .workspace => try build_workspace(view, shape),
        .zen => try build_zen(view, shape),
        .document => try build_document(view, shape),
    }
    if (shape.command) try build_command(view, shape);
}

fn header_slot_kind(kind: HeaderKind) ui_header.Kind {
    return switch (kind) {
        .breadcrumb => .breadcrumb,
        .search => .search,
        .scope => .scope,
    };
}

fn build_workspace(view: *View, shape: Shape) !void {
    var tracks: [3]Track = undefined;
    var element = try LayoutElement.flex(.row, 1, workspace_tracks(&shape, &tracks));
    const band = content_band(shape);
    element.placement = .{ .x = 0, .y = 0, .width = band.width, .height = band.height };
    view.workspace = try view.tree.append_child(view.content, .{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = element,
    });
    for (shape.panes[0..shape.pane_count], 0..) |kind, index| {
        const rows: u16 = if (shape.collapsed[index]) 0 else switch (kind) {
            .categories => shape.category_rows,
            .feeds => shape.feed_rows,
            .articles => shape.article_rows,
        };
        const slot = try ui_pane.mount(
            &view.tree,
            view.workspace,
            rows,
            visual_of(kind),
        );
        switch (kind) {
            .categories => view.categories = slot,
            .feeds => view.feeds = slot,
            .articles => view.articles = slot,
        }
    }
}

fn build_zen(view: *View, shape: Shape) !void {
    const band = content_band(shape);
    view.zen = try ui_pane.mount_placed(
        &view.tree,
        view.content,
        Rect.init(0, 0, band.width, band.height),
        shape.zen_rows,
        ui.item_list_visual,
    );
    if (!shape.finder) return;
    const rect = shape.finder_rect;
    const inner = widgets.panel_content_rect(ui.overlay_chrome, rect);
    view.finder = try command_center.mount(&view.tree, view.content, .{
        .width = inner.width,
        .rows = shape.finder_rows,
        .filters = true,
        .placement = Rect.init(
            rect.x -| band.x,
            rect.y -| band.y,
            rect.width,
            rect.height,
        ),
    });
}

fn build_document(view: *View, shape: Shape) !void {
    const band = content_band(shape);
    view.document = try ui_document.mount(
        &view.tree,
        view.content,
        Rect.init(0, 0, band.width, band.height),
        shape.document_rows,
        shape.document_width,
        shape.document_image,
    );
}

fn build_command(view: *View, shape: Shape) !void {
    const band = content_band(shape);
    const rect = shape.command_rect;
    const inner = widgets.panel_content_rect(ui.overlay_chrome, rect);
    view.command = try command_center.mount(&view.tree, view.content, .{
        .width = inner.width,
        .rows = shape.command_rows,
        .placement = Rect.init(
            rect.x -| band.x,
            rect.y -| band.y,
            rect.width,
            rect.height,
        ),
    });
}

fn build_help(view: *View, shape: Shape) !void {
    const band = content_band(shape);
    const rect = shape.help_rect;
    view.help = try ui_help.mount(
        &view.tree,
        view.content,
        Rect.init(
            rect.x -| band.x,
            rect.y -| band.y,
            rect.width,
            rect.height,
        ),
        shape.help,
    );
}

// Updating.

fn update(view: *View, application: anytype) void {
    update_header(view, application);
    update_status(view, application);
    if (view.categories.mounted) update_categories(view, application);
    if (view.feeds.mounted) update_feeds(view, application);
    if (view.articles.mounted) update_articles(view, application);
    if (view.zen.mounted) update_zen(view, application);
    if (view.document.mounted) update_document(view, application);
    if (view.command.mounted) update_command(view, application);
    if (view.finder.mounted) update_finder(view, application);
    if (view.help.mounted) {
        ui_help.update(&view.tree, &view.help, &keymap.reader, "KEYBOARD HELP");
    }
}

fn update_header(view: *View, application: anytype) void {
    // Unread only. The article total is already the Categories pane's first
    // row, and the Articles pane carries its own position out of that total.
    const meta = view.header_meta.set("{d} UNREAD", .{application.unread_count()});
    const body: ui_header.Body = switch (view.shape.header) {
        .search => .{ .search = .{
            .prompt = search_prompt(application.search_scope),
            .placeholder = search_placeholder(application.search_scope),
            .value = application.search.value(),
            .cursor = application.search.cursor,
        } },
        // Zen's own pane meta carries the count, so the header names the
        // scope and stops there.
        .scope => .{ .scope = .{
            .badge = zen_label,
            .name = scope_name(application),
            .detail = "",
            .accent = theme.accent_warm,
        } },
        .breadcrumb => .{ .breadcrumb = .{
            .scope = scope_name(application),
            .tabs = &workspace_tabs,
            .selected = tab_index(application.focus),
            .accent = focus_accent(application.focus),
        } },
    };
    ui_header.update(&view.tree, &view.header, .{
        .title = "READER",
        .meta = meta,
        .body = body,
    });
}

fn update_status(view: *View, application: anytype) void {
    const confirming = application.feed_mode == .remove_confirm or
        application.feed_mode == .prune_confirm;
    const own: []const widgets.StatusHint = if (application.help_open)
        &help_hints
    else if (application.search_open)
        &ui_status.search_hints
    else if (application.command.is_open())
        &ui_status.prompt_hints
    else if (application.feed_mode == .add_url or application.feed_mode == .add_category)
        &feed_form_hints
    else if (confirming)
        &confirm_hints
    else if (application.zen.active)
        &zen_hints
    else if (application.reader_only)
        &document_hints
    else
        &browse_hints;
    // An overlay names itself in its own title bar, so the status line does not
    // repeat it; it keeps showing what the application last had to say.
    const message = application.message.bytes();
    ui_status.update(&view.tree, view.status, .{
        .message = message,
        .hints = ui_status.with_trailer(&view.hint_buffer, own),
        .warning = confirming,
    });
}

fn update_categories(view: *View, application: anytype) void {
    const focused = application.focus == .categories;
    const count = application.category_row_count();
    const config = ui_pane.Config{
        .role = .filter,
        .focused = focused,
        .title = "CATEGORIES",
        .meta = view.categories_meta.set("{d} VIEWS", .{count}),
        .empty_text = "No categories",
        .highlight = application.search_query_for(.categories),
        .visual = ui.row_list_visual,
        .item_count = count,
        .scroll = application.category_scroll,
        .selected = application.category_cursor,
    };
    ui_pane.update_frame(&view.tree, &view.categories, config);
    ui_pane.update_list(&view.tree, &view.categories, config);
    var row: u16 = 0;
    while (row < view.categories.row_count) : (row += 1) {
        const index = application.category_scroll + row;
        if (index >= count) {
            ui_pane.set_row(&view.tree, &view.categories, row, null, false);
            continue;
        }
        ui_pane.set_row(&view.tree, &view.categories, row, .{
            .title = category_name(application, index),
            .detail = view.category_counts[row].set(
                "{d}",
                .{category_count(application, index)},
            ),
            .marker = category_marker(application, index),
        }, index == application.category_cursor);
    }
}

fn update_feeds(view: *View, application: anytype) void {
    const focused = application.focus == .feeds;
    const total = application.filtered_feed_count + 1;
    const config = ui_pane.Config{
        .role = .filter,
        .focused = focused,
        .title = "FEEDS",
        .meta = view.feeds_meta.set("{d} SOURCES", .{application.filtered_feed_count}),
        .empty_text = if (application.search_query_for(.feeds).len > 0)
            "No feeds match this search"
        else
            "No feeds in this scope",
        .highlight = application.search_query_for(.feeds),
        .visual = ui.row_list_visual,
        .item_count = total,
        .scroll = application.feed_scroll,
        .selected = application.feed_cursor,
    };
    ui_pane.update_frame(&view.tree, &view.feeds, config);
    ui_pane.update_list(&view.tree, &view.feeds, config);
    var row: u16 = 0;
    while (row < view.feeds.row_count) : (row += 1) {
        const index = application.feed_scroll + row;
        if (index >= total) {
            ui_pane.set_row(&view.tree, &view.feeds, row, null, false);
            continue;
        }
        if (index == 0) {
            ui_pane.set_row(&view.tree, &view.feeds, row, .{
                .title = "All feeds",
                .marker = if (application.active_feed == null) '*' else ' ',
            }, index == application.feed_cursor);
            continue;
        }
        const feed_index = application.filtered_feeds[index - 1];
        const feed = &application.feeds[feed_index];
        ui_pane.set_row(&view.tree, &view.feeds, row, .{
            .title = feed.title.bytes(),
            .detail = view.feed_counts[row].set(
                "{d}",
                .{application.feed_unread_count(feed_index)},
            ),
            .marker = feed_marker(application, feed, feed_index),
        }, index == application.feed_cursor);
    }
}

fn update_articles(view: *View, application: anytype) void {
    const focused = application.focus == .articles;
    const config = article_config(view, application, focused, "ARTICLES");
    ui_pane.update_frame(&view.tree, &view.articles, config);
    ui_pane.update_list(&view.tree, &view.articles, config);
    fill_articles(view, application, &view.articles);
}

fn update_zen(view: *View, application: anytype) void {
    const config = article_config(view, application, true, "ZEN LIBRARY");
    ui_pane.update_frame(&view.tree, &view.zen, config);
    ui_pane.update_list(&view.tree, &view.zen, config);
    fill_articles(view, application, &view.zen);
}

fn safe_article_highlight(application: anytype) []const u8 {
    const query = application.search_query_for(.articles);
    if (query.len == 0) return query;
    var index = application.article_scroll;
    while (index < application.filtered_article_count) : (index += 1) {
        const article = &application.articles[application.filtered_articles[index]];
        if (!ui_pane.is_ascii(article.title.bytes())) return "";
    }
    return query;
}

fn article_config(
    view: *View,
    application: anytype,
    focused: bool,
    title: []const u8,
) ui_pane.Config {
    const position = if (application.filtered_article_count == 0)
        0
    else
        application.article_cursor + 1;
    return .{
        .role = .collection,
        .focused = focused,
        .title = title,
        .meta = view.articles_meta.set(
            "{d}/{d}",
            .{ position, application.filtered_article_count },
        ),
        .empty_text = empty_article_text(application),
        .highlight = safe_article_highlight(application),
        .visual = ui.item_list_visual,
        .item_count = application.filtered_article_count,
        .scroll = application.article_scroll,
        .selected = application.article_cursor,
    };
}

fn fill_articles(view: *View, application: anytype, slot: *const ui_pane.Slot) void {
    var row: u16 = 0;
    while (row < slot.row_count) : (row += 1) {
        const index = application.article_scroll + row;
        if (index >= application.filtered_article_count) {
            ui_pane.set_row(&view.tree, slot, row, null, false);
            continue;
        }
        const article = &application.articles[application.filtered_articles[index]];
        const feed = &application.feeds[article.feed_index];
        ui_pane.set_row(&view.tree, slot, row, .{
            .title = article.title.bytes(),
            .detail = article.published.bytes(),
            .subtitle = feed.title.bytes(),
            .marker = if (article.read) ' ' else '*',
        }, index == application.article_cursor);
    }
}

fn update_document(view: *View, application: anytype) void {
    const article = application.selected_article() orelse {
        ui_document.update_frame(&view.tree, &view.document, .{
            .title = "READER",
            .meta = "NOTHING SELECTED",
            .focused = true,
        });
        ui_document.set_message(&view.tree, &view.document, "No article selected");
        application.set_reader_metrics(0, view.document.row_count);
        return;
    };
    const feed = &application.feeds[article.feed_index];
    // A paged article says so, so a page ending mid-thought reads as a page
    // break rather than as the end of the article.
    const page_count = application.reader_page_count();
    ui_document.update_frame(&view.tree, &view.document, .{
        .title = article.title.bytes(),
        .meta = if (page_count > 1) view.document_meta.set(
            "{s} | PAGE {d}/{d}",
            .{ feed.title.bytes(), application.reader_page + 1, page_count },
        ) else view.document_meta.set("{s}", .{feed.title.bytes()}),
        .focused = true,
    });
    if (application.selected_image_path()) |path| {
        ui_document.update_image(
            &view.tree,
            &view.document,
            path,
            view.shape.document_image,
        );
    }
    const parsed = application.selected_document() orelse return;
    const width = view.shape.document_width;
    const total = ui_document.line_count(parsed, width, view.shape.document_image.rows);
    application.set_reader_metrics(total, view.document.row_count);
    const rows = @min(view.document.row_count, view.lines.len);
    const written = ui_document.window(
        parsed,
        width,
        application.reader_scroll,
        view.shape.document_image.rows,
        view.lines[0..rows],
    );
    var row: u16 = 0;
    while (row < view.document.row_count) : (row += 1) {
        ui_document.set_line(
            &view.tree,
            &view.document,
            row,
            if (row < written) view.lines[row] else null,
        );
    }
}

fn update_command(view: *View, application: anytype) void {
    if (application.active_argument()) |argument| {
        command_center.update_surface(
            &view.tree,
            &view.command,
            command_policy.argument_config(
                application.active_label(),
                argument.placeholder,
            ),
            application.command.query(),
            application.command.input.cursor,
        );
        ui_pane.update_list(&view.tree, &view.command.results, .{
            .role = .command,
            .focused = true,
            .empty_text = "",
            .visual = ui.command_list_visual,
        });
        ui_pane.clear_rows_from(&view.tree, &view.command.results, 0);
        return;
    }
    const meta = view.command_meta.set("{d} RESULTS", .{application.command.count});
    command_center.update(
        &view.tree,
        &view.command,
        &application.command,
        application,
        command_policy.deck_config(meta, application.command.query()),
    );
}

fn update_finder(view: *View, application: anytype) void {
    const selected = update_filters(view, application);
    command_center.update_surface(
        &view.tree,
        &view.finder,
        command_policy.finder_config(
            "FIND ARTICLES",
            scope_name(application),
            "Fuzzy search titles, feeds, URLs, and summaries",
            .{
                .items = view.filters[0..view.filter_count],
                .selected = selected,
                .label = command_policy.finder.filter_label,
            },
        ),
        application.search.value(),
        application.search.cursor,
    );
    const config = article_config(view, application, true, "");
    ui_pane.update_list(&view.tree, &view.finder.results, .{
        .role = .command,
        .focused = true,
        .empty_text = config.empty_text,
        .highlight = application.search.value(),
        .visual = ui.item_list_visual,
        .item_count = application.filtered_article_count,
        .scroll = application.article_scroll,
        .selected = application.article_cursor,
    });
    fill_articles(view, application, &view.finder.results);
}

/// The scopes zen mode offers as filters: everything, and unread.
fn update_filters(view: *View, application: anytype) u16 {
    view.filters[0] = .{ .label = "All articles" };
    view.filters[1] = .{ .label = "Unread" };
    view.filter_count = 2;
    return switch (application.scope) {
        .all => 0,
        .unread => 1,
        .category => 0,
    };
}

// Geometry.

fn apply_viewport(view: *View, application: anytype) void {
    if (view.categories.mounted) {
        application.set_category_viewport(view.categories.inner.height);
    }
    if (view.feeds.mounted) {
        application.set_feed_viewport(view.feeds.inner.height);
    }
    if (view.articles.mounted) {
        application.set_article_viewport(@divFloor(
            view.articles.inner.height,
            ui.item_list_visual.row_height,
        ));
    }
    if (view.zen.mounted) {
        application.set_article_viewport(@divFloor(
            view.zen.inner.height,
            ui.item_list_visual.row_height,
        ));
    }
    if (view.finder.mounted) {
        application.set_article_viewport(@divFloor(
            view.finder.results.inner.height,
            ui.item_list_visual.row_height,
        ));
    }
    if (view.command.mounted) {
        application.command.set_viewport_rows(@max(@divFloor(
            view.command.results.inner.height,
            ui.command_list_visual.row_height,
        ), 1));
    }
}

fn capture_rects(view: *View) void {
    ui_pane.capture_rects(&view.tree, &view.categories);
    ui_pane.capture_rects(&view.tree, &view.feeds);
    ui_pane.capture_rects(&view.tree, &view.articles);
    ui_pane.capture_rects(&view.tree, &view.zen);
    command_center.capture_rects(&view.tree, &view.command);
    command_center.capture_rects(&view.tree, &view.finder);
    if (view.document.mounted) {
        view.document.inner = view.node_rect(view.document.panel);
        const node = view.tree.get(view.document.panel);
        if (node) |value| view.document.inner = value.content_rect();
    }
}

fn capture_regions(view: *View) void {
    view.regions = .{};
    if (view.categories.mounted) view.regions.categories = view.categories.inner;
    if (view.feeds.mounted) view.regions.feeds = view.feeds.inner;
    if (view.articles.mounted) view.regions.articles = view.articles.inner;
    if (view.zen.mounted) view.regions.articles = view.zen.inner;
    if (view.document.mounted) view.regions.document = view.document.inner;
    if (view.command.mounted) view.regions.command_results = view.command.results.inner;
    if (view.finder.mounted) {
        view.regions.finder_modal = view.finder.rect;
        view.regions.finder_results = view.finder.results.inner;
    }
}

/// Hands the panes' geometry to the application so a pointer press can be
/// mapped back to a row.
pub fn register_geometry(view: *View, application: anytype) void {
    application.reset_pane_geometry();
    register_pane(view, application, .categories, &view.categories, 1);
    register_pane(view, application, .feeds, &view.feeds, 1);
    register_pane(
        view,
        application,
        .articles,
        if (view.zen.mounted) &view.zen else &view.articles,
        ui.item_list_visual.row_height,
    );
    if (view.document.mounted) {
        application.set_pane_bounds(.reader, view.document.inner);
        application.set_pane_list(.reader, view.document.inner, 1);
    }
}

fn register_pane(
    view: *View,
    application: anytype,
    focus: Focus,
    slot: *const ui_pane.Slot,
    height: u8,
) void {
    _ = view;
    if (!slot.mounted) return;
    application.set_pane_bounds(focus, slot.rect);
    application.set_pane_list(focus, slot.inner, height);
}

// Content the props read from.

fn scope_name(application: anytype) []const u8 {
    return switch (application.scope) {
        .all => "All articles",
        .unread => "Unread",
        .category => application.active_category.bytes(),
    };
}

fn category_name(application: anytype, index: u16) []const u8 {
    if (index == 0) return "All articles";
    if (index == 1) return "Unread";
    const category = application.category_at(index) orelse return "";
    return category.bytes();
}

fn category_count(application: anytype, index: u16) u16 {
    if (index == 0) return application.article_count;
    if (index == 1) return application.unread_count();
    return 0;
}

fn category_marker(application: anytype, index: u16) u8 {
    if (index == 0) return if (application.scope == .all) '*' else ' ';
    if (index == 1) return if (application.scope == .unread) '*' else ' ';
    const category = application.category_at(index) orelse return ' ';
    if (application.scope != .category) return ' ';
    return if (std.ascii.eqlIgnoreCase(
        application.active_category.bytes(),
        category.bytes(),
    )) '*' else ' ';
}

fn feed_marker(application: anytype, feed: anytype, feed_index: u16) u8 {
    if (feed.failed) return '!';
    if (!feed.fetched) return '.';
    return if (application.active_feed == feed_index) '*' else ' ';
}

fn empty_article_text(application: anytype) []const u8 {
    if (application.search_query_for(.articles).len > 0) return "No search results";
    if (application.fetch_in_progress) return "Fetching articles...";
    if (application.scope == .unread) return "You are all caught up";
    return "No articles in this scope";
}

fn tab_index(focus: Focus) u16 {
    return switch (focus) {
        .categories => 0,
        .feeds => 1,
        .articles, .reader => 2,
    };
}

fn focus_accent(focus: Focus) markix.Color {
    return switch (focus) {
        .categories, .feeds => theme.accent_cool,
        .articles => theme.accent_warm,
        .reader => theme.accent,
    };
}

fn search_prompt(scope: Focus) []const u8 {
    return switch (scope) {
        .categories => " SEARCH CATEGORIES ",
        .feeds => " SEARCH FEEDS ",
        .articles, .reader => " SEARCH ARTICLES ",
    };
}

fn search_placeholder(scope: Focus) []const u8 {
    return switch (scope) {
        .categories => "category name",
        .feeds => "feed name, URL, or category",
        .articles, .reader => "article, feed, URL, or summary",
    };
}
