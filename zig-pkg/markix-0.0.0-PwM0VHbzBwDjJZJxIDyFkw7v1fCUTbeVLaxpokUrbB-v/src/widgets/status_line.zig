const std = @import("std");
const Surface = @import("surface.zig").Surface;
const Rect = @import("../layout/rect.zig").Rect;
const Style = @import("../style/style.zig").Style;
const Attributes = @import("../style/text_style.zig").Attributes;

pub const Hint = struct {
    key: []const u8,
    label: []const u8,
};

pub const Visual = struct {
    message_attributes: Attributes = .{ .bold = true },
    key_attributes: Attributes = .{ .bold = true },
    label_attributes: Attributes = .{ .dim = true },
    hint_gap: u8 = 2,
};

pub const StatusLine = struct {
    style: Style,
    visual: Visual = .{},

    pub fn draw(
        self: StatusLine,
        surface: Surface,
        rect: Rect,
        message: []const u8,
        hints: []const Hint,
    ) !void {
        std.debug.assert(rect.height > 0);
        std.debug.assert(self.visual.hint_gap < rect.width or rect.width == 0);
        if (rect.width == 0 or rect.height == 0) return;
        surface.fill(Rect.init(rect.x, rect.y, rect.width, 1), self.style.background);
        const hint_width = @min(hints_width(hints, self.visual.hint_gap), rect.width);
        const hint_start = rect.width - hint_width;
        const message_width = hint_start -| @intFromBool(hint_start > 0);
        if (message_width > 0) {
            const length = @min(message.len, message_width);
            try surface.styled_text(
                rect.x,
                rect.y,
                message[0..length],
                .{
                    .foreground = self.style.foreground,
                    .background = self.style.background,
                    .attributes = self.visual.message_attributes,
                },
            );
        }
        if (hint_start < rect.width) {
            try self.draw_hints(
                surface,
                Rect.init(rect.x + hint_start, rect.y, rect.width - hint_start, 1),
                hints,
            );
        }
    }

    fn draw_hints(
        self: StatusLine,
        surface: Surface,
        rect: Rect,
        hints: []const Hint,
    ) !void {
        std.debug.assert(rect.height > 0);
        std.debug.assert(hints.len <= std.math.maxInt(u16));
        var column: u16 = 0;
        for (hints) |hint| {
            const hint_width: u16 = @intCast(hint.key.len + hint.label.len + 1);
            if (column + hint_width > rect.width) break;
            try surface.styled_text(
                rect.x + column,
                rect.y,
                hint.key,
                .{
                    .foreground = self.style.selected_foreground,
                    .background = self.style.selected_background,
                    .attributes = self.visual.key_attributes,
                },
            );
            column += @intCast(hint.key.len);
            if (column >= rect.width) break;
            column += 1;
            if (column >= rect.width) break;
            const label_length: u16 = @intCast(hint.label.len);
            try surface.styled_text(
                rect.x + column,
                rect.y,
                hint.label[0..label_length],
                .{
                    .foreground = self.style.muted,
                    .background = self.style.background,
                    .attributes = self.visual.label_attributes,
                },
            );
            column += label_length;
            column = @min(column +| self.visual.hint_gap, rect.width);
        }
    }
};

fn hints_width(hints: []const Hint, gap: u8) u16 {
    var width: u32 = 0;
    for (hints) |hint| {
        width += @intCast(hint.key.len + hint.label.len + 1 + gap);
    }
    return @intCast(@min(width, std.math.maxInt(u16)));
}
