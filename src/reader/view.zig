const std = @import("std");
const terminal = @import("markix").terminal;
const layout = @import("markix").layout;
const theme = @import("markix").theme;
const document = @import("markix").document;
const application_module = @import("application.zig");
const limits = @import("limits.zig");

const Rect = layout.Rect;
const Surface = terminal.Surface;
const ListItem = terminal.widgets.ListItem;
const LayoutNodeIndex = layout.layout_tree.LayoutNodeIndex;
const pane_chrome = terminal.widgets.PanelChrome{
    .rail_width = 1,
    .rail_height = 3,
    .content_padding_left = 1,
    .content_padding_top = 1,
    .header_background = false,
    .title_attributes = .{ .bold = true },
};
const article_visual = terminal.widgets.ListVisual{
    .row_height = 2,
    .selected_marker = '>',
    .title_attributes = .{ .bold = true },
    .selected_attributes = .{ .bold = true },
    .subtitle_attributes = .{ .dim = true },
    .detail_width_divisor = 4,
};

pub fn render(application: anytype, canvas: *terminal.TerminalCanvas) !void {
    const surface = Surface{ .canvas = canvas };
    const bounds = surface.bounds();
    application.reset_pane_geometry();
    surface.fill(bounds, theme.background);
    if (application.help_open) {
        try draw_help(surface, bounds);
        return;
    }
    if (application.reader_only) {
        try draw_reader(application, surface, bounds);
        return;
    }
    var tree = layout.LayoutTree.init();
    const built = try build_layout(&tree, bounds, application);
    try layout.layout_tree.evaluate(&tree, bounds);
    try draw_header(application, surface, node_rect(&tree, built.header));
    var pane_index: u8 = 0;
    while (pane_index < built.pane_count) : (pane_index += 1) {
        const pane = built.panes[pane_index];
        const rect = node_rect(&tree, pane.node);
        // Bounds cover the whole pane so a collapsed section can still be
        // hit-tested and expanded by a click; the list area is set by the
        // draw function below.
        application.set_pane_bounds(pane.focus, rect);
        try draw_pane(application, surface, pane.focus, rect);
    }
    try draw_status(application, surface, node_rect(&tree, built.status));
}

const PaneSlot = struct {
    focus: application_module.Focus,
    node: LayoutNodeIndex,
};

const RssLayout = struct {
    header: LayoutNodeIndex,
    status: LayoutNodeIndex,
    panes: [4]PaneSlot = undefined,
    pane_count: u8 = 0,
};

fn build_layout(
    tree: *layout.LayoutTree,
    bounds: Rect,
    application: anytype,
) !RssLayout {
    const root = try tree.set_root(try layout.LayoutElement.flex(
        .column,
        0,
        &.{ .{ .cells = 2 }, .{ .fraction = 1 }, .{ .cells = 1 } },
    ));
    var result = RssLayout{
        .header = try tree.append_child(root, layout.LayoutElement.leaf()),
        .status = undefined,
    };
    const workspace = try append_workspace(tree, root, bounds.width, application);
    result.pane_count = workspace.pane_count;
    @memcpy(result.panes[0..workspace.pane_count], workspace.panes[0..workspace.pane_count]);
    result.status = try tree.append_child(root, layout.LayoutElement.leaf());
    return result;
}

const WorkspaceLayout = struct {
    panes: [4]PaneSlot = undefined,
    pane_count: u8,
};

fn append_workspace(
    tree: *layout.LayoutTree,
    root: LayoutNodeIndex,
    width: u16,
    application: anytype,
) !WorkspaceLayout {
    if (width >= 120) return append_wide_workspace(tree, root, application);
    if (width >= 80) return append_medium_workspace(tree, root, application);
    const workspace = try tree.append_child(root, layout.LayoutElement.leaf());
    return .{
        .panes = pane_slots(&.{application.focus}, &.{workspace}),
        .pane_count = 1,
    };
}

fn append_wide_workspace(
    tree: *layout.LayoutTree,
    root: LayoutNodeIndex,
    application: anytype,
) !WorkspaceLayout {
    const tracks = [_]layout.flex.Track{
        section_track(application, .categories, .{ .cells = 18 }),
        section_track(application, .feeds, .{ .cells = 30 }),
        section_track(application, .articles, .{ .fraction = 1 }),
    };
    const workspace = try tree.append_child(
        root,
        try layout.LayoutElement.flex(.row, 1, &tracks),
    );
    const focuses = [_]application_module.Focus{ .categories, .feeds, .articles };
    var nodes: [3]LayoutNodeIndex = undefined;
    append_leaves(tree, workspace, &nodes) catch |err| return err;
    return .{ .panes = pane_slots(&focuses, &nodes), .pane_count = 3 };
}

