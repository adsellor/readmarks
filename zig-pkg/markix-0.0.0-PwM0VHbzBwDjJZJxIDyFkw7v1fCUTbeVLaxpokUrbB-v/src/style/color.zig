pub const Color = struct {
    kind: Kind,
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub const Kind = enum(u8) {
        rgb,
        ansi,
        terminal_foreground,
        terminal_background,
        transparent,
    };

    pub fn from_rgb(red: u8, green: u8, blue: u8) Color {
        return .{ .kind = .rgb, .r = red, .g = green, .b = blue };
    }

    pub fn from_rgba(red: u8, green: u8, blue: u8, alpha: u8) Color {
        if (alpha == 0) {
            return .{
                .kind = .transparent,
                .r = 0,
                .g = 0,
                .b = 0,
                .a = 0,
            };
        }
        return .{ .kind = .rgb, .r = red, .g = green, .b = blue, .a = alpha };
    }

    pub fn ansi(index: u8) Color {
        std.debug.assert(index < 16);
        return .{ .kind = .ansi, .r = index, .g = 0, .b = 0 };
    }

    pub fn terminal_foreground() Color {
        return .{
            .kind = .terminal_foreground,
            .r = 0,
            .g = 0,
            .b = 0,
        };
    }

    pub fn terminal_background() Color {
        return .{
            .kind = .terminal_background,
            .r = 0,
            .g = 0,
            .b = 0,
        };
    }

    pub fn equals(self: Color, other: Color) bool {
        return self.kind == other.kind and
            self.r == other.r and
            self.g == other.g and
            self.b == other.b and
            self.a == other.a;
    }
};

const std = @import("std");

test "terminal and ANSI colors remain distinct from RGB colors" {
    const foreground = Color.terminal_foreground();
    const background = Color.terminal_background();
    const cyan = Color.ansi(6);
    try std.testing.expect(!foreground.equals(background));
    try std.testing.expect(!cyan.equals(Color.from_rgb(0, 255, 255)));
}
