const std = @import("std");

pub const Color = struct {
    kind: Kind = .none,
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,

    pub const Kind = enum(u8) {
        none,
        rgb,
        ansi,
        default,
    };

    pub fn rgb(hex: u24) Color {
        return .{
            .kind = .rgb,
            .r = @intCast((hex >> 16) & 0xff),
            .g = @intCast((hex >> 8) & 0xff),
            .b = @intCast(hex & 0xff),
        };
    }

    pub fn ansi(index: u8) Color {
        std.debug.assert(index < 16);
        return .{ .kind = .ansi, .r = index };
    }

    pub fn default() Color {
        return .{ .kind = .default };
    }

    pub fn is_set(self: Color) bool {
        return self.kind != .none;
    }

    pub fn value(self: Color) u24 {
        return (@as(u24, self.r) << 16) | (@as(u24, self.g) << 8) | self.b;
    }

    pub fn eql(self: Color, other: Color) bool {
        return self.kind == other.kind and
            self.r == other.r and self.g == other.g and self.b == other.b;
    }
};

pub const Style = struct {
    foreground: Color = .{},
    background: Color = .{},
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,

    pub const none: Style = .{};

    pub fn eql(self: Style, other: Style) bool {
        return self.foreground.eql(other.foreground) and
            self.background.eql(other.background) and
            self.bold == other.bold and
            self.dim == other.dim and
            self.italic == other.italic and
            self.underline == other.underline and
            self.strikethrough == other.strikethrough;
    }

    pub fn is_empty(self: Style) bool {
        return self.eql(none);
    }
};

test "colours compare by value" {
    try std.testing.expect(Color.rgb(0xc4a7e7).eql(Color.rgb(0xc4a7e7)));
    try std.testing.expect(!Color.rgb(0xc4a7e7).eql(Color.rgb(0x908caa)));
    try std.testing.expect(!Color.rgb(0).eql(Color{}));
    try std.testing.expectEqual(@as(u24, 0xc4a7e7), Color.rgb(0xc4a7e7).value());
}

test "an unset colour is not black" {
    try std.testing.expect(!(Color{}).is_set());
    try std.testing.expect(Color.rgb(0x000000).is_set());
}

test "styles compare structurally" {
    const heading = Style{ .foreground = Color.rgb(0xc4a7e7), .bold = true };
    try std.testing.expect(heading.eql(.{
        .foreground = Color.rgb(0xc4a7e7),
        .bold = true,
    }));
    try std.testing.expect(!heading.eql(.{ .foreground = Color.rgb(0xc4a7e7) }));
    try std.testing.expect(Style.none.is_empty());
    try std.testing.expect(!heading.is_empty());
}
