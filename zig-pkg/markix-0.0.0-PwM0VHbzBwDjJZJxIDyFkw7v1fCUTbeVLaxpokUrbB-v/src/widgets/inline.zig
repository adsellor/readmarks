const assert = @import("std").debug.assert;
const Color = @import("../style/color.zig").Color;
const Rect = @import("../layout/rect.zig").Rect;
const Surface = @import("surface.zig").Surface;
const Attributes = @import("../style/text_style.zig").Attributes;

pub const Span = struct {
    text: []const u8,
    foreground: Color,
    background: ?Color = null,
    attributes: Attributes = .{},
};

pub const Inline = struct {
    pub fn draw(
        surface: Surface,
        rect: Rect,
        spans: []const Span,
    ) !u16 {
        assert(rect.height > 0);
        assert(spans.len <= 4096);
        if (rect.width == 0 or rect.height == 0) return 0;
        var column: u16 = 0;
        for (spans) |span| {
            if (column >= rect.width) break;
            const available = rect.width - column;
            const length: u16 = @intCast(@min(span.text.len, available));
            if (length == 0) continue;
            try surface.styled_text(
                rect.x + column,
                rect.y,
                span.text[0..length],
                .{
                    .foreground = span.foreground,
                    .background = span.background,
                    .attributes = span.attributes,
                },
            );
            column += length;
        }
        return column;
    }
};

test "inline spans retain independent styles and stable positions" {
    const std = @import("std");
    const Canvas = @import("../backend/terminal/canvas.zig").TerminalCanvas;
    var canvas = try Canvas.init(std.testing.allocator, 20, 4);
    defer canvas.deinit();
    const surface = Surface{ .canvas = &canvas };
    const foreground = Color.from_rgb(230, 230, 230);
    const accent = Color.from_rgb(80, 200, 170);
    _ = try Inline.draw(surface, Rect.init(2, 1, 12, 1), &.{
        .{ .text = "KEY", .foreground = accent },
        .{ .text = " value", .foreground = foreground },
    });
    try std.testing.expectEqual(@as(usize, 2), canvas.text_entries.items.len);
    try std.testing.expectEqual(@as(u16, 2), canvas.text_entries.items[0].x);
    try std.testing.expectEqual(@as(u16, 5), canvas.text_entries.items[1].x);
    try std.testing.expectEqualStrings("KEY", canvas.text_entries.items[0].bytes());
    try std.testing.expectEqualStrings(" value", canvas.text_entries.items[1].bytes());
}