fn append_medium_workspace(
    tree: *layout.LayoutTree,
    root: LayoutNodeIndex,
    application: anytype,
) !WorkspaceLayout {
    const navigation: application_module.Focus = if (application.focus == .categories)
        .categories
    else
        .feeds;
    const tracks = [_]layout.flex.Track{
        section_track(application, navigation, .{ .cells = 28 }),
        section_track(application, .articles, .{ .fraction = 1 }),
    };
    const workspace = try tree.append_child(
        root,
        try layout.LayoutElement.flex(.row, 1, &tracks),
    );
    const focuses = [_]application_module.Focus{ navigation, .articles };
    var nodes: [2]LayoutNodeIndex = undefined;
    append_leaves(tree, workspace, &nodes) catch |err| return err;
    return .{ .panes = pane_slots(&focuses, &nodes), .pane_count = 2 };
}

fn append_leaves(
    tree: *layout.LayoutTree,
    parent: LayoutNodeIndex,
    nodes: []LayoutNodeIndex,
) !void {
    for (nodes) |*node| {
        node.* = try tree.append_child(parent, layout.LayoutElement.leaf());
    }
}

fn pane_slots(
    focuses: []const application_module.Focus,
    nodes: []const LayoutNodeIndex,
) [4]PaneSlot {
    std.debug.assert(focuses.len == nodes.len);
    std.debug.assert(focuses.len <= 4);
    var panes: [4]PaneSlot = undefined;
    for (focuses, nodes, 0..) |focus, node, index| {
        panes[index] = .{ .focus = focus, .node = node };
    }
    return panes;
}

fn node_rect(tree: *layout.LayoutTree, node: LayoutNodeIndex) Rect {
    return tree.get(node).?.element.rect;
}

const HelpLine = struct {
    key: []const u8,
    label: []const u8,
};

fn draw_help(surface: Surface, bounds: Rect) !void {
    if (bounds.width < 8 or bounds.height < 6) return;
    const width = @min(bounds.width -| 4, 74);
    const height = @min(bounds.height -| 2, 22);
    const rect = Rect.init(
        bounds.x + @divFloor(bounds.width - width, 2),
        bounds.y + @divFloor(bounds.height - height, 2),
        width,
        height,
    );
    const inner = try (terminal.widgets.Panel{
        .title = "KEYBOARD HELP",
        .meta = "? / ESC TO CLOSE",
        .style = theme.pane_style(theme.accent, true),
        .focused = true,
        .chrome = pane_chrome,
    }).draw(surface, rect);
    const lines = [_]HelpLine{
        .{ .key = "NAVIGATION", .label = "" },
        .{ .key = "h/l, Tab", .label = "move between panes" },
        .{ .key = "j/k, arrows", .label = "move selection or scroll reader" },
        .{ .key = "g/G, Ctrl-d/u", .label = "jump to edge or move a page" },
        .{ .key = "READING", .label = "" },
        .{ .key = "Enter", .label = "read the article here, full screen" },
        .{ .key = "v", .label = "toggle full-screen reader from any pane" },
        .{ .key = "Esc", .label = "close the reader; the article counts as read" },
        .{ .key = "o / i", .label = "open article / image in browser" },
        .{ .key = "m / b", .label = "toggle read / bookmark" },
        .{ .key = "FEEDS", .label = "" },
        .{ .key = "A", .label = "add a feed" },
        .{ .key = "d, d", .label = "remove the focused feed" },
        .{ .key = "r / R", .label = "refresh focused feed / every feed" },
        .{ .key = "P, P", .label = "prune feeds failed by the last full refresh" },
        .{ .key = "VIEW", .label = "" },
        .{ .key = "/", .label = "search the focused pane; Esc clears it" },
        .{ .key = "c", .label = "collapse the focused pane" },
        .{ .key = "a / u", .label = "show all / unread" },
        .{ .key = "? / q", .label = "toggle this help / quit" },
    };
    try draw_help_lines(surface, inner, &lines);
}

