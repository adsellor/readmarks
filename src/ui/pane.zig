const std = @import("std");
const theme = @import("../theme.zig");
const tokens = @import("tokens.zig");
const fuzzy = @import("fuzzy.zig");
const node = @import("node.zig");

const Tree = node.Tree;
const Index = node.Index;
const Color = node.Color;
const Style = node.Style;
const Rect = node.Rect;
const Sizing = node.Sizing;

pub const rows_max: u16 = 64;
const title_bytes_max: usize = 512;

pub const Role = enum {
    filter,
    collection,
    document,
    command,

    pub fn accent(self: Role) Color {
        return switch (self) {
            .filter => theme.palette.accent_cool,
            .collection => theme.palette.accent_warm,
            .document => theme.palette.accent,
            .command => theme.palette.command,
        };
    }

    pub fn selection(self: Role, focused: bool) Color {
        if (self == .command) return theme.palette.command_row;
        return if (focused) theme.palette.selection else theme.palette.line;
    }
};

pub const Frame = struct {
    chrome: tokens.Chrome = tokens.pane_chrome,
    title: []const u8 = "",
    meta: []const u8 = "",
    rail: Color,
    title_color: Color,
    ground: Color,
    header_ground: Color = .{},
    width: Sizing = node.grow,
    height: Sizing = node.grow,
};

pub fn frame_for(role: Role, focused: bool) Frame {
    const lit = focused or role == .command;
    return .{
        .rail = if (lit) role.accent() else theme.palette.line,
        .title_color = if (lit) role.accent() else theme.palette.muted,
        .ground = theme.palette.panel,
        .header_ground = role.selection(true),
    };
}

pub const Panel = struct {
    outer: Index,
    body: Index,
};

pub fn panel(tree: *Tree, parent: Index, frame: Frame) !Panel {
    const chrome = frame.chrome;
    std.debug.assert(chrome.padding_top >= 1);
    const outer = try node.row(tree, parent, .{
        .width = frame.width,
        .height = frame.height,
        .background = frame.ground,
    });
    if (chrome.rail_width > 0) {
        const rail = try node.box(tree, outer, .{ .width = node.fixed(chrome.rail_width) });
        const length = if (chrome.rail_height == 0) node.grow else node.fixed(chrome.rail_height);
        _ = try node.fill(tree, rail, node.grow, length, frame.rail);
    }
    const main = try node.box(tree, outer, .{});
    try header(tree, main, frame);
    if (chrome.padding_top > 1) {
        _ = try node.spacer(tree, main, node.grow, node.fixed(chrome.padding_top - 1));
    }
    const body = try node.box(tree, main, .{
        .padding = .{ .left = chrome.padding_left },
    });
    std.debug.assert(body > outer);
    return .{ .outer = outer, .body = body };
}

pub fn floating(tree: *Tree, rect: Rect, frame: Frame) !Panel {
    std.debug.assert(tree.len == 0);
    std.debug.assert(rect.width > 0 and rect.height > 0);
    const shadow = theme.palette.shadow;
    const root = try node.box(tree, node.none, .{
        .width = node.fixed(rect.width + 1),
        .height = node.fixed(rect.height + 1),
    });
    const top = try node.row(tree, root, .{ .height = node.fixed(rect.height) });
    var placed = frame;
    placed.width = node.fixed(rect.width);
    placed.height = node.grow;
    const result = try panel(tree, top, placed);
    const side = try node.box(tree, top, .{ .width = node.fixed(1) });
    _ = try node.spacer(tree, side, node.grow, node.fixed(1));
    _ = try node.fill(tree, side, node.grow, node.grow, shadow);
    const bottom = try node.row(tree, root, .{ .height = node.fixed(1) });
    _ = try node.spacer(tree, bottom, node.fixed(1), node.grow);
    _ = try node.fill(tree, bottom, node.grow, node.grow, shadow);
    return result;
}

