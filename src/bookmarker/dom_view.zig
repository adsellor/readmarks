const std = @import("std");
const markix = @import("markix");
const theme = @import("../theme.zig");
const tokens = @import("../ui/tokens.zig");
const node = @import("../ui/node.zig");
const pane = @import("../ui/pane.zig");
const header = @import("../ui/header.zig");
const status = @import("../ui/status.zig");
const help = @import("../ui/help.zig");
const field = @import("../ui/field.zig");
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
const Style = node.Style;
const Display = display_mod.Display;
const Frame = display_mod.Frame;
const BrowserFocus = application_module.BrowserFocus;
const Field = application_module.Field;
const MouseListRegion = application_module.MouseListRegion;

pub const rows_max = pane.rows_max;
pub const bookmark_list_visual = tokens.item_list_visual;
const scope_list_visual = tokens.row_list_visual;
const hint = status.hint;

const scope_width: i32 = 20;
const form_width_max: i32 = 78;
const form_height_max: i32 = 12;
const form_label_width: i32 = 8;
const progress_width: i32 = 12;

const browse_hints = [_]status.Hint{
    hint.help,
    hint.focus,
    hint.move,
    hint.activate,
    hint.search,
    hint.command,
    hint.zen,
    hint.add,
};

const help_hints = [_]status.Hint{hint.close};
const add_hints = [_]status.Hint{ hint.field, hint.save, hint.cancel };

const finder_hints = [_]status.Hint{
    hint.fuzzy,
    hint.category,
    hint.step,
    hint.apply,
    hint.clear,
};

const focus_hints = [_]status.Hint{
    hint.move,
    hint.find,
    hint.activate,
    hint.command,
    .{ .key = "f", .label = "favourite" },
    .{ .key = "z", .label = "workspace" },
};

const form_fields = [_]header.Segment{
    .{ .label = "Title" },
    .{ .label = "URL" },
    .{ .label = "Tags" },
    .{ .label = "Note" },
};

const form_order = [_]Field{ .title, .url, .tags, .notes };
const form_labels = [_][]const u8{ "TITLE", "URL", "TAGS", "NOTE" };

const form_placeholders = [_][]const u8{
    "Page title",
    "https://",
    "design, systems, reading",
    "Why this is worth keeping",
};

const browser_tabs = [_]header.Segment{
    .{ .label = "Browse" },
    .{ .label = "Bookmarks" },
    .{ .label = "Preview" },
};

const link_label = " LINK ";
const tags_label = " TAGS ";
const note_label = " NOTE ";
const summary_label = "SUMMARY";
const focus_label = " ZEN ";

const ContentKind = enum { workspace, add, focus };
const PaneKind = enum { scopes, bookmarks, preview };

const Text = struct {
    bytes: [48]u8 = undefined,
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
};

const Preview = struct {
    head: Index = node.none,
    area: Index = node.none,
};

pub const View = struct {
    panes: [3]Pane = undefined,
    pane_count: u8 = 0,
    focus: ?pane.Panel = null,
    form: ?pane.Panel = null,
    preview: Preview = .{},
    fields: [form_fields.len]Index = @splat(node.none),
    field_count: u8 = 0,

    header_meta: Text = .{},
    header_count: Text = .{},
    scopes_meta: Text = .{},
    bookmarks_meta: Text = .{},
    focus_meta: Text = .{},
    command_meta: Text = .{},
    progress: Text = .{},
    scope_counts: [rows_max]Text = @splat(.{}),
    hint_buffer: [16]status.Hint = undefined,

    categories: [3]header.Segment = @splat(.{ .label = "" }),
    category_scopes: [3]u16 = @splat(0),
    category_count: u8 = 0,

    fn reset(self: *View) void {
        self.pane_count = 0;
        self.focus = null;
        self.form = null;
        self.preview = .{};
        self.field_count = 0;
        self.category_count = 0;
    }
};