fn draw_help_lines(
    surface: Surface,
    rect: Rect,
    lines: []const HelpLine,
) !void {
    var row: u16 = 0;
    while (row < lines.len and row < rect.height) : (row += 1) {
        const line = lines[row];
        const heading = line.label.len == 0;
        try surface.styled_text_in(rect, row, line.key, .{
            .foreground = if (heading) theme.accent else theme.accent_warm,
            .background = theme.panel,
            .attributes = .{ .bold = true },
        });
        if (!heading and rect.width > 17) {
            try surface.styled_text(
                rect.x + 17,
                rect.y + row,
                line.label[0..@min(line.label.len, rect.width - 17)],
                text_style(theme.foreground, .{}),
            );
        }
    }
}

fn draw_header(application: anytype, surface: Surface, rect: Rect) !void {
    surface.fill(rect, theme.panel);
    _ = try terminal.widgets.Inline.draw(surface, rect, &.{
        .{
            .text = "RSS",
            .foreground = theme.accent_cool,
            .attributes = .{ .bold = true },
        },
    });
    var count_buffer: [48]u8 = undefined;
    const count = try std.fmt.bufPrint(
        &count_buffer,
        " {d} ARTICLES  {d} UNREAD ",
        .{ application.article_count, application.unread_count() },
    );
    if (count.len < rect.width) {
        try surface.text(
            rect.right() - @as(u16, @intCast(count.len)),
            rect.y,
            count,
            theme.muted,
            theme.panel_alt,
        );
    }
    const second = Rect.init(rect.x, rect.y +| 1, rect.width, 1);
    if (application.feed_mode == .add_url or application.feed_mode == .add_category) {
        try draw_feed_form(application, surface, second);
    } else if (application.search_open) {
        // The prompt names the pane being searched: the same keystroke means
        // three different things depending on where it was pressed.
        try terminal.widgets.draw_text_input(
            &application.search,
            surface,
            second,
            .{
                .prompt = search_prompt(application.search_scope),
                .placeholder = search_placeholder(application.search_scope),
                .style = theme.focused_field,
                .focused = true,
            },
        );
    } else {
        try draw_breadcrumb(application, surface, second);
    }
}

fn search_prompt(scope: application_module.Focus) []const u8 {
    return switch (scope) {
        .categories => " SEARCH CATEGORIES ",
        .feeds => " SEARCH FEEDS ",
        .articles, .reader => " SEARCH ARTICLES ",
    };
}

fn search_placeholder(scope: application_module.Focus) []const u8 {
    return switch (scope) {
        .categories => "category name",
        .feeds => "feed name, URL, or category",
        .articles, .reader => "article, feed, URL, or summary",
    };
}

fn draw_feed_form(application: anytype, surface: Surface, rect: Rect) !void {
    const url_active = application.feed_mode == .add_url;
    if (url_active) {
        try terminal.widgets.draw_text_input(
            &application.feed_url_input,
            surface,
            rect,
            .{
                .prompt = " FEED URL ",
                .placeholder = "https://example.com/feed.xml",
                .style = theme.focused_field,
                .focused = true,
            },
        );
    } else {
        try terminal.widgets.draw_text_input(
            &application.feed_category_input,
            surface,
            rect,
            .{
                .prompt = " CATEGORY ",
                .placeholder = "Unsorted",
                .style = theme.focused_field,
                .focused = true,
            },
        );
    }
}

fn draw_breadcrumb(application: anytype, surface: Surface, rect: Rect) !void {
    _ = try terminal.widgets.Inline.draw(surface, rect, &.{
        .{
            .text = " ",
            .foreground = theme.muted,
        },
        .{
            .text = scope_name(application),
            .foreground = theme.foreground_strong,
            .attributes = .{ .bold = true },
        },
        .{
            .text = "  /  ",
            .foreground = theme.line,
        },
        .{
            .text = active_feed_name(application),
            .foreground = theme.accent_warm,
        },
        .{
            .text = "  |  ",
            .foreground = theme.line,
        },
        .{
            .text = focus_name(application.focus),
            .foreground = focus_color(application.focus),
            .background = theme.line,
            .attributes = .{ .bold = true },
        },
    });
}

fn draw_pane(
    application: anytype,
    surface: Surface,
    focus: application_module.Focus,
    rect: Rect,
) !void {
    switch (focus) {
        .categories => try draw_categories(application, surface, rect),
        .feeds => try draw_feeds(application, surface, rect),
        .articles => try draw_articles(application, surface, rect),
        // The reader no longer has a side pane; this only serves the narrow
        // single-pane layout, which draws it fullscreen.
        .reader => try draw_reader(application, surface, rect),
    }
}

