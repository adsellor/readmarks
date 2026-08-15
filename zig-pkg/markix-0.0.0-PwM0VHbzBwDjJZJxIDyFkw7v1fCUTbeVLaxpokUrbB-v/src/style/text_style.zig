const Color = @import("color.zig").Color;

pub const Attributes = packed struct(u8) {
    bold: bool = false,
    dim: bool = false,
    underline: bool = false,
    reserved: u5 = 0,
};

pub const TextStyle = struct {
    foreground: Color,
    background: ?Color = null,
    attributes: Attributes = .{},
};
