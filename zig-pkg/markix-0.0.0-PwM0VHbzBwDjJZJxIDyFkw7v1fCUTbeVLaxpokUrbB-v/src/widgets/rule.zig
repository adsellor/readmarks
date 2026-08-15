const std = @import("std");
const Surface = @import("surface.zig").Surface;
const Rect = @import("../layout/rect.zig").Rect;
const Style = @import("../style/style.zig").Style;

// A horizontal divider.
//
// A rule is not a label with dashes in it: it spans whatever width it is
// given, and the backends draw it differently -- characters on a terminal, a
// border in a browser -- so it carries its own kind.

pub const Visual = struct {
    character: u8 = '-',
    /// Columns left blank at each end.
    inset: u8 = 0,
};

pub const Rule = struct {
    style: Style,
    visual: Visual = .{},

    pub fn rows(self: Rule) u16 {
        _ = self;
        return 1;
    }

    pub fn draw(self: Rule, surface: Surface, rect: Rect) !void {
        std.debug.assert(rect.width <= std.math.maxInt(u16));
        if (rect.width == 0) return;
        if (rect.height == 0) return;
        const inset: u16 = @min(self.visual.inset, rect.width / 2);
        const width = rect.width -| inset *| 2;
        if (width == 0) return;
        const inner = Rect.init(rect.x + inset, rect.y, width, rect.height);
        try surface.horizontal_rule(inner, 0, self.style.border);
    }
};

test "a rule occupies one row" {
    try std.testing.expectEqual(@as(u16, 1), (Rule{ .style = Style.plain() }).rows());
}

test "a rule spans its width" {
    const Canvas = @import("../backend/terminal/canvas.zig").TerminalCanvas;
    var canvas = try Canvas.init(std.testing.allocator, 20, 4);
    defer canvas.deinit();
    const rule = Rule{ .style = Style.plain() };
    try rule.draw(.{ .canvas = &canvas }, Rect.init(0, 0, 12, 1));
    try std.testing.expectEqual(@as(usize, 1), canvas.text_entries.items.len);
    try std.testing.expectEqual(@as(u16, 12), canvas.text_entries.items[0].text_length);
}

test "an inset rule stays inside its rect" {
    const Canvas = @import("../backend/terminal/canvas.zig").TerminalCanvas;
    var canvas = try Canvas.init(std.testing.allocator, 20, 4);
    defer canvas.deinit();
    const rule = Rule{ .style = Style.plain(), .visual = .{ .inset = 2 } };
    try rule.draw(.{ .canvas = &canvas }, Rect.init(0, 0, 12, 1));
    const entry = &canvas.text_entries.items[0];
    try std.testing.expectEqual(@as(u16, 2), entry.x);
    try std.testing.expectEqual(@as(u16, 8), entry.text_length);
}

test "a zero width rule draws nothing" {
    const Canvas = @import("../backend/terminal/canvas.zig").TerminalCanvas;
    var canvas = try Canvas.init(std.testing.allocator, 20, 4);
    defer canvas.deinit();
    const rule = Rule{ .style = Style.plain(), .visual = .{ .inset = 9 } };
    try rule.draw(.{ .canvas = &canvas }, Rect.init(0, 0, 0, 1));
    try rule.draw(.{ .canvas = &canvas }, Rect.init(0, 1, 4, 1));
    try std.testing.expectEqual(@as(usize, 0), canvas.text_entries.items.len);
}