fn section_track(
    application: anytype,
    focus: application_module.Focus,
    expanded: layout.flex.Track,
) layout.flex.Track {
    return if (application.is_collapsed(focus)) .{ .cells = 3 } else expanded;
}

fn draw_categories(application: anytype, surface: Surface, rect: Rect) !void {
    if (application.is_collapsed(.categories)) {
        try draw_collapsed(surface, rect, "C", theme.accent_cool);
        return;
    }
    const focused = application.focus == .categories;
    const inner = try (terminal.widgets.Panel{
        .title = "CATEGORIES",
        .meta = "SCOPE",
        .style = theme.pane_style(theme.accent_cool, focused),
        .focused = focused,
        .chrome = pane_chrome,
    }).draw(surface, rect);
    application.set_pane_list(.categories, inner, 1);
    var items: [limits.category_count_max + 2]ListItem = undefined;
    var all_count_buffer: [12]u8 = undefined;
    var unread_count_buffer: [12]u8 = undefined;
    const all_count = std.fmt.bufPrint(
        &all_count_buffer,
        "{d}",
        .{application.article_count},
    ) catch "";
    const unread_count = std.fmt.bufPrint(
        &unread_count_buffer,
        "{d}",
        .{application.unread_count()},
    ) catch "";
    items[0] = .{
        .title = "All articles",
        .detail = all_count,
        .marker = if (application.scope == .all) '*' else ' ',
    };
    items[1] = .{
        .title = "Unread",
        .detail = unread_count,
        .marker = if (application.scope == .unread) '*' else ' ',
    };
    // Rows past the two anchors are whatever a search over this pane left.
    var index: u16 = 2;
    while (application.category_at(index)) |category| : (index += 1) {
        items[index] = .{
            .title = category.bytes(),
            .marker = if (application.scope == .category and
                std.ascii.eqlIgnoreCase(
                    application.active_category.bytes(),
                    category.bytes(),
                ))
                '*'
            else
                ' ',
        };
    }
    const list = terminal.widgets.List{
        .style = theme.pane_style(theme.accent_cool, focused),
        .highlight_query = application.search_query_for(.categories),
        .focused = focused,
    };
    application.set_category_viewport(list.capacity(inner.height));
    try list.draw(
        surface,
        inner,
        items[0..application.category_row_count()],
        application.category_cursor,
        application.category_scroll,
    );
}

fn draw_feeds(application: anytype, surface: Surface, rect: Rect) !void {
    if (application.is_collapsed(.feeds)) {
        try draw_collapsed(surface, rect, "F", theme.accent_cool);
        return;
    }
    const focused = application.focus == .feeds;
    var meta_buffer: [24]u8 = undefined;
    const meta = std.fmt.bufPrint(
        &meta_buffer,
        "{d} SOURCES",
        .{application.filtered_feed_count},
    ) catch "";
    const inner = try (terminal.widgets.Panel{
        .title = "FEEDS",
        .meta = meta,
        .style = theme.pane_style(theme.accent_cool, focused),
        .focused = focused,
        .chrome = pane_chrome,
    }).draw(surface, rect);
    application.set_pane_list(.feeds, inner, 1);
    const list = terminal.widgets.List{
        .style = theme.pane_style(theme.accent_cool, focused),
        .empty_text = if (application.search_query_for(.feeds).len > 0)
            "No feeds match this search"
        else
            "No feeds in this scope",
        .highlight_query = application.search_query_for(.feeds),
        .match_foreground = theme.command,
        .focused = focused,
    };
    application.set_feed_viewport(list.capacity(inner.height));
    const total = application.filtered_feed_count + 1;
    const start = @min(application.feed_scroll, total);
    const visible_count = @min(application.feed_viewport, total - start);
    var items: [terminal.limits.terminal_rows_max]ListItem = undefined;
    var details: [terminal.limits.terminal_rows_max][12]u8 = undefined;
    var visible: u16 = 0;
    while (visible < visible_count) : (visible += 1) {
        const absolute = start + visible;
        if (absolute == 0) {
            items[visible] = .{
                .title = "All feeds",
                .marker = if (application.active_feed == null) '*' else ' ',
            };
            continue;
        }
        const feed_index = application.filtered_feeds[absolute - 1];
        const feed = &application.feeds[feed_index];
        const unread = application.feed_unread_count(feed_index);
        const detail = std.fmt.bufPrint(&details[visible], "{d}", .{unread}) catch "";
        items[visible] = .{
            .title = feed.title.bytes(),
            .detail = detail,
            .marker = if (feed.failed)
                '!'
            else if (!feed.fetched)
                '.'
            else if (application.active_feed == feed_index)
                '*'
            else
                ' ',
        };
    }
    try list.draw(
        surface,
        inner,
        items[0..visible_count],
        application.feed_cursor -| start,
        0,
    );
}

