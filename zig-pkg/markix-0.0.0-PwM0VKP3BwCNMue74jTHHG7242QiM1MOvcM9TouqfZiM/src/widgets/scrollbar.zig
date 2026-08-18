const std = @import("std");
const Color = @import("../style/color.zig").Color;
const Rect = @import("../layout/rect.zig").Rect;
const Surface = @import("surface.zig").Surface;

pub const ScrollbarStyle = struct {
    track_foreground: Color,
    track_background: ?Color = null,
    thumb_foreground: Color,
    thumb_background: ?Color = null,
    track_character: u8 = '.',
    thumb_character: u8 = '#',
};

pub const Scrollbar = struct {
    style: ScrollbarStyle,

    pub fn draw(
        self: Scrollbar,
        surface: Surface,
        rect: Rect,
        position: u16,
        total: u16,
        viewport: u16,
    ) !void {
        std.debug.assert(rect.width > 0 or rect.height == 0);
        if (rect.width == 0 or rect.height == 0) return;
        const geometry = thumb_geometry(rect.height, position, total, viewport);
        std.debug.assert(geometry.start + geometry.size <= rect.height);
        var row: u16 = 0;
        while (row < rect.height) : (row += 1) {
            const thumb = row >= geometry.start and row < geometry.start + geometry.size;
            try surface.text(
                rect.x,
                rect.y + row,
                if (thumb) &.{self.style.thumb_character} else &.{self.style.track_character},
                if (thumb) self.style.thumb_foreground else self.style.track_foreground,
                if (thumb) self.style.thumb_background else self.style.track_background,
            );
        }
    }
};

const ThumbGeometry = struct {
    start: u16,
    size: u16,
};

fn thumb_geometry(
    height: u16,
    position: u16,
    total: u16,
    viewport: u16,
) ThumbGeometry {
    std.debug.assert(height > 0);
    std.debug.assert(position <= total or total == 0);
    if (total <= viewport or total == 0) return .{ .start = 0, .size = height };
    const size: u16 = @intCast(@max(
        @as(u32, 1),
        @divFloor(@as(u32, viewport) * height, total),
    ));
    const travel = height - size;
    const maximum = total - viewport;
    const start: u16 = @intCast(@divFloor(
        @as(u32, @min(position, maximum)) * travel,
        maximum,
    ));
    return .{ .start = start, .size = size };
}

test "scrollbar thumb geometry is bounded at both ends" {
    try std.testing.expectEqual(ThumbGeometry{ .start = 0, .size = 2 }, thumb_geometry(
        10,
        0,
        50,
        10,
    ));
    try std.testing.expectEqual(ThumbGeometry{ .start = 8, .size = 2 }, thumb_geometry(
        10,
        40,
        50,
        10,
    ));
}
