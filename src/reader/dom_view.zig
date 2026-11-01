const std = @import("std");
const markix = @import("markix");
const theme = @import("../theme.zig");
const tokens = @import("../ui/tokens.zig");
const node = @import("../ui/node.zig");
const pane = @import("../ui/pane.zig");
const header = @import("../ui/header.zig");
const status = @import("../ui/status.zig");
const help = @import("../ui/help.zig");
const ui_document = @import("../ui/document.zig");
const command_center = @import("../ui/command_center.zig");
const geometry = @import("../ui/geometry.zig");
const display_mod = @import("../ui/display.zig");
const command_policy = @import("../command.zig");
const keymap = @import("../keymap.zig");
const application_module = @import("application.zig");

const Tree = node.Tree;
const Index = node.Index;
const Rect = node.Rect;
const Color = node.Color;
const Focus = application_module.Focus;
const Display = display_mod.Display;
const Frame = display_mod.Frame;

pub const rows_max = pane.rows_max;
const hint = status.hint;
const reader_measure_max: i32 = 72;
const zen_label = " ZEN ";

const browse_hints = [_]status.Hint{
    hint.help,
    hint.focus,
    hint.move,
    hint.activate,
    hint.search,
    hint.command,
    hint.zen,
    hint.browser,
};

const zen_hints = [_]status.Hint{
    hint.move,
    hint.find,
    hint.activate,
    hint.command,
    .{ .key = "b", .label = "save" },
    .{ .key = "z", .label = "workspace" },
};

const document_hints = [_]status.Hint{
    hint.move,
    hint.browser,
    .{ .key = "b", .label = "save" },
    .{ .key = "m", .label = "read" },
    .{ .key = "v/esc", .label = "close" },
};

const help_hints = [_]status.Hint{hint.close};
const feed_form_hints = [_]status.Hint{ hint.save, hint.field, hint.cancel };
const confirm_hints = [_]status.Hint{
    .{ .key = "again", .label = "confirm" },
    .{ .key = "other", .label = "cancel" },
};

const workspace_tabs = [_]header.Segment{
    .{ .label = "Categories" },
    .{ .label = "Feeds" },
    .{ .label = "Articles" },
};

const zen_filters = [_]header.Segment{
    .{ .label = "All articles" },
    .{ .label = "Unread" },
};

const ContentKind = enum { workspace, document, zen };
const PaneKind = enum { categories, feeds, articles };

const Text = struct {
    bytes: [64]u8 = undefined,
    length: u8 = 0,

    fn set(self: *Text, comptime format: []const u8, args: anytype) []const u8 {
        const written = std.fmt.bufPrint(&self.bytes, format, args) catch self.bytes[0..0];
        self.length = @intCast(written.len);
        return self.bytes[0..self.length];
    }
};

const Pane = struct {
    kind: PaneKind,
    panel: pane.Panel,
    collapsed: bool,
};

pub const View = struct {
    panes: [3]Pane = undefined,
    pane_count: u8 = 0,
    zen: ?pane.Panel = null,
    document: ?pane.Panel = null,

    header_meta: Text = .{},
    categories_meta: Text = .{},
    feeds_meta: Text = .{},
    articles_meta: Text = .{},
    command_meta: Text = .{},
    document_meta: Text = .{},
    category_counts: [rows_max]Text = @splat(.{}),
    feed_counts: [rows_max]Text = @splat(.{}),
    hint_buffer: [16]status.Hint = undefined,
};

pub fn sync(view: *View, application: anytype, display: *Display) !void {
    const frame = &display.frame;
    const width = display.width();
    const height = display.height();
    std.debug.assert(width > 0 and height > 0);
    frame.begin();
    view.pane_count = 0;
    view.zen = null;
    view.document = null;
    const tree = &frame.base;
    const root = try node.box(tree, node.none, .{
        .width = node.fixed(width),
        .height = node.fixed(height),
        .background = theme.palette.background,
    });
    try header.build(tree, root, header_config(view, application), width);
    const content = try node.row(tree, root, .{ .gap = 1 });
    try status.build(tree, root, status_config(view, application), width);
    switch (content_kind(application)) {
        .workspace => try build_workspace(view, application, tree, content, width),
        .zen => view.zen = try pane.panel(
            tree,
            content,
            article_frame(view, application, true, "ZEN LIBRARY"),
        ),
        .document => view.document = try pane.panel(
            tree,
            content,
            document_frame(view, application),
        ),
    }
    node.resolve(tree, width, height);
    const band = node.rect_of(tree, content);
    std.debug.assert(band.width <= width);
    if (application.zen.active and application.zen.finding) {
        const finder = command_center.rect_for(band);
        application.set_article_viewport(command_center.rows_for(finder, true));
    }
    try fill_panes(view, application, tree);
    if (view.zen) |panel| try fill_zen(application, tree, panel);
    if (view.document) |panel| {
        try fill_document(application, frame, node.inner_of(tree, panel.body));
    }
    node.resolve(tree, width, height);
    try build_overlay(view, application, frame, band);
    register_geometry(view, application, tree);
}