fn header(tree: *Tree, parent: Index, frame: Frame) !void {
    const strip = try node.row(tree, parent, .{
        .height = node.fixed(1),
        .padding = .{ .left = frame.chrome.padding_left, .right = 1 },
        .gap = 1,
        .background = if (frame.chrome.header_background) frame.header_ground else .{},
    });
    _ = try node.label(tree, strip, frame.title, .{ .style = theme.strong(frame.title_color) });
    if (frame.meta.len == 0 or !meta_fits(frame)) return;
    _ = try node.label(tree, strip, frame.meta, .{
        .width = node.fit_at_least(node.columns(frame.meta)),
        .style = theme.faint(theme.palette.muted),
    });
}

fn meta_fits(frame: Frame) bool {
    const width = switch (frame.width) {
        .fixed => |cells| cells,
        else => return true,
    };
    const chrome = frame.chrome;
    const room = width - chrome.rail_width - chrome.padding_left - 1;
    return node.columns(frame.title) + 1 + node.columns(frame.meta) <= room;
}

pub const List = struct {
    role: Role,
    focused: bool = false,
    empty_text: []const u8 = "No items",
    highlight: []const u8 = "",
    visual: tokens.Visual = tokens.item_list_visual,
    item_count: u16 = 0,
    scroll: u16 = 0,
    selected: u16 = 0,
};

pub const Row = struct {
    title: []const u8 = "",
    detail: []const u8 = "",
    subtitle: []const u8 = "",
    marker: u8 = ' ',
};

pub fn capacity(inner: Rect, visual: tokens.Visual) u16 {
    std.debug.assert(visual.row_height > 0);
    if (inner.height <= 0) return 0;
    const rows = @divFloor(inner.height, visual.row_height);
    return @intCast(@min(rows, rows_max));
}

pub fn empty(tree: *Tree, body: Index, list: List) !void {
    std.debug.assert(list.item_count == 0);
    _ = try node.label(tree, body, list.empty_text, .{ .style = theme.ink(theme.palette.muted) });
}

pub fn item(tree: *Tree, body: Index, list: List, width: i32, value: Row, selected: bool) !void {
    const visual = list.visual;
    std.debug.assert(visual.row_height > 0);
    std.debug.assert(visual.title_column >= 2);
    const accent = list.role.accent();
    const ground: Color = if (selected) list.role.selection(list.focused) else .{};
    const entry = try node.box(tree, body, .{ .height = node.fixed(visual.row_height) });
    const first = try node.row(tree, entry, .{ .height = node.fixed(1) });
    const pointer: []const u8 = if (selected) visual.selected_marker else " ";
    const pointer_color = if (list.focused) accent else theme.palette.muted;
    _ = try node.label(tree, first, pointer, .{
        .width = node.fixed(1),
        .style = theme.ink(pointer_color),
    });
    _ = try node.label(tree, first, marker_text(value.marker), .{
        .width = node.fixed(visual.title_column - 1),
        .style = theme.ink(accent),
    });
    const title = try node.line(tree, first, .{});
    const strong = selected or visual.title_bold;
    try highlighted(tree, title, value.title, list, .{
        .foreground = if (selected) theme.palette.foreground_strong else theme.palette.foreground,
        .background = ground,
        .bold = strong,
    });
    const detail_width = detail_columns(width, value.detail, visual.detail_width_divisor);
    if (detail_width > 0) {
        _ = try node.spacer(tree, first, node.fixed(1), node.fixed(1));
        _ = try node.label(tree, first, value.detail, .{
            .width = node.fixed(detail_width),
            .style = if (selected)
                .{ .foreground = accent, .background = ground }
            else
                theme.faint(theme.palette.muted),
        });
    }
    if (visual.row_height < 2 or value.subtitle.len == 0) return;
    const second = try node.row(tree, entry, .{ .height = node.fixed(1) });
    _ = try node.spacer(tree, second, node.fixed(visual.title_column), node.fixed(1));
    const faint = theme.faint(theme.palette.muted);
    _ = try node.label(tree, second, value.subtitle, .{ .style = faint });
}

