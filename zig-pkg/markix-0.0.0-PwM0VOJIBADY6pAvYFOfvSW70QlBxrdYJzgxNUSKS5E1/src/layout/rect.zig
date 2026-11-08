const std = @import("std");

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,

    pub fn init(x: i32, y: i32, width: i32, height: i32) Rect {
        return .{ .x = x, .y = y, .width = width, .height = height };
    }

    pub fn right(self: Rect) i32 {
        return self.x + self.width;
    }

    pub fn bottom(self: Rect) i32 {
        return self.y + self.height;
    }

    pub fn contains(self: Rect, x: i32, y: i32) bool {
        return x >= self.x and x < self.right() and
            y >= self.y and y < self.bottom();
    }

    pub fn overlaps(self: Rect, other: Rect) bool {
        if (self.width <= 0 or self.height <= 0) return false;
        if (other.width <= 0 or other.height <= 0) return false;
        return self.x < other.right() and other.x < self.right() and
            self.y < other.bottom() and other.y < self.bottom();
    }
};

pub const Edges = struct {
    left: i32 = 0,
    right: i32 = 0,
    top: i32 = 0,
    bottom: i32 = 0,

    pub fn all(value: i32) Edges {
        return .{ .left = value, .right = value, .top = value, .bottom = value };
    }

    pub fn symmetric(across: i32, down: i32) Edges {
        return .{
            .left = across,
            .right = across,
            .top = down,
            .bottom = down,
        };
    }

    pub fn horizontal(self: Edges) i32 {
        return self.left + self.right;
    }

    pub fn vertical(self: Edges) i32 {
        return self.top + self.bottom;
    }
};

test "rect geometry" {
    const rect = Rect.init(2, 3, 4, 5);
    try std.testing.expectEqual(@as(i32, 6), rect.right());
    try std.testing.expectEqual(@as(i32, 8), rect.bottom());
    try std.testing.expect(rect.contains(2, 3));
    try std.testing.expect(!rect.contains(6, 3));
}

test "empty rects never overlap" {
    const empty = Rect.init(0, 0, 0, 4);
    try std.testing.expect(!empty.overlaps(Rect.init(0, 0, 4, 4)));
}

test "edges sum per axis" {
    try std.testing.expectEqual(@as(i32, 4), Edges.all(2).horizontal());
    try std.testing.expectEqual(@as(i32, 6), Edges.symmetric(1, 3).vertical());
}
