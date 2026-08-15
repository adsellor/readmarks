//! A titled panel wrapping a scrolling list. Categories, feeds, articles,
//! scopes, bookmarks and command results are all this component with different
//! configuration.

const std = @import("std");
const markix = @import("markix");
const dom = markix.dom;
const layout = markix.layout;
const theme = @import("../theme.zig");
const tokens = @import("tokens.zig");

const NodeIndex = dom.DomTree.NodeIndex;
const LayoutElement = layout.LayoutElement;
const Rect = layout.Rect;

/// Upper bound on rows mounted for one list. Rows are mounted only for the
/// visible window, so this tracks terminal height rather than collection size.
pub const rows_max: u16 = 64;

/// What a pane holds, which is what decides its accent. The role is the whole
/// of the colour decision: a pane that narrows a collection looks the same in
/// the reader as it does in the bookmarker.
pub const Role = enum {
    /// Scopes, categories, feeds: the things that narrow a collection.
    filter,
    /// Articles, bookmarks: the collection itself.
    collection,
    /// The reader, the preview: the document.
    document,
    /// The command centre and its finder.
    command,

    pub fn accent(self: Role) markix.Color {
        return switch (self) {
            .filter => theme.accent_cool,
            .collection => theme.accent_warm,
            .document => theme.accent,
            .command => theme.command,
        };
    }

    pub fn style(self: Role, focused: bool) markix.Style {
        if (self == .command) return theme.command_panel;
        return theme.pane_style(self.accent(), focused);
    }
};

/// Mounted nodes. Rows occupy `row_count` consecutive indices from `first_row`.
pub const Slot = struct {
    mounted: bool = false,
    panel: NodeIndex = 0,
    list: NodeIndex = 0,
    first_row: NodeIndex = 0,
    row_count: u16 = 0,
    rect: Rect = Rect.init(0, 0, 0, 0),
    inner: Rect = Rect.init(0, 0, 0, 0),
};

pub const Config = struct {
    role: Role,
    focused: bool = false,
    title: []const u8 = "",
    meta: []const u8 = "",
    empty_text: []const u8 = "No items",
    highlight: []const u8 = "",
    visual: markix.widgets.ListVisual = tokens.item_list_visual,
    /// Items in the backing collection, which may exceed the mounted rows.
    item_count: u16 = 0,
    /// Index of the first mounted row within the collection.
    scroll: u16 = 0,
    selected: u16 = 0,
};

/// One row's content. The caller fills these from whatever it is listing.
pub const Row = struct {
    title: []const u8 = "",
    detail: []const u8 = "",
    subtitle: []const u8 = "",
    marker: u8 = ' ',
};

/// Mounts a pane that fills the box its parent gives it.
pub fn mount(
    tree: *dom.DomTree,
    parent: NodeIndex,
    rows: u16,
    visual: markix.widgets.ListVisual,
) !Slot {
    var slot = Slot{};
    slot.panel = try tree.append_child(parent, .{
        .kind = .panel,
        .props = .{ .panel = .{ .chrome = tokens.pane_chrome, .style = theme.panel_style } },
        .layout = try LayoutElement.flex(.column, 0, &.{.{ .fraction = 1 }}),
    });
    slot.list = try tree.append_child(slot.panel, .{
        .kind = .list,
        .props = .{ .list = .{ .style = theme.panel_style, .visual = visual } },
        .layout = LayoutElement.leaf(),
    });
    slot.mounted = true;
    try mount_rows(tree, &slot, rows);
    return slot;
}

/// Mounts a pane at an explicit placement inside a free parent.
pub fn mount_placed(
    tree: *dom.DomTree,
    parent: NodeIndex,
    placement: Rect,
    rows: u16,
    visual: markix.widgets.ListVisual,
) !Slot {
    var element = try LayoutElement.flex(.column, 0, &.{.{ .fraction = 1 }});
    element.placement = .{
        .x = placement.x,
        .y = placement.y,
        .width = placement.width,
        .height = placement.height,
    };
    var slot = Slot{};
    slot.panel = try tree.append_child(parent, .{
        .kind = .panel,
        .props = .{ .panel = .{ .chrome = tokens.pane_chrome, .style = theme.panel_style } },
        .layout = element,
    });
    slot.list = try tree.append_child(slot.panel, .{
        .kind = .list,
        .props = .{ .list = .{ .style = theme.panel_style, .visual = visual } },
        .layout = LayoutElement.leaf(),
    });
    slot.mounted = true;
    try mount_rows(tree, &slot, rows);
    return slot;
}

/// Mounts a bare list with no panel around it, for a surface that already has
/// its own chrome -- the command centre and the finder.
pub fn mount_list(
    tree: *dom.DomTree,
    parent: NodeIndex,
    placement: Rect,
    rows: u16,
    visual: markix.widgets.ListVisual,
    style: markix.Style,
) !Slot {
    var slot = Slot{};
    slot.list = try tree.append_child(parent, .{
        .kind = .list,
        .props = .{ .list = .{ .style = style, .visual = visual } },
        .layout = LayoutElement.placed(
            placement.x,
            placement.y,
            placement.width,
            placement.height,
        ),
    });
    slot.mounted = true;
    try mount_rows(tree, &slot, rows);
    return slot;
}

