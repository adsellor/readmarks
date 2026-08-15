//! The help sheet, rendered from a keymap table. Both experiences mount this
//! same surface; only the table differs.

const std = @import("std");
const markix = @import("markix");
const dom = markix.dom;
const layout = markix.layout;
const theme = @import("../theme.zig");
const tokens = @import("tokens.zig");
const keymap = @import("../keymap.zig");

const NodeIndex = dom.DomTree.NodeIndex;
const LayoutElement = layout.LayoutElement;
const Rect = layout.Rect;

pub const rows_max: u16 = 48;
pub const columns_max: u16 = 3;
/// Column the label starts in, leaving room for the widest key in the tables.
const label_column: u16 = 16;
/// Narrowest a column can be and still show a key beside its explanation.
const column_width_min: u16 = 34;
/// Gap between columns.
const column_gap: u16 = 2;

pub const Slot = struct {
    mounted: bool = false,
    panel: NodeIndex = 0,
    shadow: NodeIndex = 0,
    first_row: NodeIndex = 0,
    /// Cells, not rows: `rows * columns`, filled column by column.
    row_count: u16 = 0,
    rows: u16 = 0,
    columns: u16 = 0,
};

/// The sheet is a reference, so it takes as much of the band as it can rather
/// than the three quarters a prompt takes: a binding that does not fit is a
/// binding the user cannot discover.
pub fn rect_for(bounds: Rect) Rect {
    const width = @min(bounds.width -| 2, 108);
    const height = bounds.height -| 2;
    return Rect.init(
        bounds.x + (bounds.width - width) / 2,
        bounds.y + (bounds.height - height) / 2,
        width,
        height,
    );
}

/// How the sheet divides `rect` up for `entry_count` bindings. Columns are
/// added only when the rows alone cannot hold them all.
pub const Layout = struct {
    rows: u16 = 0,
    columns: u16 = 0,
    column_width: u16 = 0,

    pub fn cells(self: Layout) u16 {
        return self.rows * self.columns;
    }
};

pub fn layout_for(rect: Rect, entry_count: u16) Layout {
    const inner = markix.widgets.panel_content_rect(tokens.overlay_chrome, rect);
    const available = @min(inner.height, rows_max);
    if (available == 0 or inner.width < column_width_min) return .{};
    const fits = @max(@divFloor(inner.width + column_gap, column_width_min + column_gap), 1);
    const needed = @divFloor(entry_count + available - 1, available);
    const columns = @min(@min(@max(needed, 1), fits), columns_max);
    // Share the entries out evenly rather than filling the first column to the
    // brim: a column break in the middle of a section reads as two sections.
    const balanced = @divFloor(entry_count + columns - 1, columns);
    const gaps = column_gap * (columns - 1);
    return .{
        .rows = @min(@max(balanced, 1), available),
        .columns = columns,
        .column_width = @divFloor(inner.width -| gaps, columns),
    };
}

pub fn mount(
    tree: *dom.DomTree,
    parent: NodeIndex,
    placement: Rect,
    sheet: Layout,
) !Slot {
    var slot = Slot{
        .mounted = true,
        .rows = sheet.rows,
        .columns = sheet.columns,
    };
    slot.shadow = try tree.append_child(parent, .{
        .kind = .panel,
        .props = .{ .panel = .{
            .chrome = .{ .rail_width = 0, .content_padding_left = 0 },
            .style = shadow_style(),
        } },
        .layout = LayoutElement.placed_free(
            placement.x + 1,
            placement.y + 1,
            placement.width,
            placement.height,
        ),
    });
    slot.panel = try tree.append_child(parent, .{
        .kind = .panel,
        .props = .{ .panel = .{
            .chrome = tokens.overlay_chrome,
            .style = theme.command_panel,
        } },
        .layout = LayoutElement.placed_free(
            placement.x,
            placement.y,
            placement.width,
            placement.height,
        ),
        .focused = true,
    });
    slot.first_row = tree.node_count;
    var column: u16 = 0;
    while (column < sheet.columns) : (column += 1) {
        const x = column * (sheet.column_width + column_gap);
        var row: u16 = 0;
        while (row < sheet.rows) : (row += 1) {
            // A key column and a label column, so headings and bindings line
            // up down the sheet rather than each row measuring itself.
            _ = try tree.append_child(slot.panel, .{
                .kind = .label,
                .props = .{ .label = .{} },
                .layout = LayoutElement.placed(x, row, label_column, 1),
            });
            _ = try tree.append_child(slot.panel, .{
                .kind = .label,
                .props = .{ .label = .{} },
                .layout = LayoutElement.placed(
                    x + label_column,
                    row,
                    sheet.column_width -| label_column,
                    1,
                ),
            });
        }
    }
    slot.row_count = sheet.cells();
    return slot;
}

/// Writes `shared` followed by `own` into the mounted rows.
pub fn update(
    tree: *dom.DomTree,
    slot: *const Slot,
    own: []const keymap.Entry,
    title: []const u8,
) void {
    if (!slot.mounted) return;
    tree.set_props(slot.panel, .{ .panel = .{
        .style = theme.command_panel,
        .chrome = tokens.overlay_chrome,
        .title = title,
        .meta = "? / ESC TO CLOSE",
    } });
    tree.set_props(slot.shadow, .{ .panel = .{
        .style = shadow_style(),
        .chrome = .{ .rail_width = 0, .content_padding_left = 0 },
    } });
    // Cells are mounted column by column, and entries fill them the same way,
    // so a section reads down a column before moving to the next.
    var cell: u16 = 0;
    while (cell < slot.row_count) : (cell += 1) {
        const entry = entry_at(own, cell);
        const key_node = slot.first_row + cell * 2;
        const label_node = key_node + 1;
        const value = entry orelse {
            tree.set_props(key_node, .{ .label = .{} });
            tree.set_props(label_node, .{ .label = .{} });
            continue;
        };
        tree.set_props(key_node, .{ .label = .{
            .text = value.key,
            .style = key_style(value.is_heading()),
        } });
        tree.set_props(label_node, .{ .label = .{
            .text = value.label,
            .style = theme.command_panel,
        } });
    }
}

fn entry_at(own: []const keymap.Entry, row: u16) ?keymap.Entry {
    if (row < keymap.shared.len) return keymap.shared[row];
    const index = row - keymap.shared.len;
    if (index >= own.len) return null;
    return own[index];
}

fn key_style(is_heading: bool) markix.Style {
    var style = theme.command_panel;
    style.foreground = if (is_heading) theme.command else theme.accent_warm;
    return style;
}

fn shadow_style() markix.Style {
    var style = theme.panel_style;
    style.background = theme.shadow;
    return style;
}

test "the sheet reads shared bindings before the experience's own" {
    try std.testing.expectEqualStrings(
        keymap.shared[0].key,
        entry_at(&keymap.reader, 0).?.key,
    );
    const first_own = entry_at(&keymap.reader, @intCast(keymap.shared.len)).?;
    try std.testing.expectEqualStrings(keymap.reader[0].key, first_own.key);
    try std.testing.expect(entry_at(&keymap.reader, rows_max) == null);
}