pub fn sync(view: *View, application: anytype, display: *Display) !void {
    const frame = &display.frame;
    const width = display.width();
    const height = display.height();
    std.debug.assert(width > 0 and height > 0);
    frame.begin();
    view.reset();
    application.mouse_layout = .{};
    const tree = &frame.base;
    const kind = content_kind(application);
    const root = try node.box(tree, node.none, .{
        .width = node.fixed(width),
        .height = node.fixed(height),
        .background = theme.palette.background,
    });
    try header.build(tree, root, header_config(view, application), width);
    const content = try node.row(tree, root, .{
        .gap = 1,
        .alignment = if (kind == .add) .{ .x = .center, .y = .center } else .{},
    });
    try status.build(tree, root, status_config(view, application), width);
    switch (kind) {
        .workspace => try build_workspace(view, application, tree, content, width),
        .focus => view.focus = try pane.panel(tree, content, titled(
            .collection,
            true,
            "ZEN LIBRARY",
            position_meta(&view.focus_meta, application),
        )),
        .add => view.form = try pane.panel(tree, content, form_frame()),
    }
    node.resolve(tree, width, height);
    const band = node.rect_of(tree, content);
    std.debug.assert(band.width <= width);
    if (finder_open(application)) {
        application.set_viewport_rows(command_center.rows_for(command_center.rect_for(band), true));
    }
    try fill_panes(view, application, frame);
    if (view.focus) |panel| try fill_focus(application, tree, panel);
    if (view.form) |panel| try fill_form(view, application, tree, panel);
    node.resolve(tree, width, height);
    try build_overlay(view, application, frame, band);
    register_geometry(view, application, tree);
}

fn content_kind(application: anytype) ContentKind {
    return switch (application.mode) {
        .add => .add,
        .focus => .focus,
        else => .workspace,
    };
}

fn finder_open(application: anytype) bool {
    return application.mode == .focus and application.focus_search_open;
}

fn header_config(view: *View, application: anytype) header.Config {
    std.debug.assert(application.filtered_count <= application.store.count);
    std.debug.assert(application.search.cursor <= application.search.value().len);
    const meta = view.header_meta.set(
        "{d} SAVED  {d} SHOWN",
        .{ application.store.count, application.filtered_count },
    );
    const body: header.Body = switch (application.mode) {
        .search => .{ .search = .{
            .prompt = " SEARCH ",
            .placeholder = "title, URL, tag, note, or page text",
            .value = application.search.value(),
            .cursor = application.search.cursor,
        } },
        .focus => .{ .scope = .{
            .badge = focus_label,
            .name = scope_name(application),
            .detail = view.header_count.set("/  {d} MATCHES", .{application.filtered_count}),
            .accent = theme.palette.accent_warm,
        } },
        else => .{ .breadcrumb = .{
            .scope = scope_name(application),
            .tabs = &browser_tabs,
            .selected = focus_index(application.browser_focus),
            .accent = focus_accent(application.browser_focus),
        } },
    };
    return .{ .title = "BOOKMARKS", .meta = meta, .body = body };
}

fn status_config(view: *View, application: anytype) status.Config {
    const own: []const status.Hint = if (application.help_open)
        &help_hints
    else switch (application.mode) {
        .browse, .confirm_delete => &browse_hints,
        .search => &status.search_hints,
        .add => &add_hints,
        .command => &status.prompt_hints,
        .focus => if (application.focus_search_open) &finder_hints else &focus_hints,
    };
    std.debug.assert(own.len > 0);
    std.debug.assert(own.len + status.trailer.len <= view.hint_buffer.len);
    return .{
        .message = application.message.bytes(),
        .hints = status.with_trailer(&view.hint_buffer, own),
        .warning = application.mode == .confirm_delete,
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
        var frame = pane_frame(view, application, kind);
        frame.width = track(width, count, index);
        const panel = try pane.panel(tree, content, frame);
        view.panes[index] = .{ .kind = kind, .panel = panel };
        if (kind == .preview) try build_preview(view, application, tree, panel.body);
    }
    view.pane_count = count;
}

