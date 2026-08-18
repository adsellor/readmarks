const std = @import("std");
const Color = @import("../style/color.zig").Color;
const Rect = @import("../layout/rect.zig").Rect;
const Surface = @import("surface.zig").Surface;
const Attributes = @import("../style/text_style.zig").Attributes;

pub const BadgeStyle = struct {
    foreground: Color,
    background: Color,
    attributes: Attributes = .{ .bold = true },
    padding: u8 = 1,

    /// Theme-neutral style usable as a field default, mirroring Style.plain.
    pub fn plain() BadgeStyle {
        return .{
            .foreground = Color.terminal_foreground(),
            .background = Color.terminal_background(),
        };
    }
};

pub const Badge = struct {
    style: BadgeStyle,

    pub fn draw(
        self: Badge,
        surface: Surface,
        rect: Rect,
        text: []const u8,
    ) !u16 {
        std.debug.assert(rect.height > 0);
        std.debug.assert(self.style.padding <= rect.width or rect.width == 0);
        if (rect.width == 0 or rect.height == 0) return 0;
        const padding = @min(@as(u16, self.style.padding), rect.width);
        const text_width = rect.width -| padding *| 2;
        const length: u16 = @intCast(@min(text.len, text_width));
        const width = @min(rect.width, length + padding *| 2);
        surface.fill(Rect.init(rect.x, rect.y, width, 1), self.style.background);
        if (length > 0) {
            try surface.styled_text(
                rect.x + padding,
                rect.y,
                text[0..length],
                .{
                    .foreground = self.style.foreground,
                    .background = self.style.background,
                    .attributes = self.style.attributes,
                },
            );
        }
        return width;
    }
};