fn draw_articles(application: anytype, surface: Surface, rect: Rect) !void {
    if (application.is_collapsed(.articles)) {
        try draw_collapsed(surface, rect, "A", theme.accent_warm);
        return;
    }
    const focused = application.focus == .articles;
    var meta_buffer: [24]u8 = undefined;
    const meta = std.fmt.bufPrint(
        &meta_buffer,
        "{d} SHOWN",
        .{application.filtered_article_count},
    ) catch "";
    const inner = try (terminal.widgets.Panel{
        .title = "ARTICLES",
        .meta = meta,
        .style = theme.pane_style(theme.accent_warm, focused),
        .focused = focused,
        .chrome = pane_chrome,
    }).draw(surface, rect);
    application.set_pane_list(.articles, inner, 2);
    try surface.selectable(inner, theme.selection_bookmarks);
    const list = terminal.widgets.List{
        .style = theme.pane_style(theme.accent_warm, focused),
        .empty_text = empty_article_text(application),
        .highlight_query = application.search_query_for(.articles),
        .match_foreground = theme.command,
        .focused = focused,
        .visual = article_visual,
    };
    application.set_article_viewport(list.capacity(inner.height));
    const start = @min(application.article_scroll, application.filtered_article_count);
    const remaining = application.filtered_article_count - start;
    const visible_count = @min(application.article_viewport, remaining);
    var items: [terminal.limits.terminal_rows_max]ListItem = undefined;
    var visible: u16 = 0;
    while (visible < visible_count) : (visible += 1) {
        const filtered_index = start + visible;
        const article = &application.articles[application.filtered_articles[filtered_index]];
        const feed = &application.feeds[article.feed_index];
        items[visible] = .{
            .title = article.title.bytes(),
            .detail = article.published.bytes(),
            .subtitle = feed.title.bytes(),
            .marker = if (article.read) ' ' else '*',
        };
    }
    try list.draw(
        surface,
        inner,
        items[0..visible_count],
        application.article_cursor -| start,
        0,
    );
}

fn draw_reader(application: anytype, surface: Surface, rect: Rect) !void {
    if (application.is_collapsed(.reader)) {
        try draw_collapsed(surface, rect, "R", theme.accent);
        return;
    }
    const focused = application.focus == .reader or application.reader_only;
    const inner = try (terminal.widgets.Panel{
        .title = "READER",
        .meta = if (application.reader_only) "FULLSCREEN | v/esc to close" else "DOCUMENT",
        .style = theme.pane_style(theme.accent, focused),
        .focused = focused,
        .chrome = pane_chrome,
    }).draw(surface, rect);
    application.set_pane_list(.reader, inner, 1);
    application.set_pane_bounds(.reader, inner);
    try surface.selectable(inner, theme.selection_preview);
    const article = application.selected_article() orelse {
        try surface.text_in(inner, 0, "No article selected", theme.muted, theme.panel);
        application.set_reader_metrics(0, inner.height);
        return;
    };
    if (focused) {
        _ = try application.request_selected_image();
    }
    const feed = &application.feeds[article.feed_index];
    var row: u16 = 0;
    if (row < inner.height) {
        try surface.styled_text_in(inner, row, article.title.bytes(), .{
            .foreground = theme.foreground_strong,
            .background = theme.panel,
            .attributes = .{ .bold = true },
        });
        row += 1;
    }
    if (row < inner.height) {
        _ = try terminal.widgets.Inline.draw(
            surface,
            Rect.init(inner.x, inner.y + row, inner.width, 1),
            &.{
                .{
                    .text = " FEED ",
                    .foreground = theme.inverse_foreground,
                    .background = theme.accent_cool,
                    .attributes = .{ .bold = true },
                },
                .{
                    .text = feed.title.bytes(),
                    .foreground = theme.muted,
                },
            },
        );
        row += 2;
    }
    if (row < inner.height) {
        const summary_rect = Rect.init(
            inner.x,
            inner.y + row,
            inner.width,
            inner.height - row,
        );
        const parsed = application.selected_document() orelse return;
        const image_path = if (terminal.widgets.Image.supported(surface))
            application.selected_image_path()
        else
            null;
        const render_image = image_path != null;
        const lines = reader_layout_lines(
            application,
            parsed,
            summary_rect.width,
            render_image,
        );
        application.set_reader_metrics(lines, summary_rect.height);
        try draw_document_window(
            surface,
            summary_rect,
            parsed,
            application.reader_scroll,
            image_path,
            &application.reader_block_lines,
        );
    }
}