fn workspace_panes(application: anytype, width: i32, out: *[3]PaneKind) u8 {
    std.debug.assert(width > 0);
    if (width >= 110) {
        out.* = .{ .scopes, .bookmarks, .preview };
        return 3;
    }
    if (width >= 76) {
        out[0] = if (application.browser_focus == .scopes) .scopes else .bookmarks;
        out[1] = .preview;
        return 2;
    }
    std.debug.assert(width < 76);
    out[0] = switch (application.browser_focus) {
        .scopes => .scopes,
        .bookmarks => if (application.narrow_preview) .preview else .bookmarks,
        .preview => .preview,
    };
    return 1;
}

fn track(width: i32, count: u8, index: usize) node.Sizing {
    std.debug.assert(index < count);
    if (index + 1 == count) return node.grow;
    if (count == 3 and index == 0) return node.fixed(scope_width);
    const gaps: i32 = count - 1;
    const shared = if (count == 3) width - scope_width - gaps else width - gaps;
    return node.fixed(@divFloor(@max(shared, 0) * 2, 5));
}

fn pane_frame(view: *View, application: anytype, kind: PaneKind) pane.Frame {
    std.debug.assert(application.filtered_count <= application.store.count);
    std.debug.assert(scope_item_count(application) >= 2);
    const focus = application.browser_focus;
    return switch (kind) {
        .scopes => titled(.filter, focus == .scopes, "BROWSE", view.scopes_meta.set(
            "{d} VIEWS",
            .{scope_item_count(application)},
        )),
        .bookmarks => titled(
            .collection,
            focus == .bookmarks,
            "BOOKMARKS",
            position_meta(&view.bookmarks_meta, application),
        ),
        .preview => titled(.document, focus == .preview, "PREVIEW", ""),
    };
}

fn titled(role: pane.Role, focused: bool, title: []const u8, meta: []const u8) pane.Frame {
    var frame = pane.frame_for(role, focused);
    frame.title = title;
    frame.meta = meta;
    return frame;
}

fn position_meta(text: *Text, application: anytype) []const u8 {
    const count = application.filtered_count;
    const position = if (count == 0) 0 else application.selected + 1;
    return text.set("{d}/{d}", .{ position, count });
}

fn form_frame() pane.Frame {
    var frame = titled(.collection, true, "NEW BOOKMARK", "");
    frame.chrome = tokens.form_chrome;
    frame.width = .{ .grow = .{ .max = form_width_max } };
    frame.height = .{ .grow = .{ .max = form_height_max } };
    return frame;
}

fn build_preview(view: *View, application: anytype, tree: *Tree, body: Index) !void {
    std.debug.assert(view.preview.area == node.none);
    const palette = theme.palette;
    const bookmark = application.selected_bookmark() orelse {
        const strip = try node.line(tree, body, .{});
        const chip = theme.chip(palette.muted, palette.panel_alt);
        return node.run(tree, strip, " NO SELECTION ", chip);
    };
    _ = try node.label(tree, body, bookmark.title.bytes(), .{
        .style = theme.ink(palette.foreground_strong),
    });
    try labelled(tree, body, link_label, palette.accent_cool, bookmark.url.bytes(), .{
        .foreground = palette.muted,
        .underline = true,
    });
    if (!bookmark.tags.is_empty()) {
        const style = theme.strong(palette.accent_warm);
        try labelled(tree, body, tags_label, palette.accent_warm, bookmark.tags.bytes(), style);
    }
    if (!bookmark.notes.is_empty()) {
        const style = theme.ink(palette.foreground);
        try labelled(tree, body, note_label, palette.accent, bookmark.notes.bytes(), style);
    }
    _ = try node.spacer(tree, body, node.grow, node.fixed(1));
    if (!bookmark.description.is_empty()) {
        try section(tree, body, summary_label);
        _ = try node.paragraph(tree, body, bookmark.description.bytes(), .{
            .style = theme.ink(palette.foreground),
        });
        _ = try node.spacer(tree, body, node.grow, node.fixed(1));
    }
    view.preview.head = try node.row(tree, body, .{ .height = node.fixed(1) });
    const heading = if (bookmark.preview.is_empty()) "NOT FETCHED" else "CONTENT";
    try section(tree, view.preview.head, heading);
    view.preview.area = try node.box(tree, body, .{});
    std.debug.assert(view.preview.area > view.preview.head);
}