fn content_kind(application: anytype) ContentKind {
    if (application.reader_only) return .document;
    if (application.zen.active) return .zen;
    return .workspace;
}

fn header_config(view: *View, application: anytype) header.Config {
    std.debug.assert(application.search.cursor <= application.search.value().len);
    std.debug.assert(tab_index(application.focus) < workspace_tabs.len);
    const meta = view.header_meta.set("{d} UNREAD", .{application.unread_count()});
    const body: header.Body = if (application.search_open) .{ .search = .{
        .prompt = search_prompt(application.search_scope),
        .placeholder = search_placeholder(application.search_scope),
        .value = application.search.value(),
        .cursor = application.search.cursor,
    } } else if (application.zen.active) .{ .scope = .{
        .badge = zen_label,
        .name = scope_name(application),
        .detail = "",
        .accent = theme.palette.accent_warm,
    } } else .{ .breadcrumb = .{
        .scope = scope_name(application),
        .tabs = &workspace_tabs,
        .selected = tab_index(application.focus),
        .accent = focus_accent(application.focus),
    } };
    return .{ .title = "READER", .meta = meta, .body = body };
}

fn status_config(view: *View, application: anytype) status.Config {
    const confirming = application.feed_mode == .remove_confirm or
        application.feed_mode == .prune_confirm;
    const own: []const status.Hint = if (application.help_open)
        &help_hints
    else if (application.search_open)
        &status.search_hints
    else if (application.command.is_open())
        &status.prompt_hints
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
    std.debug.assert(own.len > 0);
    std.debug.assert(own.len + status.trailer.len <= view.hint_buffer.len);
    return .{
        .message = application.message.bytes(),
        .hints = status.with_trailer(&view.hint_buffer, own),
        .warning = confirming,
    };
}

fn build_workspace(
    view: *View,
    application: anytype,
    tree: *Tree,
    content: Index,
    width: i32,
) !void {
    std.debug.assert(view.pane_count == 0);
    var kinds: [3]PaneKind = undefined;
    const count = workspace_panes(application, width, &kinds);
    std.debug.assert(count >= 1 and count <= 3);
    for (kinds[0..count], 0..) |kind, index| {
        const collapsed = application.is_collapsed(focus_of(kind));
        var frame = pane_frame(view, application, kind);
        frame.width = track(count, index, collapsed);
        view.panes[index] = .{
            .kind = kind,
            .panel = try pane.panel(tree, content, frame),
            .collapsed = collapsed,
        };
    }
    view.pane_count = count;
}

fn workspace_panes(application: anytype, width: i32, out: *[3]PaneKind) u8 {
    std.debug.assert(width > 0);
    if (width >= 120) {
        out.* = .{ .categories, .feeds, .articles };
        return 3;
    }
    if (width >= 80) {
        out[0] = if (application.focus == .categories) .categories else .feeds;
        out[1] = .articles;
        return 2;
    }
    std.debug.assert(width < 80);
    out[0] = switch (application.focus) {
        .categories => .categories,
        .feeds => .feeds,
        .articles, .reader => .articles,
    };
    return 1;
}

fn track(count: u8, index: usize, collapsed: bool) node.Sizing {
    if (collapsed) return node.fixed(3);
    if (count == 3) return switch (index) {
        0 => node.fixed(18),
        1 => node.fixed(30),
        else => node.grow,
    };
    if (count == 2 and index == 0) return node.fixed(28);
    return node.grow;
}