fn draw_collapsed(
    surface: Surface,
    rect: Rect,
    label: []const u8,
    accent: layout.Color,
) !void {
    const inner = try (terminal.widgets.Panel{
        .style = theme.pane_style(accent, true),
        .focused = true,
        .chrome = .{
            .rail_width = 1,
            .rail_height = 3,
            .content_padding_left = 1,
            .content_padding_top = 1,
        },
    }).draw(surface, rect);
    try surface.styled_text_in(inner, 0, label, .{
        .foreground = accent,
        .background = theme.panel,
        .attributes = .{ .bold = true },
    });
}

fn draw_status(application: anytype, surface: Surface, rect: Rect) !void {
    const status = terminal.widgets.StatusLine{
        .style = theme.base,
        .visual = .{
            .message_attributes = .{ .bold = true },
            .key_attributes = .{ .bold = true },
            .label_attributes = .{ .dim = true },
            .hint_gap = 2,
        },
    };
    if (application.search_open) {
        try status.draw(surface, rect, "Search all loaded article text", &.{
            .{ .key = "enter", .label = "apply" },
            .{ .key = "esc", .label = "clear" },
        });
        return;
    }
    if (application.feed_mode == .add_url or application.feed_mode == .add_category) {
        try status.draw(surface, rect, application.message.bytes(), &.{
            .{ .key = "enter", .label = "next/save" },
            .{ .key = "tab", .label = "field" },
            .{ .key = "esc", .label = "cancel" },
        });
        return;
    }
    if (application.feed_mode == .remove_confirm) {
        try status.draw(surface, rect, application.message.bytes(), &.{
            .{ .key = "d", .label = "confirm" },
            .{ .key = "other", .label = "cancel" },
        });
        return;
    }
    if (application.feed_mode == .prune_confirm) {
        try status.draw(surface, rect, application.message.bytes(), &.{
            .{ .key = "P", .label = "confirm" },
            .{ .key = "other", .label = "cancel" },
        });
        return;
    }
    try status.draw(surface, rect, application.message.bytes(), &.{
        .{ .key = "?", .label = "keys" },
        .{ .key = "hjkl", .label = "move" },
        .{ .key = "enter", .label = "read" },
        .{ .key = "o", .label = "browser" },
        .{ .key = "b", .label = "save" },
        .{ .key = "q", .label = "quit" },
    });
}

fn scope_name(application: anytype) []const u8 {
    return switch (application.scope) {
        .all => "All articles",
        .unread => "Unread",
        .category => application.active_category.bytes(),
    };
}

fn active_feed_name(application: anytype) []const u8 {
    if (application.active_feed) |index| return application.feeds[index].title.bytes();
    return "All feeds";
}

fn focus_name(focus: application_module.Focus) []const u8 {
    return switch (focus) {
        .categories => "Categories",
        .feeds => "Feeds",
        .articles => "Articles",
        .reader => "Reader",
    };
}

fn focus_color(focus: application_module.Focus) layout.Color {
    return switch (focus) {
        .categories, .feeds => theme.accent_cool,
        .articles => theme.accent_warm,
        .reader => theme.accent,
    };
}

fn empty_article_text(application: anytype) []const u8 {
    if (application.search_query_for(.articles).len > 0) return "No search results";
    if (application.fetch_in_progress) return "Fetching articles...";
    if (application.scope == .unread) return "You are all caught up";
    return "No articles in this scope";
}

const WrappedLine = struct {
    bytes: []const u8,
    next: usize,
};

const BlockPresentation = struct {
    prefix: []const u8,
    style: terminal.TextStyle,
};

const RenderCursor = struct {
    logical_line: u16 = 0,
    drawn: u16 = 0,
    scroll: u16,
};

const reader_image_rows: u16 = 10;