fn labelled(
    tree: *Tree,
    body: Index,
    name: []const u8,
    color: Color,
    value: []const u8,
    style: Style,
) !void {
    const strip = try node.line(tree, body, .{});
    try node.run(tree, strip, name, theme.chip(theme.palette.inverse_foreground, color));
    try node.run(tree, strip, " ", .{});
    try node.run(tree, strip, value, style);
}

fn section(tree: *Tree, parent: Index, name: []const u8) !void {
    const strip = try node.line(tree, parent, .{});
    try node.run(tree, strip, name, theme.chip(theme.palette.muted, theme.palette.panel_alt));
}

fn fill_panes(view: *View, application: anytype, frame: *Frame) !void {
    const tree = &frame.base;
    std.debug.assert(view.pane_count <= 3);
    for (view.panes[0..view.pane_count]) |entry| {
        const inner = node.inner_of(tree, entry.panel.body);
        std.debug.assert(inner.width >= 0 and inner.height >= 0);
        switch (entry.kind) {
            .scopes => {
                application.set_scope_viewport_rows(pane.capacity(inner, scope_list_visual));
                try fill_scopes(view, application, tree, entry.panel.body, inner);
            },
            .bookmarks => {
                application.set_viewport_rows(pane.capacity(inner, bookmark_list_visual));
                const focused = application.browser_focus == .bookmarks;
                const list = bookmark_list(application, focused, "");
                try fill_bookmarks(application, tree, entry.panel.body, inner, list);
            },
            .preview => try fill_preview(view, application, frame),
        }
    }
}

fn fill_scopes(view: *View, application: anytype, tree: *Tree, body: Index, inner: Rect) !void {
    const count = scope_item_count(application);
    std.debug.assert(count >= 2);
    const list = pane.List{
        .role = .filter,
        .focused = application.browser_focus == .scopes,
        .empty_text = "No views",
        .visual = scope_list_visual,
        .item_count = count,
        .scroll = application.scope_scroll,
        .selected = application.scope_cursor,
    };
    const rows = pane.capacity(inner, list.visual);
    std.debug.assert(rows <= rows_max);
    var row: u16 = 0;
    while (row < rows and list.scroll + row < count) : (row += 1) {
        const index = list.scroll + row;
        const matches = scope_bookmark_count(application, index);
        try pane.item(tree, body, list, inner.width, .{
            .title = scope_item_name(application, index),
            .detail = view.scope_counts[row].set("{d}", .{matches}),
            .marker = if (index < 2) ' ' else '#',
        }, index == list.selected);
    }
}

fn bookmark_list(application: anytype, focused: bool, highlight: []const u8) pane.List {
    return .{
        .role = .collection,
        .focused = focused,
        .empty_text = empty_bookmark_text(application),
        .highlight = safe_highlight(application, highlight),
        .visual = bookmark_list_visual,
        .item_count = application.filtered_count,
        .scroll = application.scroll,
        .selected = application.selected,
    };
}

fn fill_bookmarks(
    application: anytype,
    tree: *Tree,
    body: Index,
    inner: Rect,
    list: pane.List,
) !void {
    std.debug.assert(list.item_count <= application.filtered_count);
    std.debug.assert(list.visual.row_height > 0);
    if (list.item_count == 0) return pane.empty(tree, body, list);
    const rows = pane.capacity(inner, list.visual);
    var row: u16 = 0;
    while (row < rows and list.scroll + row < list.item_count) : (row += 1) {
        const index = list.scroll + row;
        const bookmark = &application.store.items[application.filtered[index]];
        const title = bookmark.title.bytes();
        const host = bookmark.host();
        const tags = bookmark.tags.bytes();
        try pane.item(tree, body, list, inner.width, .{
            .title = title,
            .detail = if (std.ascii.eqlIgnoreCase(title, host)) "" else host,
            .subtitle = if (tags.len == 0) bookmark.notes.bytes() else tags,
            .marker = if (bookmark.favorite) '*' else ' ',
        }, index == list.selected);
    }
}

