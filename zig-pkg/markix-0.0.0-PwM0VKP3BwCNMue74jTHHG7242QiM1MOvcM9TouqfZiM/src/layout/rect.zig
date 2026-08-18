const std = @import("std");

pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn init(x: u16, y: u16, width: u16, height: u16) Rect {
        return .{ .x = x, .y = y, .width = width, .height = height };
    }

    pub fn right(self: Rect) u16 {
        return @intCast(@as(u32, self.x) + self.width);
    }

    pub fn bottom(self: Rect) u16 {
        return @intCast(@as(u32, self.y) + self.height);
    }

    pub fn overlaps(self: Rect, other: Rect) bool {
        if (self.width == 0 or self.height == 0) return false;
        if (other.width == 0 or other.height == 0) return false;
        return self.x < other.right() and other.x < self.right() and
            self.y < other.bottom() and other.y < self.bottom();
    }

    pub fn inset(self: Rect, horizontal: u16, vertical: u16) Rect {
        const width = self.width -| @as(u16, horizontal *| 2);
        const height = self.height -| @as(u16, vertical *| 2);
        return .{
            .x = self.x + @min(horizontal, self.width),
            .y = self.y + @min(vertical, self.height),
            .width = width,
            .height = height,
        };
    }
};

test "rect inset saturates at empty" {
    const rect = Rect.init(4, 5, 3, 2).inset(2, 2);
    try std.testing.expectEqual(@as(u16, 0), rect.width);
    try std.testing.expectEqual(@as(u16, 0), rect.height);
    try std.testing.expectEqual(@as(u16, 6), rect.x);
    try std.testing.expectEqual(@as(u16, 7), rect.y);
}
