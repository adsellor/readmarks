const std = @import("std");
const rect = @import("rect.zig");

pub const Edges = rect.Edges;

pub const Sizing = union(enum) {
    fit: Clamp,
    grow: Clamp,
    fixed: i32,
    percent: u16,

    pub const Clamp = struct {
        min: i32 = 0,
        max: i32 = std.math.maxInt(i32),
    };

    pub fn fit_content() Sizing {
        return .{ .fit = .{} };
    }

    pub fn grow_all() Sizing {
        return .{ .grow = .{} };
    }

    pub fn minimum(self: Sizing) i32 {
        return switch (self) {
            .fit => |clamp| clamp.min,
            .grow => |clamp| clamp.min,
            .fixed => |value| value,
            .percent => 0,
        };
    }

    pub fn maximum(self: Sizing) i32 {
        return switch (self) {
            .fit => |clamp| clamp.max,
            .grow => |clamp| clamp.max,
            .fixed => |value| value,
            .percent => std.math.maxInt(i32),
        };
    }
};

pub const Direction = enum { row, column };

pub const AlignX = enum { left, center, right };
pub const AlignY = enum { top, center, bottom };

pub const Alignment = struct {
    x: AlignX = .left,
    y: AlignY = .top,
};

pub const Layout = struct {
    width: Sizing = .{ .fit = .{} },
    height: Sizing = .{ .fit = .{} },
    padding: Edges = .{},
    gap: i32 = 0,
    direction: Direction = .row,
    alignment: Alignment = .{},

    pub fn size(self: Layout, axis: Direction) Sizing {
        return if (axis == .row) self.width else self.height;
    }
};
pub const Content = union(enum) {
    none: void,
    text: Text,
};

pub const Text = struct {
    value: []const u8,
    font: u16 = 0,
    wrap: bool = true,
};

test "sizing bounds" {
    try std.testing.expectEqual(@as(i32, 8), (Sizing{ .fixed = 8 }).minimum());
    try std.testing.expectEqual(@as(i32, 8), (Sizing{ .fixed = 8 }).maximum());
    try std.testing.expectEqual(@as(i32, 0), Sizing.fit_content().minimum());
    const clamped = Sizing{ .grow = .{ .min = 4, .max = 20 } };
    try std.testing.expectEqual(@as(i32, 4), clamped.minimum());
    try std.testing.expectEqual(@as(i32, 20), clamped.maximum());
}

test "layout reports the sizing for an axis" {
    const layout = Layout{
        .width = .{ .fixed = 10 },
        .height = .{ .grow = .{} },
    };
    try std.testing.expectEqual(@as(i32, 10), layout.size(.row).minimum());
    try std.testing.expect(layout.size(.column) == .grow);
}
