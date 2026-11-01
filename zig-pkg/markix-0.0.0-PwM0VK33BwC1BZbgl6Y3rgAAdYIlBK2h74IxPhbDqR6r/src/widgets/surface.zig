const std = @import("std");
const TerminalCanvas = @import("../backend/terminal/canvas.zig").TerminalCanvas;
const Color = @import("../style/color.zig").Color;
const Rect = @import("../layout/rect.zig").Rect;
const TextSelectionStyle = @import("../style/style.zig").TextSelectionStyle;
const Attributes = @import("../style/text_style.zig").Attributes;
const TextStyle = @import("../style/text_style.zig").TextStyle;
const text_measure = @import("../layout/text_measure.zig");

pub const Surface = struct {
    canvas: *TerminalCanvas,
    text_occlusion: ?*const Rect = null,

    pub fn bounds(self: Surface) Rect {
        return Rect.init(
            0,
            0,
            self.canvas.width,
            @divFloor(self.canvas.height + 1, 2),
        );
    }

    pub fn with_text_occlusion(
        self: Surface,
        rect: *const Rect,
    ) Surface {
        return .{
            .canvas = self.canvas,
            .text_occlusion = rect,
        };
    }

    pub fn fill(self: Surface, rect: Rect, color: Color) void {
        const canvas_bounds = self.bounds();
        if (rect.x >= canvas_bounds.width or rect.y >= canvas_bounds.height) return;
        const width = @min(rect.width, canvas_bounds.width - rect.x);
        const height = @min(rect.height, canvas_bounds.height - rect.y);
        self.canvas.filled_rect(
            rect.x,
            rect.y * 2,
            width,
            height * 2,
            color,
        );
    }

    pub fn selectable(
        self: Surface,
        rect: Rect,
        style: TextSelectionStyle,
    ) !void {
        std.debug.assert(rect.width > 0 or rect.height == 0);
        std.debug.assert(self.canvas.width > 0);
        const canvas_bounds = self.bounds();
        if (rect.x >= canvas_bounds.width or rect.y >= canvas_bounds.height) return;
        const clipped = Rect.init(
            rect.x,
            rect.y,
            @min(rect.width, canvas_bounds.width - rect.x),
            @min(rect.height, canvas_bounds.height - rect.y),
        );
        if (clipped.width == 0 or clipped.height == 0) return;
        try self.canvas.add_selection_region(clipped, style);
    }

    pub fn text(
        self: Surface,
        x: u16,
        y: u16,
        value: []const u8,
        foreground: Color,
        background: ?Color,
    ) !void {
        std.debug.assert(value.len <= std.math.maxInt(u16));
        std.debug.assert(self.canvas.width > 0);
        const canvas_bounds = self.bounds();
        if (x >= canvas_bounds.width or y >= canvas_bounds.height) return;
        const visible_length = @min(value.len, canvas_bounds.width - x);
        if (visible_length == 0) return;
        try self.add_visible_text(
            x,
            y,
            value[0..visible_length],
            foreground,
            background,
            .{},
        );
    }

    pub fn styled_text(
        self: Surface,
        x: u16,
        y: u16,
        value: []const u8,
        style: TextStyle,
    ) !void {
        std.debug.assert(value.len <= std.math.maxInt(u16));
        std.debug.assert(self.canvas.width > 0);
        const canvas_bounds = self.bounds();
        if (x >= canvas_bounds.width or y >= canvas_bounds.height) return;
        const visible_length = @min(value.len, canvas_bounds.width - x);
        if (visible_length == 0) return;
        try self.add_visible_text(
            x,
            y,
            value[0..visible_length],
            style.foreground,
            style.background,
            style.attributes,
        );
    }

    fn add_visible_text(
        self: Surface,
        x: u16,
        y: u16,
        value: []const u8,
        foreground: Color,
        background: ?Color,
        attributes: Attributes,
    ) !void {
        std.debug.assert(value.len <= std.math.maxInt(u16));
        std.debug.assert(self.canvas.width > 0);
        const occlusion = self.text_occlusion orelse {
            try self.canvas.add_styled_text(
                x,
                y,
                value,
                foreground,
                background,
                attributes,
            );
            return;
        };
        if (!row_intersects(occlusion.*, y, x, value.len)) {
            try self.canvas.add_styled_text(
                x,
                y,
                value,
                foreground,
                background,
                attributes,
            );
            return;
        }
        try self.add_text_around_occlusion(
            occlusion.*,
            x,
            y,
            value,
            foreground,
            background,
            attributes,
        );
    }

    fn add_text_around_occlusion(
        self: Surface,
        occlusion: Rect,
        x: u16,
        y: u16,
        value: []const u8,
        foreground: Color,
        background: ?Color,
        attributes: Attributes,
    ) !void {
        std.debug.assert(value.len <= std.math.maxInt(u16));
        std.debug.assert(self.canvas.width > 0);
        if (x < occlusion.x) {
            const left_length = @min(value.len, occlusion.x - x);
            try self.canvas.add_styled_text(
                x,
                y,
                value[0..left_length],
                foreground,
                background,
                attributes,
            );
        }
        const value_end = @as(u32, x) + @as(u32, @intCast(value.len));
        if (value_end <= occlusion.right()) return;
        const right_x = @max(x, occlusion.right());
        const right_offset = right_x - x;
        try self.canvas.add_styled_text(
            right_x,
            y,
            value[right_offset..],
            foreground,
            background,
            attributes,
        );
    }

    pub fn styled_text_in(
        self: Surface,
        rect: Rect,
        row: u16,
        value: []const u8,
        style: TextStyle,
    ) !void {
        if (row >= rect.height or rect.width == 0) return;
        const visible_length = @min(value.len, rect.width);
        if (visible_length == 0) return;
        try self.styled_text(rect.x, rect.y + row, value[0..visible_length], style);
    }

    pub fn text_in(
        self: Surface,
        rect: Rect,
        row: u16,
        value: []const u8,
        foreground: Color,
        background: ?Color,
    ) !void {
        std.debug.assert(row <= rect.height or rect.height == 0);
        std.debug.assert(value.len <= std.math.maxInt(u16));
        if (row >= rect.height or rect.width == 0) return;
        const visible_length = @min(value.len, rect.width);
        if (visible_length == 0) return;
        try self.text(
            rect.x,
            rect.y + row,
            value[0..visible_length],
            foreground,
            background,
        );
    }

    pub fn horizontal_rule(
        self: Surface,
        rect: Rect,
        row: u16,
        color: Color,
    ) !void {
        if (row >= rect.height) return;
        const buffer: [512]u8 = @splat('-');
        const length = @min(rect.width, buffer.len);
        try self.text(rect.x, rect.y + row, buffer[0..length], color, null);
    }

    pub fn wrapped_text(
        self: Surface,
        rect: Rect,
        value: []const u8,
        foreground: Color,
        background: ?Color,
    ) !u16 {
        std.debug.assert(rect.width > 0 or rect.height == 0);
        std.debug.assert(value.len <= std.math.maxInt(u16));
        if (rect.width == 0 or rect.height == 0) return 0;
        // Breaks come from the shared measurer, so the rows painted here are
        // exactly the rows layout reserved for this text.
        var offset: usize = 0;
        var row: u16 = 0;
        while (offset < value.len and row < rect.height) : (row += 1) {
            const line = text_measure.next_line(value, offset, rect.width);
            try self.text_in(rect, row, line.text, foreground, background);
            offset = line.next;
        }
        return row;
    }
};

