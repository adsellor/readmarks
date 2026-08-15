const std = @import("std");
const Surface = @import("surface.zig").Surface;
const Rect = @import("../layout/rect.zig").Rect;
const Style = @import("../style/style.zig").Style;
const Attributes = @import("../style/text_style.zig").Attributes;
const text_measure = @import("../layout/text_measure.zig");
const text_width = @import("../backend/terminal/text_width.zig");

// Pre-formatted text: its own newlines, no wrapping, drawn on its own surface.
//
// A code block differs from prose in every way that matters to layout -- it
// does not reflow, it keeps its indentation, and it paints a background behind
// itself -- so it is a widget rather than a differently coloured label.

pub const Visual = struct {
    /// Columns of padding inside the block's surface.
    padding_left: u8 = 1,
    /// Blank rows inside the surface, above and below the text.
    padding_rows: u8 = 0,
    /// A rail down the left edge, as panels have.
    rail_width: u8 = 1,
    attributes: Attributes = .{},
};

pub const CodeBlock = struct {
    text: []const u8,
    language: []const u8 = "",
    style: Style,
    visual: Visual = .{},

    /// Rows the block occupies, padding included. Lines are not wrapped: code
    /// that runs past the edge is clipped rather than reflowed.
    pub fn rows(self: CodeBlock) u16 {
        const text_rows = text_measure.literal_rows(self.text);
        std.debug.assert(text_rows > 0);
        return text_rows +| @as(u16, self.visual.padding_rows) *| 2;
    }

    pub fn indent(self: CodeBlock) u16 {
        return @as(u16, self.visual.rail_width) + self.visual.padding_left;
    }

    pub fn draw(self: CodeBlock, surface: Surface, rect: Rect) !void {
        std.debug.assert(self.visual.rail_width <= rect.width or rect.width == 0);
        std.debug.assert(rect.width <= std.math.maxInt(u16));
        if (rect.width == 0) return;
        if (rect.height == 0) return;
        surface.fill(rect, self.style.background);
        self.draw_rail(surface, rect);

        const left_columns = self.indent();
        if (left_columns >= rect.width) return;
        const body = Rect.init(
            rect.x + left_columns,
            rect.y + self.visual.padding_rows,
            rect.width - left_columns,
            rect.height -| self.visual.padding_rows,
        );
        try self.draw_lines(surface, body);
    }

    fn draw_rail(self: CodeBlock, surface: Surface, rect: Rect) void {
        if (self.visual.rail_width == 0) return;
        const width = @min(@as(u16, self.visual.rail_width), rect.width);
        surface.fill(Rect.init(rect.x, rect.y, width, rect.height), self.style.border);
    }

    fn draw_lines(self: CodeBlock, surface: Surface, body: Rect) !void {
        std.debug.assert(body.width > 0);
        var row: u16 = 0;
        var start: usize = 0;
        while (start <= self.text.len and row < body.height) : (row += 1) {
            const end = std.mem.indexOfScalarPos(u8, self.text, start, '\n') orelse
                self.text.len;
            const line = text_width.clip(self.text[start..end], body.width);
            if (line.len > 0) {
                try surface.text_in(
                    body,
                    row,
                    line,
                    self.style.foreground,
                    self.style.background,
                );
            }
            if (end == self.text.len) break;
            start = end + 1;
        }
        std.debug.assert(row <= body.height);
    }
};

test "a code block counts its own lines" {
    const block = CodeBlock{ .text = "one\ntwo\nthree", .style = Style.plain() };
    try std.testing.expectEqual(@as(u16, 3), block.rows());
}

test "padding adds rows above and below" {
    const block = CodeBlock{
        .text = "one\ntwo",
        .style = Style.plain(),
        .visual = .{ .padding_rows = 1 },
    };
    try std.testing.expectEqual(@as(u16, 4), block.rows());
}

test "code does not wrap, it clips" {
    const Canvas = @import("../backend/terminal/canvas.zig").TerminalCanvas;
    var canvas = try Canvas.init(std.testing.allocator, 20, 8);
    defer canvas.deinit();
    const block = CodeBlock{
        .text = "a line that is far too long for this rect",
        .style = Style.plain(),
    };
    // One source line stays one row however wide it is.
    try std.testing.expectEqual(@as(u16, 1), block.rows());
    try block.draw(.{ .canvas = &canvas }, Rect.init(0, 0, 20, 4));
    for (canvas.text_entries.items) |*entry| {
        try std.testing.expect(entry.x + entry.text_length <= 20);
    }
}

test "indentation is preserved" {
    const Canvas = @import("../backend/terminal/canvas.zig").TerminalCanvas;
    var canvas = try Canvas.init(std.testing.allocator, 30, 8);
    defer canvas.deinit();
    const block = CodeBlock{ .text = "outer\n    inner", .style = Style.plain() };
    try block.draw(.{ .canvas = &canvas }, Rect.init(0, 0, 30, 4));
    var saw_indented = false;
    for (canvas.text_entries.items) |*entry| {
        if (std.mem.eql(u8, entry.bytes(), "    inner")) saw_indented = true;
    }
    try std.testing.expect(saw_indented);
}

test "an empty rect draws nothing" {
    const Canvas = @import("../backend/terminal/canvas.zig").TerminalCanvas;
    var canvas = try Canvas.init(std.testing.allocator, 20, 4);
    defer canvas.deinit();
    const block = CodeBlock{ .text = "x", .style = Style.plain() };
    try block.draw(.{ .canvas = &canvas }, Rect.init(0, 0, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), canvas.text_entries.items.len);
}