fn safe_highlight(application: anytype, query: []const u8) []const u8 {
    if (query.len == 0) return query;
    var index = application.scroll;
    while (index < application.filtered_count) : (index += 1) {
        const bookmark = &application.store.items[application.filtered[index]];
        if (!pane.is_ascii(bookmark.title.bytes())) return "";
    }
    return query;
}

fn fill_preview(view: *View, application: anytype, frame: *Frame) !void {
    std.debug.assert(frame.page.len == 0);
    const bookmark = application.selected_bookmark() orelse return;
    const tree = &frame.base;
    const area = node.rect_of(tree, view.preview.area);
    std.debug.assert(area.width >= 0 and area.height >= 0);
    const text = bookmark.preview.bytes();
    var total: i32 = 0;
    if (text.len > 0 and area.width > 0) {
        const root = try node.box(&frame.page, node.none, .{
            .width = node.fixed(area.width),
            .height = node.fit,
        });
        const ink = theme.ink(theme.palette.foreground);
        _ = try node.paragraph(&frame.page, root, text, .{ .style = ink });
        node.resolve(&frame.page, area.width, markix.unbounded);
        total = markix.backend.cells.height_of(&frame.page);
    }
    const lines = rows_of(total);
    application.set_preview_metrics(lines, rows_of(area.height));
    if (lines == 0) return;
    frame.page_options = .{
        .x = area.x,
        .y = area.y,
        .scroll = application.preview_scroll,
        .clip = area,
        .base = theme.panel(),
    };
    var counter: [24]u8 = undefined;
    const position = @min(application.preview_scroll +| 1, lines);
    const fraction = std.fmt.bufPrint(&counter, "{d}/{d}", .{ position, lines }) catch "";
    _ = try node.label(tree, view.preview.head, view.progress.set("{s: >11} ", .{fraction}), .{
        .width = node.fixed(progress_width),
        .style = .{ .foreground = theme.palette.accent, .background = theme.palette.panel_alt },
    });
}

fn rows_of(cells: i32) u16 {
    return @intCast(std.math.clamp(cells, 0, std.math.maxInt(u16)));
}

fn fill_focus(application: anytype, tree: *Tree, panel: pane.Panel) !void {
    const inner = node.inner_of(tree, panel.body);
    if (!finder_open(application)) {
        application.set_viewport_rows(pane.capacity(inner, bookmark_list_visual));
    }
    const list = bookmark_list(application, true, application.search.value());
    try fill_bookmarks(application, tree, panel.body, inner, list);
}

fn fill_form(view: *View, application: anytype, tree: *Tree, panel: pane.Panel) !void {
    std.debug.assert(view.field_count == 0);
    const palette = theme.palette;
    const inner = node.inner_of(tree, panel.body);
    const selected = field_index(application.field);
    const tabs = try node.line(tree, panel.body, .{});
    try header.segments(
        tree,
        tabs,
        &form_fields,
        selected,
        theme.chip(palette.inverse_foreground, palette.accent_warm),
        .{ .foreground = palette.muted, .background = palette.panel_alt, .dim = true },
    );
    _ = try node.spacer(tree, panel.body, node.grow, node.fixed(1));
    const grid = try node.box(tree, panel.body, .{ .height = node.fit, .gap = 1 });
    const room = @max(0, inner.width - form_label_width - 1);
    inline for (.{ "title", "url", "tags", "notes" }, 0..) |name, index| {
        const input = &@field(application, name);
        const focused = index == selected;
        const strip = try form_row(tree, grid, index, input.value(), input.cursor, focused, room);
        view.fields[index] = strip;
    }
    view.field_count = form_fields.len;
    std.debug.assert(view.field_count == form_order.len);
}

