const std = @import("std");
const limits = @import("limits.zig");
const Color = @import("../../style/color.zig").Color;
const Attributes = @import("../../style/text_style.zig").Attributes;

pub const TextEntry = struct {
    x: u16,
    y: u16,
    text: [limits.text_bytes_max]u8 = undefined,
    text_length: u16,
    foreground_color: Color,
    background_color: ?Color = null,
    attributes: Attributes = .{},

    pub fn bytes(self: *const TextEntry) []const u8 {
        return self.text[0..self.text_length];
    }

    pub fn equals(self: *const TextEntry, other: *const TextEntry) bool {
        const transparent = Color.from_rgba(0, 0, 0, 0);
        const self_background = self.background_color orelse transparent;
        const other_background = other.background_color orelse transparent;

        return self.x == other.x and
            self.y == other.y and
            self.foreground_color.equals(other.foreground_color) and
            self_background.equals(other_background) and
            self.attributes == other.attributes and
            std.mem.eql(u8, self.bytes(), other.bytes());
    }
};