fn pane_frame(view: *View, application: anytype, kind: PaneKind) pane.Frame {
    std.debug.assert(application.filtered_feed_count <= application.feed_count);
    std.debug.assert(application.category_row_count() >= 2);
    return switch (kind) {
        .categories => titled(
            .filter,
            application.focus == .categories,
            "CATEGORIES",
            view.categories_meta.set("{d} VIEWS", .{application.category_row_count()}),
        ),
        .feeds => titled(.filter, application.focus == .feeds, "FEEDS", view.feeds_meta.set(
            "{d} SOURCES",
            .{application.filtered_feed_count},
        )),
        .articles => article_frame(view, application, application.focus == .articles, "ARTICLES"),
    };
}

fn titled(role: pane.Role, focused: bool, title: []const u8, meta: []const u8) pane.Frame {
    var frame = pane.frame_for(role, focused);
    frame.title = title;
    frame.meta = meta;
    return frame;
}

fn article_frame(view: *View, application: anytype, focused: bool, title: []const u8) pane.Frame {
    const count = application.filtered_article_count;
    const position = if (count == 0) 0 else application.article_cursor + 1;
    const meta = view.articles_meta.set("{d}/{d}", .{ position, count });
    return titled(.collection, focused, title, meta);
}

fn document_frame(view: *View, application: anytype) pane.Frame {
    const article = application.selected_article() orelse {
        return titled(.document, true, "READER", "NOTHING SELECTED");
    };
    const feed = &application.feeds[article.feed_index];
    const page_count = application.reader_page_count();
    const meta = if (page_count > 1) view.document_meta.set(
        "{s} | PAGE {d}/{d}",
        .{ feed.title.bytes(), application.reader_page + 1, page_count },
    ) else view.document_meta.set("{s}", .{feed.title.bytes()});
    return titled(.document, true, article.title.bytes(), meta);
}

fn fill_panes(view: *View, application: anytype, tree: *Tree) !void {
    std.debug.assert(view.pane_count <= 3);
    for (view.panes[0..view.pane_count]) |entry| {
        if (entry.collapsed) continue;
        const inner = node.inner_of(tree, entry.panel.body);
        std.debug.assert(inner.width >= 0 and inner.height >= 0);
        switch (entry.kind) {
            .categories => {
                application.set_category_viewport(@intCast(@max(inner.height, 0)));
                try fill_categories(view, application, tree, entry.panel.body, inner);
            },
            .feeds => {
                application.set_feed_viewport(@intCast(@max(inner.height, 0)));
                try fill_feeds(view, application, tree, entry.panel.body, inner);
            },
            .articles => {
                application.set_article_viewport(pane.capacity(inner, tokens.item_list_visual));
                const list = article_list(application, application.focus == .articles);
                try fill_articles(application, tree, entry.panel.body, inner, list);
            },
        }
    }
}

fn fill_zen(application: anytype, tree: *Tree, panel: pane.Panel) !void {
    const inner = node.inner_of(tree, panel.body);
    const rows = pane.capacity(inner, tokens.item_list_visual);
    if (!application.zen.finding) application.set_article_viewport(rows);
    try fill_articles(application, tree, panel.body, inner, article_list(application, true));
}

fn fill_categories(view: *View, application: anytype, tree: *Tree, body: Index, inner: Rect) !void {
    const count = application.category_row_count();
    std.debug.assert(count >= 2);
    std.debug.assert(inner.height >= 0);
    const list = pane.List{
        .role = .filter,
        .focused = application.focus == .categories,
        .empty_text = "No categories",
        .highlight = application.search_query_for(.categories),
        .visual = tokens.row_list_visual,
        .item_count = count,
        .scroll = application.category_scroll,
        .selected = application.category_cursor,
    };
    if (count == 0) return pane.empty(tree, body, list);
    const rows = pane.capacity(inner, list.visual);
    var row: u16 = 0;
    while (row < rows and list.scroll + row < count) : (row += 1) {
        const index = list.scroll + row;
        try pane.item(tree, body, list, inner.width, .{
            .title = category_name(application, index),
            .detail = view.category_counts[row].set("{d}", .{category_count(application, index)}),
            .marker = category_marker(application, index),
        }, index == list.selected);
    }
}