const markers = blk: {
    var table: [256][1]u8 = undefined;
    for (&table, 0..) |*slot, byte| slot.* = .{@intCast(byte)};
    break :blk table;
};

fn marker_text(marker: u8) []const u8 {
    if (!std.ascii.isPrint(marker)) return " ";
    return &markers[marker];
}

fn detail_columns(width: i32, detail: []const u8, divisor: u8) i32 {
    if (width <= 8 or detail.len == 0 or divisor == 0) return 0;
    const maximum = @min(@divFloor(width, divisor), width - 5);
    return @min(node.columns(detail), maximum);
}

pub fn highlighted(tree: *Tree, title: Index, text: []const u8, list: List, style: Style) !void {
    std.debug.assert(title != node.none);
    var mask: [title_bytes_max]bool = undefined;
    const usable = text.len <= mask.len and list.highlight.len > 0;
    if (!usable or !fuzzy.mark_matches(text, list.highlight, &mask)) {
        return node.run(tree, title, text, style);
    }
    var match = style;
    match.foreground = theme.palette.command;
    match.underline = true;
    match.bold = true;
    std.debug.assert(text.len <= mask.len);
    var start: usize = 0;
    while (start < text.len) {
        const matched = mask[start];
        var end = start + 1;
        while (end < text.len and mask[end] == matched) : (end += 1) {}
        try node.run(tree, title, text[start..end], if (matched) match else style);
        start = end;
    }
}

pub fn is_ascii(text: []const u8) bool {
    for (text) |byte| {
        if (byte >= 0x80) return false;
    }
    return true;
}

const testing = std.testing;

test "roles map to distinct accents" {
    try testing.expect(!Role.filter.accent().eql(Role.collection.accent()));
    try testing.expect(!Role.collection.accent().eql(Role.document.accent()));
    try testing.expect(!Role.document.accent().eql(Role.command.accent()));
}

test "a pane puts its body under the header and beside the rail" {
    var nodes: [32]node.Node = undefined;
    var tree = Tree.init(&nodes);
    const frame = try panel(&tree, node.none, .{
        .title = "FEEDS",
        .meta = "3 SOURCES",
        .rail = theme.palette.accent,
        .title_color = theme.palette.accent,
        .ground = theme.palette.panel,
    });
    node.resolve(&tree, 30, 10);
    const inner = node.inner_of(&tree, frame.body);
    const expected = tokens.content_rect(tokens.pane_chrome, Rect.init(0, 0, 30, 10));
    try testing.expectEqual(expected, inner);
    try testing.expectEqual(@as(u16, 4), capacity(inner, tokens.item_list_visual));
}

test "a highlighted title splits into matched and unmatched runs" {
    var nodes: [16]node.Node = undefined;
    var tree = Tree.init(&nodes);
    const root = try node.row(&tree, node.none, .{
        .width = node.fixed(20),
        .height = node.fixed(1),
    });
    const title = try node.line(&tree, root, .{});
    try highlighted(&tree, title, "TigerStyle", .{ .role = .filter, .highlight = "tgs" }, .{});
    try testing.expectEqual(@as(usize, 2 + 6), tree.len);
    try testing.expectEqualStrings("T", tree.at(2).text);
    try testing.expect(tree.at(2).style.underline);
    try testing.expectEqualStrings("i", tree.at(3).text);
}

test "a detail never takes more than its share of the row" {
    try testing.expectEqual(@as(i32, 0), detail_columns(8, "12", 3));
    try testing.expectEqual(@as(i32, 2), detail_columns(40, "12", 3));
    try testing.expectEqual(@as(i32, 10), detail_columns(30, "2026-11-01 12:00", 3));
}
