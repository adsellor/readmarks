const assert = @import("std").debug.assert;
const Rect = @import("../layout/rect.zig").Rect;
const Surface = @import("surface.zig").Surface;
const Badge = @import("badge.zig").Badge;
const BadgeStyle = @import("badge.zig").BadgeStyle;

pub const Item = struct {
    label: []const u8,
};

pub const Segmented = struct {
    active_style: BadgeStyle,
    idle_style: BadgeStyle,
    gap: u8 = 1,

    pub fn draw(
        self: Segmented,
        surface: Surface,
        rect: Rect,
        items: []const Item,
        selected: u16,
    ) !u16 {
        assert(rect.height > 0);
        assert(self.gap < rect.width or rect.width == 0);
        var column: u16 = 0;
        for (items, 0..) |item, index| {
            if (column >= rect.width) break;
            const style = if (index == selected)
                self.active_style
            else
                self.idle_style;
            const used = try (Badge{ .style = style }).draw(
                surface,
                Rect.init(rect.x + column, rect.y, rect.width - column, 1),
                item.label,
            );
            column += used;
            if (column < rect.width) {
                column += @min(@as(u16, self.gap), rect.width - column);
            }
        }
        return column;
    }
};
