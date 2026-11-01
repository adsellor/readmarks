const std = @import("std");

pub const Units = struct {
    width: u16 = 1,
    height: u16 = 1,

    pub const cell: Units = .{ .width = 1, .height = 1 };

    pub fn x(self: Units, logical: i32) i32 {
        return logical * @as(i32, self.width);
    }

    pub fn y(self: Units, logical: i32) i32 {
        return logical * @as(i32, self.height);
    }

    pub fn columns(self: Units, device: i32) i32 {
        std.debug.assert(self.width > 0);
        return @divTrunc(device, @as(i32, self.width));
    }

    pub fn rows(self: Units, device: i32) i32 {
        std.debug.assert(self.height > 0);
        return @divTrunc(device, @as(i32, self.height));
    }

    pub fn eql(self: Units, other: Units) bool {
        return self.width == other.width and self.height == other.height;
    }
};

test "a terminal's logical pixel is its cell" {
    try std.testing.expectEqual(@as(i32, 7), Units.cell.x(7));
    try std.testing.expectEqual(@as(i32, 7), Units.cell.y(7));
    try std.testing.expectEqual(@as(i32, 7), Units.cell.columns(7));
}

test "a page's logical pixel is nine across and thirty down" {
    const page = Units{ .width = 9, .height = 30 };
    try std.testing.expectEqual(@as(i32, 630), page.x(70));
    try std.testing.expectEqual(@as(i32, 180), page.y(6));
    try std.testing.expectEqual(@as(i32, 70), page.columns(630));
    try std.testing.expectEqual(@as(i32, 6), page.rows(180));
}

test "a box in one renderer's units, measured in another's" {
    const page = Units{ .width = 9, .height = 30 };
    const pixels = Units{ .width = 1, .height = 1 };
    try std.testing.expectEqual(@as(i32, 180), pixels.rows(page.y(6)));
    try std.testing.expectEqual(@as(i32, 6), Units.cell.rows(Units.cell.y(6)));
}
