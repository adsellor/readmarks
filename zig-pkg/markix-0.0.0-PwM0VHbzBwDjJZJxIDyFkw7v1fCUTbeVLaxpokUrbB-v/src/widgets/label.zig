const Surface = @import("surface.zig").Surface;
const Rect = @import("../layout/rect.zig").Rect;
const Style = @import("../style/style.zig").Style;

pub const Label = struct {
    text: []const u8,
    style: Style,
    muted: bool = false,
    /// Flow the text across the rect's rows. The layout's measure pass uses
    /// the same setting to decide how many rows to reserve.
    wrap: bool = false,

    pub fn draw(self: Label, surface: Surface, rect: Rect) !void {
        if (rect.width == 0 or rect.height == 0) return;
        const foreground = if (self.muted) self.style.muted else self.style.foreground;
        if (self.wrap) {
            _ = try surface.wrapped_text(rect, self.text, foreground, self.style.background);
            return;
        }
        try surface.text_in(rect, 0, self.text, foreground, self.style.background);
    }
};
