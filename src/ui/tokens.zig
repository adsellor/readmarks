const std = @import("std");
const Rect = @import("node.zig").Rect;

pub const Chrome = struct {
    rail_width: u8 = 1,
    rail_height: u8 = 0,
    padding_left: u8 = 1,
    padding_top: u8 = 1,
    header_background: bool = false,
};

pub const pane_chrome = Chrome{ .rail_width = 1, .rail_height = 3 };

pub const header_chrome = Chrome{ .rail_width = 0, .padding_left = 0 };

pub const overlay_chrome = Chrome{
    .rail_width = 1,
    .rail_height = 4,
    .padding_left = 2,
    .header_background = true,
};

pub const form_chrome = Chrome{
    .rail_width = 1,
    .padding_left = 2,
    .padding_top = 2,
    .header_background = true,
};

pub const Visual = struct {
    row_height: u8 = 1,
    selected_marker: []const u8 = ">",
    title_bold: bool = false,
    detail_width_divisor: u8 = 3,
    title_column: u8 = 3,
};

pub const item_list_visual = Visual{ .row_height = 2, .title_bold = true };

pub const row_list_visual = Visual{ .row_height = 1 };

pub const command_list_visual = Visual{ .row_height = 2 };

pub const hint_gap: u8 = 2;

pub fn overlay_rect(bounds: Rect, width_max: i32, height_max: i32) Rect {
    std.debug.assert(width_max > 0);
    std.debug.assert(height_max > 0);
    const width = @min(@divFloor(bounds.width * 3, 4), width_max);
    const height = @min(@divFloor(bounds.height * 3, 4), height_max);
    return Rect.init(
        bounds.x + @divFloor(bounds.width - width, 2),
        bounds.y + @divFloor(bounds.height - height, 2),
        width,
        height,
    );
}

pub fn content_rect(chrome: Chrome, rect: Rect) Rect {
    if (rect.width <= 0 or rect.height <= 0) return rect;
    const rail = @min(@as(i32, chrome.rail_width), rect.width);
    const padding = @min(@as(i32, chrome.padding_left), rect.width - rail);
    const x = rect.x + rail + padding;
    const y = rect.y + @min(@as(i32, chrome.padding_top), rect.height);
    return Rect.init(x, y, @max(0, rect.right() - x), @max(0, rect.bottom() - y));
}

test "command results share the item row height" {
    try std.testing.expectEqual(item_list_visual.row_height, command_list_visual.row_height);
    try std.testing.expectEqual(@as(u8, 1), row_list_visual.row_height);
}

test "an overlay takes three quarters of its band, capped" {
    const rect = overlay_rect(Rect.init(0, 2, 200, 40), 84, 17);
    try std.testing.expectEqual(@as(i32, 84), rect.width);
    try std.testing.expectEqual(@as(i32, 17), rect.height);
    try std.testing.expectEqual(@as(i32, 58), rect.x);
    const inner = content_rect(overlay_chrome, rect);
    try std.testing.expectEqual(rect.x + 3, inner.x);
    try std.testing.expectEqual(rect.y + 1, inner.y);
}