fn mount_rows(tree: *dom.DomTree, slot: *Slot, rows: u16) !void {
    std.debug.assert(slot.mounted);
    std.debug.assert(rows <= rows_max);
    slot.first_row = tree.node_count;
    var index: u16 = 0;
    while (index < rows) : (index += 1) {
        _ = try tree.append_child(slot.list, .{
            .kind = .list_item,
            .props = .{ .list_item = .{} },
            .layout = LayoutElement.leaf(),
        });
    }
    slot.row_count = rows;
}

/// Writes the panel's chrome. Separate from the rows so a surface that owns
/// its own chrome can update the rows alone.
pub fn update_frame(tree: *dom.DomTree, slot: *const Slot, config: Config) void {
    if (!slot.mounted or slot.panel == 0) return;
    tree.set_focused(slot.panel, config.focused);
    tree.set_props(slot.panel, .{ .panel = .{
        .style = config.role.style(config.focused),
        .chrome = tokens.pane_chrome,
        .title = config.title,
        .meta = config.meta,
    } });
}

/// Writes the list's own props. `rows` is the visible window, so the list's
/// scroll stays at zero and it is the row props that move.
pub fn update_list(tree: *dom.DomTree, slot: *const Slot, config: Config) void {
    if (!slot.mounted) return;
    std.debug.assert(slot.list != 0);
    std.debug.assert(config.scroll <= config.item_count);
    std.debug.assert(config.visual.row_height > 0);
    tree.set_focused(slot.list, config.focused);
    tree.set_props(slot.list, .{ .list = .{
        .style = config.role.style(config.focused),
        .empty_text = config.empty_text,
        .highlight_query = config.highlight,
        .match_foreground = if (config.highlight.len > 0) theme.command else null,
        .visual = config.visual,
        .item_count = config.item_count,
        .selected = config.selected -| config.scroll,
    } });
}

/// Writes one row of the visible window. `window_index` is the row's offset
/// from the top of the window, not its index in the collection.
pub fn set_row(
    tree: *dom.DomTree,
    slot: *const Slot,
    window_index: u16,
    row: ?Row,
    selected: bool,
) void {
    std.debug.assert(window_index < slot.row_count);
    const node = slot.first_row + window_index;
    const value = row orelse {
        tree.set_props(node, .{ .list_item = .{} });
        return;
    };
    tree.set_props(node, .{ .list_item = .{
        .title = value.title,
        .detail = value.detail,
        .subtitle = value.subtitle,
        .marker = value.marker,
        .selected = selected,
    } });
}

/// Blanks every row past the end of the collection.
pub fn clear_rows_from(tree: *dom.DomTree, slot: *const Slot, first: u16) void {
    std.debug.assert(slot.mounted);
    std.debug.assert(first <= slot.row_count);
    var row = first;
    while (row < slot.row_count) : (row += 1) {
        tree.set_props(slot.first_row + row, .{ .list_item = .{} });
    }
}

pub fn is_ascii(text: []const u8) bool {
    std.debug.assert(text.len <= std.math.maxInt(u16));
    for (text) |byte| {
        if (byte >= 0x80) return false;
    }
    return true;
}

pub fn mark_rows_dirty(tree: *dom.DomTree, slot: *const Slot) void {
    if (!slot.mounted) return;
    std.debug.assert(slot.row_count <= rows_max);
    var row: u16 = 0;
    while (row < slot.row_count) : (row += 1) {
        tree.mark_dirty(slot.first_row + row);
    }
}

pub fn capture_rects(tree: *dom.DomTree, slot: *Slot) void {
    if (!slot.mounted) return;
    std.debug.assert(slot.list != 0);
    if (slot.panel != 0) {
        const node = tree.get(slot.panel) orelse return;
        slot.rect = node.rect();
    }
    const list = tree.get(slot.list) orelse return;
    slot.inner = list.rect();
}

/// Rows a pane of this size can show, derived from the panel's content box so
/// it matches what the renderer lays out.
pub fn visible_rows(rect: Rect, row_height: u8) u16 {
    if (row_height == 0) return 0;
    const inner = markix.widgets.panel_content_rect(tokens.pane_chrome, rect);
    std.debug.assert(inner.height <= rect.height);
    const rows = @min(@divFloor(inner.height, row_height), rows_max);
    std.debug.assert(rows <= rows_max);
    return rows;
}

test "roles map to distinct accents" {
    try std.testing.expect(!Role.filter.accent().equals(Role.collection.accent()));
    try std.testing.expect(!Role.collection.accent().equals(Role.document.accent()));
    try std.testing.expect(!Role.document.accent().equals(Role.command.accent()));
}