fn draw_document_window(
    surface: Surface,
    rect: Rect,
    parsed: *const document.Document,
    scroll: u16,
    image_path: ?[]const u8,
    block_lines: *const [document.block_count_max]u16,
) !void {
    if (rect.width == 0 or rect.height == 0) return;
    var cursor = RenderCursor{ .scroll = scroll };
    var image_used = false;
    const images_supported = terminal.widgets.Image.supported(surface);
    if (image_path != null and images_supported and !document_has_image(parsed)) {
        try draw_image_block(surface, rect, image_path.?, &cursor);
        consume_blank(rect, &cursor);
        image_used = true;
    }
    var index: u8 = 0;
    while (index < parsed.count and cursor.drawn < rect.height) : (index += 1) {
        const block = &parsed.blocks[index];
        if (block.kind == .image and image_path != null and images_supported and !image_used) {
            try draw_image_block(surface, rect, image_path.?, &cursor);
            image_used = true;
            if (index + 1 < parsed.count) consume_blank(rect, &cursor);
            continue;
        }
        const presentation = block_presentation(block.kind);
        if (skip_hidden_block(
            block_lines[index],
            index + 1 < parsed.count,
            &cursor,
        )) continue;
        try draw_block_text(
            surface,
            rect,
            block.text.bytes(),
            presentation,
            &cursor,
        );
        if (!block.url.is_empty() and cursor.drawn < rect.height) {
            try draw_block_text(surface, rect, block.url.bytes(), link_presentation(), &cursor);
        }
        if (index + 1 < parsed.count) consume_blank(rect, &cursor);
    }
}

fn skip_hidden_block(
    block_lines: u16,
    separator: bool,
    cursor: *RenderCursor,
) bool {
    if (cursor.drawn != 0 or cursor.logical_line >= cursor.scroll) return false;
    var lines = block_lines;
    lines +|= @intFromBool(separator);
    if (cursor.logical_line +| lines > cursor.scroll) return false;
    cursor.logical_line +|= lines;
    return true;
}

fn draw_image_block(
    surface: Surface,
    rect: Rect,
    path: []const u8,
    cursor: *RenderCursor,
) !void {
    var visible_start: ?u16 = null;
    var visible_rows: u16 = 0;
    var crop_top_rows: u16 = 0;
    var row: u16 = 0;
    while (row < reader_image_rows) : (row += 1) {
        if (cursor.logical_line >= cursor.scroll and cursor.drawn < rect.height) {
            if (visible_start == null) visible_start = cursor.drawn;
            visible_rows += 1;
            cursor.drawn += 1;
        } else if (cursor.logical_line < cursor.scroll) {
            crop_top_rows += 1;
        }
        cursor.logical_line +|= 1;
    }
    if (visible_start) |start| {
        _ = try (terminal.widgets.Image{
            .path = path,
            .id = 1,
            .crop_top_rows = crop_top_rows,
            .full_height_rows = reader_image_rows,
        }).draw(
            surface,
            Rect.init(rect.x, rect.y + start, rect.width, visible_rows),
        );
    }
}

fn draw_block_text(
    surface: Surface,
    rect: Rect,
    text: []const u8,
    presentation: BlockPresentation,
    cursor: *RenderCursor,
) !void {
    const prefix_width: u16 = @min(@as(u16, @intCast(presentation.prefix.len)), rect.width -| 1);
    const text_width = @max(rect.width - prefix_width, 1);
    var offset: usize = 0;
    var first = true;
    while (offset < text.len and cursor.drawn < rect.height) {
        const line = next_wrapped_line(text, offset, text_width);
        if (cursor.logical_line >= cursor.scroll) {
            const y = rect.y + cursor.drawn;
            if (first and prefix_width > 0) {
                try surface.styled_text(
                    rect.x,
                    y,
                    presentation.prefix[0..prefix_width],
                    presentation.style,
                );
            }
            try surface.styled_text(
                rect.x + prefix_width,
                y,
                line.bytes,
                presentation.style,
            );
            cursor.drawn += 1;
        }
        cursor.logical_line +|= 1;
        offset = line.next;
        first = false;
    }
}

fn consume_blank(rect: Rect, cursor: *RenderCursor) void {
    if (cursor.logical_line >= cursor.scroll and cursor.drawn < rect.height) {
        cursor.drawn += 1;
    }
    cursor.logical_line +|= 1;
}

