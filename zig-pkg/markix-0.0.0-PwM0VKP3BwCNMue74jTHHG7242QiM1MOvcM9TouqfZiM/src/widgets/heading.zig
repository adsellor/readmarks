const std = @import("std");
const Surface = @import("surface.zig").Surface;
const Rect = @import("../layout/rect.zig").Rect;
const Style = @import("../style/style.zig").Style;
const Attributes = @import("../style/text_style.zig").Attributes;
const text_measure = @import("../layout/text_measure.zig");

// A section heading: a marker, the text, and an optional rule beneath it.
//
// Kept as a widget rather than a styled label because a heading carries a
// level, and the level decides its marker, its weight and whether it is
// underlined. Both renderers read that from one place.

pub const level_max: u8 = 6;

pub const Visual = struct {
    /// Repeated once per level to form the marker, as in `##`.
    marker: u8 = '#',
    /// Levels at or above this get no marker.
    marker_level_max: u8 = 4,
    /// Levels at or below this are underlined.
    rule_level_max: u8 = 2,
    rule_character: u8 = '-',
    gap: u8 = 1,
    attributes: Attributes = .{ .bold = true },
};

pub const Heading = struct {
    text: []const u8,
    level: u8,
    style: Style,
    visual: Visual = .{},

    /// Rows the heading occupies, its rule included.
    pub fn rows(self: Heading, width: u16) u16 {
        std.debug.assert(self.level <= level_max);
        // A rect narrower than the marker is legitimate; the text simply has
        // no room, and the saturating subtraction leaves it a single row.
        const marker_columns = self.indent();
        const text_rows = text_measure.wrapped_rows(self.text, width -| marker_columns);
        std.debug.assert(text_rows > 0);
        std.debug.assert(text_rows <= std.math.maxInt(u16) - @as(u16, level_max));
        return text_rows + self.rule_rows();
    }

    pub fn rule_rows(self: Heading) u16 {
        std.debug.assert(self.level <= level_max);
        if (self.level > self.visual.rule_level_max) return 0;
        return 1;
    }

    /// Columns the marker and its gap occupy.
    pub fn indent(self: Heading) u16 {
        std.debug.assert(self.level <= level_max);
        if (self.level > self.visual.marker_level_max) return 0;
        if (self.level == 0) return 0;
        return @as(u16, self.level) + self.visual.gap;
    }

    pub fn draw(self: Heading, surface: Surface, rect: Rect) !void {
        std.debug.assert(self.level <= 6);
        std.debug.assert(self.level <= level_max);
        if (rect.width == 0) return;
        if (rect.height == 0) return;
        try self.draw_marker(surface, rect);
        const marker_columns = self.indent();
        if (marker_columns >= rect.width) return;
        const body = Rect.init(
            rect.x + marker_columns,
            rect.y,
            rect.width - marker_columns,
            rect.height,
        );
        const used = try surface.wrapped_text(
            body,
            self.text,
            self.style.foreground,
            self.style.background,
        );
        try self.draw_rule(surface, rect, used);
    }

    fn draw_marker(self: Heading, surface: Surface, rect: Rect) !void {
        if (self.indent() == 0) return;
        std.debug.assert(self.level > 0);
        var buffer: [level_max]u8 = @splat(self.visual.marker);
        try surface.text(
            rect.x,
            rect.y,
            buffer[0..self.level],
            self.style.muted,
            self.style.background,
        );
    }

    fn draw_rule(self: Heading, surface: Surface, rect: Rect, used: u16) !void {
        if (self.rule_rows() == 0) return;
        if (used >= rect.height) return;
        try surface.horizontal_rule(rect, used, self.style.border);
    }
};

test "a heading measures its text and its rule" {
    const style = Style.plain();
    const first = Heading{ .text = "Introduction", .level = 2, .style = style };
    // Two columns of marker plus a gap, then the text, then the rule row.
    try std.testing.expectEqual(@as(u16, 3), first.indent());
    try std.testing.expectEqual(@as(u16, 1), first.rule_rows());
    try std.testing.expectEqual(@as(u16, 2), first.rows(40));
}

test "deeper levels drop the marker and the rule" {
    const style = Style.plain();
    const deep = Heading{ .text = "Detail", .level = 5, .style = style };
    try std.testing.expectEqual(@as(u16, 0), deep.indent());
    try std.testing.expectEqual(@as(u16, 0), deep.rule_rows());
    try std.testing.expectEqual(@as(u16, 1), deep.rows(40));
}

test "a heading that wraps counts every row" {
    const style = Style.plain();
    const long = Heading{
        .text = "A heading long enough that it has to wrap across rows",
        .level = 3,
        .style = style,
    };
    try std.testing.expect(long.rows(20) > 2);
}

test "a narrow rect neither underflows nor draws" {
    const Canvas = @import("../backend/terminal/canvas.zig").TerminalCanvas;
    var canvas = try Canvas.init(std.testing.allocator, 20, 4);
    defer canvas.deinit();
    const heading = Heading{ .text = "Title", .level = 2, .style = Style.plain() };
    try heading.draw(.{ .canvas = &canvas }, Rect.init(0, 0, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), canvas.text_entries.items.len);
    // Narrower than its own marker: one row of text with nowhere to put it,
    // plus the rule this level always carries.
    try std.testing.expectEqual(@as(u16, 2), heading.rows(2));
}

test "a heading draws its marker and text" {
    const Canvas = @import("../backend/terminal/canvas.zig").TerminalCanvas;
    var canvas = try Canvas.init(std.testing.allocator, 30, 8);
    defer canvas.deinit();
    const heading = Heading{ .text = "Pigeons", .level = 2, .style = Style.plain() };
    try heading.draw(.{ .canvas = &canvas }, Rect.init(0, 0, 30, 4));
    var saw_marker = false;
    var saw_text = false;
    for (canvas.text_entries.items) |*entry| {
        if (std.mem.eql(u8, entry.bytes(), "##")) saw_marker = true;
        if (std.mem.eql(u8, entry.bytes(), "Pigeons")) saw_text = true;
    }
    try std.testing.expect(saw_marker);
    try std.testing.expect(saw_text);
}