fn fill_feeds(view: *View, application: anytype, tree: *Tree, body: Index, inner: Rect) !void {
    std.debug.assert(application.filtered_feed_count <= application.feed_count);
    std.debug.assert(inner.height >= 0);
    const total = application.filtered_feed_count + 1;
    const list = pane.List{
        .role = .filter,
        .focused = application.focus == .feeds,
        .highlight = application.search_query_for(.feeds),
        .visual = tokens.row_list_visual,
        .item_count = total,
        .scroll = application.feed_scroll,
        .selected = application.feed_cursor,
    };
    const rows = pane.capacity(inner, list.visual);
    var row: u16 = 0;
    while (row < rows and list.scroll + row < total) : (row += 1) {
        const index = list.scroll + row;
        if (index == 0) {
            try pane.item(tree, body, list, inner.width, .{
                .title = "All feeds",
                .marker = if (application.active_feed == null) '*' else ' ',
            }, index == list.selected);
            continue;
        }
        const feed_index = application.filtered_feeds[index - 1];
        const feed = &application.feeds[feed_index];
        const unread = application.feed_unread_count(feed_index);
        try pane.item(tree, body, list, inner.width, .{
            .title = feed.title.bytes(),
            .detail = view.feed_counts[row].set("{d}", .{unread}),
            .marker = feed_marker(application, feed, feed_index),
        }, index == list.selected);
    }
}

fn article_list(application: anytype, focused: bool) pane.List {
    return .{
        .role = .collection,
        .focused = focused,
        .empty_text = empty_article_text(application),
        .highlight = safe_article_highlight(application),
        .visual = tokens.item_list_visual,
        .item_count = application.filtered_article_count,
        .scroll = application.article_scroll,
        .selected = application.article_cursor,
    };
}

fn fill_articles(
    application: anytype,
    tree: *Tree,
    body: Index,
    inner: Rect,
    list: pane.List,
) !void {
    std.debug.assert(list.scroll <= list.item_count);
    std.debug.assert(list.item_count <= application.filtered_article_count);
    if (list.item_count == 0) return pane.empty(tree, body, list);
    const rows = pane.capacity(inner, list.visual);
    var row: u16 = 0;
    while (row < rows and list.scroll + row < list.item_count) : (row += 1) {
        const index = list.scroll + row;
        const article = &application.articles[application.filtered_articles[index]];
        const feed = &application.feeds[article.feed_index];
        try pane.item(tree, body, list, inner.width, .{
            .title = article.title.bytes(),
            .detail = article.published.bytes(),
            .subtitle = feed.title.bytes(),
            .marker = if (article.read) ' ' else '*',
        }, index == list.selected);
    }
}

fn safe_article_highlight(application: anytype) []const u8 {
    const query = application.search_query_for(.articles);
    if (query.len == 0) return query;
    var index = application.article_scroll;
    while (index < application.filtered_article_count) : (index += 1) {
        const article = &application.articles[application.filtered_articles[index]];
        if (!pane.is_ascii(article.title.bytes())) return "";
    }
    return query;
}

fn fill_document(application: anytype, frame: *Frame, inner: Rect) !void {
    std.debug.assert(frame.page.len == 0);
    std.debug.assert(inner.width >= 0 and inner.height >= 0);
    const width = ui_document.measure_for(inner.width, reader_measure_max);
    const rows: u16 = @intCast(@min(@max(inner.height, 0), std.math.maxInt(u16)));
    if (application.selected_article() == null) {
        try ui_document.message(&frame.page, "No article selected", width);
        application.set_reader_metrics(0, rows);
    } else if (application.selected_document()) |parsed| {
        try ui_document.build(&frame.page, parsed, width, application.selected_image_path());
    } else {
        return;
    }
    node.resolve(&frame.page, width, markix.unbounded);
    const total = ui_document.height(&frame.page);
    if (application.selected_article() != null) {
        application.set_reader_metrics(@intCast(@min(total, std.math.maxInt(u16))), rows);
    }
    frame.page_options = .{
        .x = inner.x,
        .y = inner.y,
        .scroll = application.reader_scroll,
        .clip = inner,
        .base = theme.panel(),
    };
}