fn block_presentation(kind: document.Kind) BlockPresentation {
    return switch (kind) {
        .paragraph => .{
            .prefix = "",
            .style = text_style(theme.foreground, .{}),
        },
        .heading => .{
            .prefix = "# ",
            .style = text_style(theme.accent_warm, .{ .bold = true }),
        },
        .list_item => .{
            .prefix = "- ",
            .style = text_style(theme.foreground, .{}),
        },
        .quote => .{
            .prefix = "| ",
            .style = text_style(theme.accent_cool, .{ .dim = true }),
        },
        .code => .{
            .prefix = "  ",
            .style = .{ .foreground = theme.command, .background = theme.panel_alt },
        },
        .link => link_presentation(),
        .image => .{
            .prefix = "[IMG] ",
            .style = text_style(theme.accent, .{ .bold = true }),
        },
    };
}

fn link_presentation() BlockPresentation {
    return .{
        .prefix = "  ",
        .style = text_style(theme.accent_cool, .{ .underline = true }),
    };
}

fn text_style(
    foreground: layout.Color,
    attributes: terminal.TextAttributes,
) terminal.TextStyle {
    return .{
        .foreground = foreground,
        .background = theme.panel,
        .attributes = attributes,
    };
}

fn next_wrapped_line(text: []const u8, offset: usize, width: u16) WrappedLine {
    if (offset >= text.len or width == 0) return .{ .bytes = "", .next = text.len };
    const fitted = terminal.text_width.clip(text[offset..], width);
    if (fitted.len == 0) return .{ .bytes = text[offset .. offset + 1], .next = offset + 1 };
    const maximum = offset + fitted.len;
    const newline = std.mem.indexOfScalar(u8, text[offset..maximum], '\n');
    if (newline) |relative| {
        return .{ .bytes = text[offset .. offset + relative], .next = offset + relative + 1 };
    }
    if (maximum == text.len) return .{ .bytes = text[offset..maximum], .next = maximum };
    const candidate = text[offset..maximum];
    const space = std.mem.lastIndexOfScalar(u8, candidate, ' ');
    const end = if (space) |relative| if (relative > 0) offset + relative else maximum else maximum;
    var next = end;
    while (next < text.len and text[next] == ' ') next += 1;
    return .{ .bytes = text[offset..end], .next = next };
}

fn reader_layout_lines(
    application: anytype,
    parsed: *const document.Document,
    width: u16,
    render_image: bool,
) u16 {
    if (application.reader_layout_valid and
        application.reader_layout_width == width and
        application.reader_layout_image == render_image)
    {
        return application.reader_line_count;
    }
    const lines = calculate_document_layout(
        parsed,
        width,
        render_image,
        &application.reader_block_lines,
    );
    application.reader_layout_valid = true;
    application.reader_layout_width = width;
    application.reader_layout_image = render_image;
    return lines;
}

fn calculate_document_layout(
    parsed: *const document.Document,
    width: u16,
    render_image: bool,
    block_lines: *[document.block_count_max]u16,
) u16 {
    if (width == 0) return 0;
    var count: u16 = 0;
    var image_used = false;
    if (render_image and !document_has_image(parsed)) {
        count +|= reader_image_rows + 1;
        image_used = true;
    }
    var index: u8 = 0;
    while (index < parsed.count) : (index += 1) {
        const block = &parsed.blocks[index];
        const lines = block_line_count(block, width, render_image and !image_used);
        block_lines[index] = lines;
        if (block.kind == .image and render_image and !image_used) {
            image_used = true;
        }
        count +|= lines;
        if (index + 1 < parsed.count) count +|= 1;
    }
    return count;
}

fn block_line_count(
    block: *const document.Block,
    width: u16,
    render_image: bool,
) u16 {
    if (block.kind == .image and render_image) return reader_image_rows;
    const presentation = block_presentation(block.kind);
    var count = text_line_count(
        block.text.bytes(),
        width,
        presentation.prefix.len,
    );
    if (!block.url.is_empty()) {
        count +|= text_line_count(block.url.bytes(), width, 2);
    }
    return count;
}

fn document_has_image(parsed: *const document.Document) bool {
    var index: u8 = 0;
    while (index < parsed.count) : (index += 1) {
        if (parsed.blocks[index].kind == .image) return true;
    }
    return false;
}

fn text_line_count(text: []const u8, width: u16, prefix_length: usize) u16 {
    if (text.len == 0 or width == 0) return 0;
    const prefix: u16 = @min(@as(u16, @intCast(prefix_length)), width -| 1);
    const text_width = @max(width - prefix, 1);
    var count: u16 = 0;
    var offset: usize = 0;
    while (offset < text.len and count < std.math.maxInt(u16)) : (count += 1) {
        offset = next_wrapped_line(text, offset, text_width).next;
    }
    return count;
}
