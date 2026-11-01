const std = @import("std");
const markix = @import("markix");

pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    width: u16 = 0,
    height: u16 = 0,

    pub fn init(x: u16, y: u16, width: u16, height: u16) Rect {
        return .{ .x = x, .y = y, .width = width, .height = height };
    }

    pub fn right(self: Rect) u16 {
        return self.x +| self.width;
    }

    pub fn bottom(self: Rect) u16 {
        return self.y +| self.height;
    }

    pub fn from(rect: markix.Rect) Rect {
        const x = clamp(rect.x);
        const y = clamp(rect.y);
        return .{
            .x = x,
            .y = y,
            .width = clamp(rect.right()) -| x,
            .height = clamp(rect.bottom()) -| y,
        };
    }

    pub fn wide(self: Rect) markix.Rect {
        return markix.Rect.init(self.x, self.y, self.width, self.height);
    }
};

fn clamp(value: i32) u16 {
    return @intCast(std.math.clamp(value, 0, std.math.maxInt(u16)));
}

test "a rect hanging off the screen keeps only its visible part" {
    const rect = Rect.from(markix.Rect.init(-2, 3, 10, 4));
    try std.testing.expectEqual(Rect.init(0, 3, 8, 4), rect);
    try std.testing.expectEqual(@as(u16, 8), rect.right());
    try std.testing.expectEqual(markix.Rect.init(0, 3, 8, 4), rect.wide());
}