fn build_overlay(view: *View, application: anytype, frame: *Frame, band: Rect) !void {
    std.debug.assert(frame.overlay.len == 0);
    std.debug.assert(band.width >= 0);
    if (application.help_open) {
        const rect = help.rect_for(band);
        const sheet = help.layout_for(rect, keymap.row_count(&keymap.reader));
        if (sheet.rows == 0) return;
        try help.build(&frame.overlay, rect, sheet, &keymap.reader, "KEYBOARD HELP");
        return place_overlay(frame, rect);
    }
    if (application.command.is_open()) {
        const rect = command_center.rect_for(band);
        if (rect.width <= 0 or rect.height <= 0) return;
        try build_command(view, application, &frame.overlay, rect);
        return place_overlay(frame, rect);
    }
    if (application.zen.active and application.zen.finding) {
        const rect = command_center.rect_for(band);
        if (rect.width <= 0 or rect.height <= 0) return;
        try build_finder(application, &frame.overlay, rect);
        return place_overlay(frame, rect);
    }
}

fn place_overlay(frame: *Frame, rect: Rect) void {
    node.resolve(&frame.overlay, rect.width + 1, rect.height + 1);
    frame.overlay_options = .{ .x = rect.x, .y = rect.y, .base = theme.panel() };
}

fn build_command(view: *View, application: anytype, tree: *Tree, rect: Rect) !void {
    std.debug.assert(tree.len == 0);
    std.debug.assert(rect.width > 0 and rect.height > 0);
    const rows = command_center.rows_for(rect, false);
    application.command.set_viewport_rows(rows);
    if (application.active_argument()) |argument| {
        const label = application.active_label();
        const config = command_policy.argument_config(label, argument.placeholder);
        const surface = try command_center.surface(
            tree,
            rect,
            config,
            application.command.query(),
            application.command.input.cursor,
        );
        _ = surface;
        return;
    }
    const meta = view.command_meta.set("{d} RESULTS", .{application.command.count});
    const config = command_policy.deck_config(meta, application.command.query());
    const surface = try command_center.surface(
        tree,
        rect,
        config,
        application.command.query(),
        application.command.input.cursor,
    );
    try command_center.fill(
        tree,
        surface,
        rows,
        &application.command,
        application,
        config.empty_text,
    );
}

fn build_finder(application: anytype, tree: *Tree, rect: Rect) !void {
    std.debug.assert(tree.len == 0);
    std.debug.assert(rect.width > 0 and rect.height > 0);
    const config = command_policy.finder_config(
        "FIND ARTICLES",
        scope_name(application),
        "Fuzzy search titles, feeds, URLs, and summaries",
        .{
            .items = &zen_filters,
            .selected = if (application.scope == .unread) 1 else 0,
            .label = command_policy.finder.filter_label,
        },
    );
    const surface = try command_center.surface(
        tree,
        rect,
        config,
        application.search.value(),
        application.search.cursor,
    );
    var list = article_list(application, true);
    list.role = .command;
    list.highlight = application.search.value();
    try fill_articles(
        application,
        tree,
        surface.results,
        command_center.results_rect(rect, true),
        list,
    );
}

fn register_geometry(view: *View, application: anytype, tree: *const Tree) void {
    application.reset_pane_geometry();
    for (view.panes[0..view.pane_count]) |entry| {
        const row_height: u8 = switch (entry.kind) {
            .categories, .feeds => tokens.row_list_visual.row_height,
            .articles => tokens.item_list_visual.row_height,
        };
        register(application, tree, focus_of(entry.kind), entry.panel, row_height);
    }
    const item_height = tokens.item_list_visual.row_height;
    if (view.zen) |panel| register(application, tree, .articles, panel, item_height);
    if (view.document) |panel| register(application, tree, .reader, panel, 1);
}

fn register(
    application: anytype,
    tree: *const Tree,
    focus: Focus,
    panel: pane.Panel,
    row_height: u8,
) void {
    const list = geometry.Rect.from(node.inner_of(tree, panel.body));
    application.set_pane_bounds(focus, geometry.Rect.from(node.rect_of(tree, panel.outer)));
    application.set_pane_list(focus, list, row_height);
}

fn focus_of(kind: PaneKind) Focus {
    return switch (kind) {
        .categories => .categories,
        .feeds => .feeds,
        .articles => .articles,
    };
}

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
    const active = application.active_category.bytes();
    return if (std.ascii.eqlIgnoreCase(active, category.bytes())) '*' else ' ';
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

fn focus_accent(focus: Focus) Color {
    return switch (focus) {
        .categories, .feeds => theme.palette.accent_cool,
        .articles => theme.palette.accent_warm,
        .reader => theme.palette.accent,
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
