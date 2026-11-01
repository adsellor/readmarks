const std = @import("std");
const theme = @import("../theme.zig");
const tokens = @import("tokens.zig");
const keymap = @import("../keymap.zig");
const node = @import("node.zig");
const pane = @import("pane.zig");

const Tree = node.Tree;
const Rect = node.Rect;

pub const rows_max: u16 = 48;
pub const columns_max: u16 = 3;
const label_column: i32 = 16;
const column_width_min: i32 = 33;
const column_gap: i32 = 2;

pub fn rect_for(bounds: Rect) Rect {
    const width = @max(0, @min(bounds.width - 2, 108));
    const height = @max(0, bounds.height - 2);
    return Rect.init(
        bounds.x + @divFloor(bounds.width - width, 2),
        bounds.y + @divFloor(bounds.height - height, 2),
        width,
        height,
    );
}

pub const Layout = struct {
    rows: u16 = 0,
    columns: u16 = 0,
    column_width: i32 = 0,

    pub fn cells(self: Layout) u16 {
        return self.rows * self.columns;
    }
};

pub fn layout_for(rect: Rect, entry_count: u16) Layout {
    std.debug.assert(entry_count <= rows_max * columns_max);
    const inner = tokens.content_rect(tokens.overlay_chrome, rect);
    const available: u16 = @intCast(@min(@max(inner.height, 0), rows_max));
    if (available == 0 or inner.width < column_width_min) return .{};
    const stride = column_width_min + column_gap;
    const fits: u16 = @intCast(@max(@divFloor(inner.width + column_gap, stride), 1));
    const needed = @divFloor(entry_count + available - 1, available);
    const columns = @min(@min(@max(needed, 1), fits), columns_max);
    const balanced = @divFloor(entry_count + columns - 1, columns);
    const gaps = column_gap * (columns - 1);
    std.debug.assert(columns >= 1);
    return .{
        .rows = @min(@max(balanced, 1), available),
        .columns = columns,
        .column_width = @divFloor(@max(0, inner.width - gaps), columns),
    };
}

pub fn build(
    tree: *Tree,
    rect: Rect,
    sheet: Layout,
    own: []const keymap.Entry,
    title: []const u8,
) !void {
    std.debug.assert(tree.len == 0);
    std.debug.assert(sheet.rows <= rows_max);
    var frame = pane.frame_for(.command, true);
    frame.chrome = tokens.overlay_chrome;
    frame.title = title;
    frame.meta = "? / ESC TO CLOSE";
    const panel = try pane.floating(tree, rect, frame);
    const grid = try node.row(tree, panel.body, .{ .gap = column_gap });
    var column: u16 = 0;
    while (column < sheet.columns) : (column += 1) {
        const strip = try node.box(tree, grid, .{ .width = node.fixed(sheet.column_width) });
        var row: u16 = 0;
        while (row < sheet.rows) : (row += 1) {
            const entry = entry_at(own, column * sheet.rows + row) orelse break;
            const line = try node.row(tree, strip, .{ .height = node.fixed(1) });
            const palette = theme.palette;
            const key_color = if (entry.is_heading()) palette.command else palette.accent_warm;
            _ = try node.label(tree, line, entry.key, .{
                .width = node.fixed(label_column),
                .style = theme.ink(key_color),
            });
            const ink = theme.ink(palette.foreground);
            _ = try node.label(tree, line, entry.label, .{ .style = ink });
        }
    }
}

fn entry_at(own: []const keymap.Entry, cell: u16) ?keymap.Entry {
    if (cell < keymap.shared.len) return keymap.shared[cell];
    const index = cell - keymap.shared.len;
    if (index >= own.len) return null;
    return own[index];
}

test "the sheet reads shared bindings before the experience's own" {
    try std.testing.expectEqualStrings(keymap.shared[0].key, entry_at(&keymap.reader, 0).?.key);
    const first_own = entry_at(&keymap.reader, @intCast(keymap.shared.len)).?;
    try std.testing.expectEqualStrings(keymap.reader[0].key, first_own.key);
    try std.testing.expect(entry_at(&keymap.reader, rows_max) == null);
}

test "a wide sheet spreads its entries over balanced columns" {
    const rect = rect_for(Rect.init(0, 2, 120, 18));
    const sheet = layout_for(rect, 40);
    try std.testing.expectEqual(@as(u16, 3), sheet.columns);
    try std.testing.expectEqual(@as(u16, 14), sheet.rows);
    try std.testing.expect(sheet.cells() >= 40);
}
