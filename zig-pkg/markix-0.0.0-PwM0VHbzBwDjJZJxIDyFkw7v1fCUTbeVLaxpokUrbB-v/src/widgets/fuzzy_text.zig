const assert = @import("std").debug.assert;
const maxInt = @import("std").math.maxInt;
const fuzzy = @import("../utils/fuzzy.zig");
const limits = @import("../backend/terminal/limits.zig");
const Rect = @import("../layout/rect.zig").Rect;
const Surface = @import("surface.zig").Surface;
const TextStyle = @import("../style/text_style.zig").TextStyle;
const text_width = @import("../backend/terminal/text_width.zig");

pub const FuzzyText = struct {
    query: []const u8,
    style: TextStyle,
    match_style: TextStyle,

    pub fn draw(
        self: FuzzyText,
        surface: Surface,
        rect: Rect,
        text: []const u8,
    ) !void {
        assert(rect.height > 0);
        assert(text.len <= maxInt(u16));
        if (rect.width == 0 or rect.height == 0) return;
        const visible = text_width.clip(text, rect.width);
        if (visible.len == 0) return;
        var match_mask: [limits.text_bytes_max]bool = undefined;
        if (!fuzzy.mark_matches(visible, self.query, &match_mask)) {
            try surface.styled_text_in(rect, 0, visible, self.style);
            return;
        }
        try draw_runs(
            surface,
            rect,
            visible,
            match_mask[0..visible.len],
            self.style,
            self.match_style,
        );
    }
};

fn draw_runs(
    surface: Surface,
    rect: Rect,
    text: []const u8,
    match_mask: []const bool,
    style: TextStyle,
    match_style: TextStyle,
) !void {
    assert(rect.height > 0);
    assert(match_mask.len >= text.len);
    var start: u16 = 0;
    while (start < text.len) {
        const matched = match_mask[start];
        var end = start + 1;
        while (end < text.len and match_mask[end] == matched) : (end += 1) {}
        try surface.styled_text(
            rect.x + start,
            rect.y,
            text[start..end],
            if (matched) match_style else style,
        );
        start = end;
    }
}

test "fuzzy text emits independent style runs" {
    const std = @import("std");
    const Canvas = @import("../backend/terminal/canvas.zig").TerminalCanvas;
    const Color = @import("../style/color.zig").Color;
    var canvas = try Canvas.init(std.testing.allocator, 20, 4);
    defer canvas.deinit();
    const idle = Color.from_rgb(180, 180, 180);
    const accent = Color.from_rgb(80, 220, 170);
    try (FuzzyText{
        .query = "tgs",
        .style = .{ .foreground = idle },
        .match_style = .{
            .foreground = accent,
            .attributes = .{ .bold = true, .underline = true },
        },
    }).draw(.{ .canvas = &canvas }, Rect.init(1, 1, 12, 1), "TigerStyle");
    try std.testing.expectEqual(@as(usize, 6), canvas.text_entries.items.len);
    try std.testing.expectEqualStrings("T", canvas.text_entries.items[0].bytes());
    try std.testing.expectEqualStrings("g", canvas.text_entries.items[2].bytes());
    try std.testing.expectEqualStrings("S", canvas.text_entries.items[4].bytes());
}