fn form_row(
    tree: *Tree,
    grid: Index,
    index: usize,
    value: []const u8,
    cursor: u16,
    focused: bool,
    room: i32,
) !Index {
    std.debug.assert(index < form_labels.len);
    std.debug.assert(room >= 0);
    const line = try node.row(tree, grid, .{ .height = node.fixed(1), .gap = 1 });
    _ = try node.label(tree, line, form_labels[index], .{
        .width = node.fixed(form_label_width),
        .style = theme.faint(theme.palette.muted),
    });
    var look = field.focused_look();
    if (!focused) look.ground = theme.palette.panel;
    return field.field(tree, line, .{
        .placeholder = form_placeholders[index],
        .value = value,
        .cursor = cursor,
        .focused = focused,
        .look = look,
    }, room);
}

fn build_overlay(view: *View, application: anytype, frame: *Frame, band: Rect) !void {
    std.debug.assert(frame.overlay.len == 0);
    std.debug.assert(band.width >= 0);
    if (application.help_open) {
        const rect = help.rect_for(band);
        const sheet = help.layout_for(rect, keymap.row_count(&keymap.bookmarker));
        if (sheet.rows == 0) return;
        try help.build(&frame.overlay, rect, sheet, &keymap.bookmarker, "KEYBOARD HELP");
        return place_overlay(frame, rect);
    }
    const rect = command_center.rect_for(band);
    if (rect.width <= 0 or rect.height <= 0) return;
    if (application.mode == .command) {
        try build_command(view, application, &frame.overlay, rect);
        return place_overlay(frame, rect);
    }
    if (finder_open(application)) {
        try build_finder(view, application, &frame.overlay, rect);
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
    application.set_command_viewport_rows(rows);
    application.mouse_layout.command_results = list_region(
        command_center.results_rect(rect, false),
        application.command.scroll,
        tokens.command_list_visual.row_height,
    );
    const query = application.command.query();
    const cursor = application.command.input.cursor;
    if (application.active_argument()) |argument| {
        const label = application.active_label();
        const config = command_policy.argument_config(label, argument.placeholder);
        _ = try command_center.surface(tree, rect, config, query, cursor);
        return;
    }
    const meta = view.command_meta.set("{d} RESULTS", .{application.command.count});
    const config = command_policy.deck_config(meta, query);
    const surface = try command_center.surface(tree, rect, config, query, cursor);
    try command_center.fill(
        tree,
        surface,
        rows,
        &application.command,
        application,
        config.empty_text,
    );
}

fn build_finder(view: *View, application: anytype, tree: *Tree, rect: Rect) !void {
    std.debug.assert(tree.len == 0);
    std.debug.assert(rect.width > 0 and rect.height > 0);
    const selected = choose_categories(view, application);
    const config = command_policy.finder_config(
        "FIND BOOKMARKS",
        scope_name(application),
        "Fuzzy search titles, URLs, tags, notes, and page text",
        .{
            .items = view.categories[0..view.category_count],
            .selected = selected,
            .label = command_policy.finder.filter_label,
        },
    );
    const query = application.search.value();
    const cursor = application.search.cursor;
    const surface = try command_center.surface(tree, rect, config, query, cursor);
    var list = bookmark_list(application, true, query);
    list.role = .command;
    const results = command_center.results_rect(rect, true);
    try fill_bookmarks(application, tree, surface.results, results, list);
    register_finder(view, application, rect);
}

fn choose_categories(view: *View, application: anytype) u16 {
    const count = scope_item_count(application);
    std.debug.assert(count >= 2);
    if (count == 2) {
        view.categories[0] = .{ .label = scope_item_name(application, 0) };
        view.categories[1] = .{ .label = scope_item_name(application, 1) };
        view.category_scopes[0] = 0;
        view.category_scopes[1] = 1;
        view.category_count = 2;
        return application.scope_cursor;
    }
    const cursor = application.scope_cursor;
    std.debug.assert(cursor < count);
    const around = [3]u16{
        if (cursor == 0) count - 1 else cursor - 1,
        cursor,
        if (cursor + 1 == count) 0 else cursor + 1,
    };
    for (around, 0..) |scope, index| {
        view.categories[index] = .{ .label = scope_item_name(application, scope) };
        view.category_scopes[index] = scope;
    }
    view.category_count = 3;
    return 1;
}

fn register_finder(view: *View, application: anytype, rect: Rect) void {
    const layout = &application.mouse_layout;
    std.debug.assert(view.category_count <= layout.categories.len);
    layout.focus_modal = geometry.Rect.from(rect);
    layout.finder_results = list_region(
        command_center.results_rect(rect, true),
        application.scroll,
        bookmark_list_visual.row_height,
    );
    var boxes: [3]Rect = undefined;
    const count = command_center.filter_hit_boxes(
        command_center.filters_rect(rect),
        view.categories[0..view.category_count],
        &boxes,
    );
    std.debug.assert(count <= view.category_count);
    for (boxes[0..count], 0..) |box, index| {
        layout.categories[index] = .{
            .rect = geometry.Rect.from(box),
            .scope_index = view.category_scopes[index],
        };
    }
    layout.category_count = count;
}

fn register_geometry(view: *View, application: anytype, tree: *const Tree) void {
    const layout = &application.mouse_layout;
    std.debug.assert(view.pane_count <= view.panes.len);
    std.debug.assert(view.field_count <= layout.fields.len);
    for (view.panes[0..view.pane_count]) |entry| {
        const inner = node.inner_of(tree, entry.panel.body);
        switch (entry.kind) {
            .scopes => layout.scopes = list_region(
                inner,
                application.scope_scroll,
                scope_list_visual.row_height,
            ),
            .bookmarks => layout.bookmarks = list_region(
                inner,
                application.scroll,
                bookmark_list_visual.row_height,
            ),
            .preview => layout.preview = geometry.Rect.from(inner),
        }
    }
    if (view.focus) |panel| layout.focus = list_region(
        node.inner_of(tree, panel.body),
        application.scroll,
        bookmark_list_visual.row_height,
    );
    for (view.fields[0..view.field_count], 0..) |strip, index| {
        layout.fields[index] = .{
            .rect = geometry.Rect.from(node.rect_of(tree, strip)),
            .field = form_order[index],
        };
    }
    layout.field_count = view.field_count;
}

fn list_region(rect: Rect, scroll: u16, row_height: u8) MouseListRegion {
    std.debug.assert(row_height > 0);
    return .{ .rect = geometry.Rect.from(rect), .scroll = scroll, .row_height = row_height };
}

fn scope_item_count(application: anytype) u16 {
    return application.tag_count + 2;
}

fn scope_item_name(application: anytype, index: u16) []const u8 {
    if (index == 0) return "All";
    if (index == 1) return "Favorites";
    return application.tags_available[index - 2].bytes();
}

fn scope_bookmark_count(application: anytype, scope_index: u16) u16 {
    if (scope_index == 0) return application.store.count;
    var count: u16 = 0;
    var index: u16 = 0;
    while (index < application.store.count) : (index += 1) {
        const bookmark = &application.store.items[index];
        const matches = if (scope_index == 1)
            bookmark.favorite
        else
            bookmark.has_tag(application.tags_available[scope_index - 2].bytes());
        if (matches) count += 1;
    }
    return count;
}

fn scope_name(application: anytype) []const u8 {
    return switch (application.scope_kind) {
        .all => "All bookmarks",
        .favorites => "Favorites",
        .tag => application.active_tag.bytes(),
    };
}

fn empty_bookmark_text(application: anytype) []const u8 {
    if (application.search.value().len > 0) return "No search results";
    if (application.scope_kind == .favorites) return "No favorites in this library";
    if (application.scope_kind == .tag) return "No bookmarks with this tag";
    return "Press a to add a bookmark";
}

fn focus_accent(focus: BrowserFocus) Color {
    return switch (focus) {
        .scopes => theme.palette.accent_cool,
        .bookmarks => theme.palette.accent_warm,
        .preview => theme.palette.accent,
    };
}

fn focus_index(focus: BrowserFocus) u16 {
    return switch (focus) {
        .scopes => 0,
        .bookmarks => 1,
        .preview => 2,
    };
}

fn field_index(value: Field) u16 {
    return switch (value) {
        .title => 0,
        .url => 1,
        .tags => 2,
        .notes => 3,
    };
}
