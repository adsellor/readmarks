const assert = @import("std").debug.assert;
const Surface = @import("surface.zig").Surface;
const Rect = @import("../layout/rect.zig").Rect;
const Style = @import("../style/style.zig").Style;
const Attributes = @import("../style/text_style.zig").Attributes;

pub const Chrome = struct {
    rail_width: u8 = 1,
    rail_height: u8 = 0,
    content_padding_left: u8 = 1,
    content_padding_top: u8 = 1,
    header_background: bool = false,
    title_attributes: Attributes = .{ .bold = true },
    meta_attributes: Attributes = .{ .dim = true },
    meta_padding_right: u8 = 1,
};

/// Inner box a panel paints its content into, given its outer rect.
///
/// Panel.draw returns this same rect, and the DOM tree lays a panel node's
/// children out inside it, so chrome insets stay defined in exactly one place.
pub fn content_rect(chrome: Chrome, rect: Rect) Rect {
    if (rect.width == 0 or rect.height == 0) return rect;
    const rail_width = @min(@as(u16, chrome.rail_width), rect.width);
    const header_width = rect.width - rail_width;
    const padding_left = @min(@as(u16, chrome.content_padding_left), header_width);
    const content_x = rect.x + rail_width + padding_left;
    const content_y = rect.y + @min(@as(u16, chrome.content_padding_top), rect.height);
    return Rect.init(
        content_x,
        content_y,
        rect.right() -| content_x,
        rect.y + rect.height -| content_y,
    );
}

pub const Panel = struct {
    title: []const u8 = "",
    meta: []const u8 = "",
    style: Style,
    focused: bool = false,
    chrome: Chrome = .{},

    pub fn draw(self: Panel, surface: Surface, rect: Rect) !Rect {
        assert(self.chrome.rail_width <= rect.width or rect.width == 0);
        assert(self.chrome.content_padding_top <= rect.height or rect.height == 0);
        if (rect.width == 0 or rect.height == 0) return rect;
        surface.fill(rect, self.style.background);
        const rail_width = @min(@as(u16, self.chrome.rail_width), rect.width);
        const rail_height = if (self.chrome.rail_height == 0)
            rect.height
        else
            @min(@as(u16, self.chrome.rail_height), rect.height);
        const rail_color = if (self.focused) self.style.accent else self.style.border;
        surface.fill(Rect.init(rect.x, rect.y, rail_width, rail_height), rail_color);
        const header_x = rect.x + rail_width;
        const header_width = rect.width - rail_width;
        if (self.chrome.header_background and header_width > 0) {
            surface.fill(
                Rect.init(header_x, rect.y, header_width, 1),
                self.style.selected_background,
            );
        }
        const padding_left = @min(@as(u16, self.chrome.content_padding_left), header_width);
        if (self.title.len > 0 and padding_left < header_width) {
            const title_rect = Rect.init(
                header_x + padding_left,
                rect.y,
                header_width - padding_left,
                1,
            );
            try surface.styled_text_in(
                title_rect,
                0,
                self.title,
                .{
                    .foreground = if (self.focused) self.style.accent else self.style.muted,
                    .background = if (self.chrome.header_background)
                        self.style.selected_background
                    else
                        self.style.background,
                    .attributes = self.chrome.title_attributes,
                },
            );
        }
        const padding_right = @min(
            @as(u16, self.chrome.meta_padding_right),
            header_width,
        );
        const meta_length: u16 = @intCast(@min(self.meta.len, header_width - padding_right));
        const meta_x = rect.right() - padding_right - meta_length;
        const title_length: u16 = @intCast(@min(self.title.len, header_width));
        const title_end = header_x + padding_left + title_length;
        if (meta_length > 0 and meta_x > title_end) {
            try surface.styled_text(
                meta_x,
                rect.y,
                self.meta[0..meta_length],
                .{
                    .foreground = self.style.muted,
                    .background = if (self.chrome.header_background)
                        self.style.selected_background
                    else
                        self.style.background,
                    .attributes = self.chrome.meta_attributes,
                },
            );
        }
        return content_rect(self.chrome, rect);
    }
};

test "panel draw returns the shared content rect" {
    const Canvas = @import("../backend/terminal/canvas.zig").TerminalCanvas;
    const Color = @import("../style/color.zig").Color;
    const std = @import("std");
    var canvas = try Canvas.init(std.testing.allocator, 30, 10);
    defer canvas.deinit();
    const chrome = Chrome{ .rail_width = 1, .content_padding_left = 2, .content_padding_top = 1 };
    const panel = Panel{
        .title = "Feeds",
        .style = Style.monochrome(
            Color.from_rgb(230, 230, 230),
            Color.from_rgb(20, 22, 24),
        ),
        .chrome = chrome,
    };
    const outer = Rect.init(0, 0, 30, 10);
    const returned = try panel.draw(.{ .canvas = &canvas }, outer);
    try std.testing.expectEqual(content_rect(chrome, outer), returned);
    try std.testing.expectEqual(Rect.init(3, 1, 27, 9), returned);
}

test "panel content rect collapses without dividing by zero" {
    const std = @import("std");
    const chrome = Chrome{ .rail_width = 4, .content_padding_left = 4 };
    const narrow = content_rect(chrome, Rect.init(0, 0, 2, 1));
    try std.testing.expectEqual(@as(u16, 0), narrow.width);
    const empty = content_rect(chrome, Rect.init(5, 5, 0, 0));
    try std.testing.expectEqual(Rect.init(5, 5, 0, 0), empty);
}