fn row_intersects(
    rect: Rect,
    y: u16,
    x: u16,
    text_length: usize,
) bool {
    if (rect.width == 0 or rect.height == 0) return false;
    if (y < rect.y or y >= rect.y + rect.height) return false;
    const text_end = @as(u32, x) + @as(u32, @intCast(text_length));
    if (text_end <= rect.x) return false;
    return x < rect.right();
}

test "surface bounds use terminal rows" {
    var canvas = try TerminalCanvas.init(std.testing.allocator, 40, 20);
    defer canvas.deinit();
    const surface = Surface{ .canvas = &canvas };
    try std.testing.expectEqual(Rect.init(0, 0, 40, 10), surface.bounds());
}

test "text occlusion splits entries around an overlay" {
    var canvas = try TerminalCanvas.init(std.testing.allocator, 16, 4);
    defer canvas.deinit();
    const occlusion = Rect.init(3, 0, 4, 2);
    const surface = (Surface{ .canvas = &canvas }).with_text_occlusion(&occlusion);
    const foreground = Color.from_rgb(230, 230, 230);
    try surface.text(0, 0, "abcdefghij", foreground, null);
    try std.testing.expectEqual(@as(usize, 2), canvas.text_entries.items.len);
    try std.testing.expectEqualStrings("abc", canvas.text_entries.items[0].bytes());
    try std.testing.expectEqual(@as(u16, 0), canvas.text_entries.items[0].x);
    try std.testing.expectEqualStrings("hij", canvas.text_entries.items[1].bytes());
    try std.testing.expectEqual(@as(u16, 7), canvas.text_entries.items[1].x);
}
