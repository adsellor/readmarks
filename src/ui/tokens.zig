//! Design tokens: the chrome, row metrics and dialog geometry every component
//! is built from.

const std = @import("std");
const markix = @import("markix");
const widgets = markix.widgets;
const Rect = markix.layout.Rect;

pub const pane_chrome = widgets.PanelChrome{
    .rail_width = 1,
    .rail_height = 3,
    .content_padding_left = 1,
    .content_padding_top = 1,
    .header_background = false,
    .title_attributes = .{ .bold = true },
};

/// A strip of panel colour carrying the application's name and counts, with a
/// row underneath for the mode's controls.
pub const header_chrome = widgets.PanelChrome{
    .rail_width = 0,
    .rail_height = 0,
    .content_padding_left = 0,
    .content_padding_top = 1,
    .header_background = false,
    .title_attributes = .{ .bold = true },
};

/// Surfaces that float over the workspace: the command centre, the finder and
/// the help sheet. Deeper padding and a filled header row set them apart from
/// the panes they cover.
pub const overlay_chrome = widgets.PanelChrome{
    .rail_width = 1,
    .rail_height = 4,
    .content_padding_left = 2,
    // One row under the title bar, not two. A floating surface is usually the
    // shortest thing on screen, and a second blank row costs a result.
    .content_padding_top = 1,
    .header_background = true,
    .title_attributes = .{ .bold = true },
};

pub const form_chrome = widgets.PanelChrome{
    .rail_width = 1,
    .rail_height = 0,
    .content_padding_left = 2,
    .content_padding_top = 2,
    .header_background = true,
    .title_attributes = .{ .bold = true },
};

/// Rows that stand for a saved thing: an article, a bookmark, a command
/// result. Two rows, so a title carries a subtitle underneath it.
pub const item_list_visual = widgets.ListVisual{
    .row_height = 2,
    .selected_marker = '>',
    .title_attributes = .{ .bold = true },
    .selected_attributes = .{ .bold = true },
    .subtitle_attributes = .{ .dim = true },
    .detail_width_divisor = 3,
};

/// Rows that stand for a way of narrowing: a scope, a category, a feed.
pub const row_list_visual = widgets.ListVisual{
    .row_height = 1,
    .selected_marker = '>',
    .detail_width_divisor = 3,
};

/// Command results read like items, but the title is not bold: the fuzzy match
/// highlight is what the eye should catch.
pub const command_list_visual = blk: {
    var visual = item_list_visual;
    visual.title_attributes = .{};
    break :blk visual;
};

pub const status_visual = widgets.StatusVisual{
    .message_attributes = .{ .bold = true },
    .key_attributes = .{ .bold = true },
    .label_attributes = .{ .dim = true },
    .hint_gap = 2,
};

/// Geometry for a dialog floating over `bounds`: three quarters of the band it
/// covers, capped so it stays a dialog rather than a second full screen.
pub fn overlay_rect(bounds: Rect, width_max: u16, height_max: u16) Rect {
    const width_scaled = @divFloor(@as(u32, bounds.width) * 3, 4);
    const height_scaled = @divFloor(@as(u32, bounds.height) * 3, 4);
    const width = @min(@as(u16, @intCast(width_scaled)), width_max);
    const height = @min(@as(u16, @intCast(height_scaled)), height_max);
    return Rect.init(
        bounds.x + (bounds.width - width) / 2,
        bounds.y + (bounds.height - height) / 2,
        width,
        height,
    );
}

test "command results share the item row height" {
    try std.testing.expectEqual(
        item_list_visual.row_height,
        command_list_visual.row_height,
    );
    try std.testing.expectEqual(@as(u8, 1), row_list_visual.row_height);
}
