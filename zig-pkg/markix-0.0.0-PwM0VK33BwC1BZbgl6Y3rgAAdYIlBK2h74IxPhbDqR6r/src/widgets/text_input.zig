const std = @import("std");
const Surface = @import("surface.zig").Surface;
const terminal_input = @import("../backend/terminal/input.zig");
const Rect = @import("../layout/rect.zig").Rect;
const Style = @import("../style/style.zig").Style;
const Attributes = @import("../style/text_style.zig").Attributes;

pub const Action = enum { ignored, changed, submitted, cancelled };

pub fn TextInput(comptime capacity: u16) type {
    return struct {
        const Self = @This();

        bytes: [capacity]u8 = undefined,
        length: u16 = 0,
        cursor: u16 = 0,

        pub fn value(self: *const Self) []const u8 {
            return self.bytes[0..self.length];
        }

        pub fn set(self: *Self, value_bytes: []const u8) !void {
            if (value_bytes.len > capacity) return error.TextTooLong;
            @memcpy(self.bytes[0..value_bytes.len], value_bytes);
            self.length = @intCast(value_bytes.len);
            self.cursor = self.length;
        }

        pub fn clear(self: *Self) void {
            self.length = 0;
            self.cursor = 0;
        }

        pub fn handle(self: *Self, key: terminal_input.Key) !Action {
            return switch (key) {
                .character => |byte| self.insert(byte),
                .backspace => self.backspace(),
                .delete => self.delete(),
                .left => self.move_left(),
                .right => self.move_right(),
                .home => self.move_home(),
                .end => self.move_end(),
                .enter => .submitted,
                .escape => .cancelled,
                else => .ignored,
            };
        }

        fn insert(self: *Self, byte: u8) !Action {
            if (!std.ascii.isPrint(byte)) return .ignored;
            if (self.length >= capacity) return error.TextInputFull;
            var index = self.length;
            while (index > self.cursor) : (index -= 1) {
                self.bytes[index] = self.bytes[index - 1];
            }
            self.bytes[self.cursor] = byte;
            self.length += 1;
            self.cursor += 1;
            return .changed;
        }

        fn backspace(self: *Self) Action {
            if (self.cursor == 0) return .ignored;
            self.cursor -= 1;
            return self.remove_at_cursor();
        }

        fn delete(self: *Self) Action {
            if (self.cursor >= self.length) return .ignored;
            return self.remove_at_cursor();
        }

        fn remove_at_cursor(self: *Self) Action {
            var index = self.cursor;
            while (index + 1 < self.length) : (index += 1) {
                self.bytes[index] = self.bytes[index + 1];
            }
            self.length -= 1;
            return .changed;
        }

        fn move_left(self: *Self) Action {
            self.cursor -|= 1;
            return .changed;
        }

        fn move_right(self: *Self) Action {
            self.cursor = @min(self.cursor +| 1, self.length);
            return .changed;
        }

        fn move_home(self: *Self) Action {
            self.cursor = 0;
            return .changed;
        }

        fn move_end(self: *Self) Action {
            self.cursor = self.length;
            return .changed;
        }
    };
}

pub const Options = struct {
    prompt: []const u8 = "",
    placeholder: []const u8 = "",
    style: Style,
    focused: bool,
    prompt_attributes: Attributes = .{ .bold = true },
    value_attributes: Attributes = .{},
    placeholder_attributes: Attributes = .{ .dim = true },
    cursor_attributes: Attributes = .{ .bold = true },
};

pub fn draw(
    input: anytype,
    surface: Surface,
    rect: Rect,
    options: Options,
) !void {
    std.debug.assert(rect.height > 0);
    std.debug.assert(options.prompt.len <= std.math.maxInt(u16));
    if (rect.width == 0 or rect.height == 0) return;
    surface.fill(Rect.init(rect.x, rect.y, rect.width, 1), options.style.background);
    const prompt_length: u16 = @intCast(@min(options.prompt.len, rect.width));
    if (prompt_length > 0) {
        try surface.styled_text(
            rect.x,
            rect.y,
            options.prompt[0..prompt_length],
            .{
                .foreground = options.style.accent,
                .background = options.style.background,
                .attributes = options.prompt_attributes,
            },
        );
    }
    if (prompt_length >= rect.width) return;
    const value_rect = Rect.init(
        rect.x + prompt_length,
        rect.y,
        rect.width - prompt_length,
        1,
    );
    if (options.focused) {
        try draw_focused(input, surface, value_rect, options);
    } else {
        try draw_idle(input, surface, value_rect, options);
    }
}

fn draw_idle(
    input: anytype,
    surface: Surface,
    rect: Rect,
    options: Options,
) !void {
    std.debug.assert(rect.height > 0);
    std.debug.assert(options.prompt.len <= std.math.maxInt(u16));
    const value = input.value();
    const text = if (value.len == 0) options.placeholder else value;
    const foreground = if (value.len == 0)
        options.style.muted
    else
        options.style.foreground;
    try surface.styled_text_in(rect, 0, text, .{
        .foreground = foreground,
        .background = options.style.background,
        .attributes = if (value.len == 0)
            options.placeholder_attributes
        else
            options.value_attributes,
    });
}

fn draw_focused(
    input: anytype,
    surface: Surface,
    rect: Rect,
    options: Options,
) !void {
    std.debug.assert(rect.height > 0);
    std.debug.assert(options.prompt.len <= std.math.maxInt(u16));
    const value = input.value();
    const visible_length: u16 = @intCast(@min(value.len, rect.width));
    const cursor: u16 = @min(input.cursor, @min(visible_length, rect.width - 1));
    if (cursor > 0) {
        try surface.styled_text(
            rect.x,
            rect.y,
            value[0..cursor],
            .{
                .foreground = options.style.foreground,
                .background = options.style.background,
                .attributes = options.value_attributes,
            },
        );
    }
    const cursor_byte = if (cursor < visible_length) value[cursor] else ' ';
    try surface.styled_text(
        rect.x + cursor,
        rect.y,
        &.{cursor_byte},
        .{
            .foreground = options.style.selected_foreground,
            .background = options.style.selected_background,
            .attributes = options.cursor_attributes,
        },
    );
    if (cursor + 1 < visible_length) {
        try surface.styled_text(
            rect.x + cursor + 1,
            rect.y,
            value[cursor + 1 .. visible_length],
            .{
                .foreground = options.style.foreground,
                .background = options.style.background,
                .attributes = options.value_attributes,
            },
        );
    }
}

test "focused text input emits an independently patchable cursor cell" {
    const Canvas = @import("../backend/terminal/canvas.zig").TerminalCanvas;
    const Color = @import("../style/color.zig").Color;
    var canvas = try Canvas.init(std.testing.allocator, 20, 4);
    defer canvas.deinit();
    var input = TextInput(8){};
    try input.set("abc");
    _ = try input.handle(.left);
    _ = try input.handle(.left);
    const foreground = Color.from_rgb(230, 230, 230);
    const background = Color.from_rgb(20, 20, 20);
    const style = Style.monochrome(foreground, background);
    try draw(&input, .{ .canvas = &canvas }, Rect.init(1, 1, 10, 1), .{
        .style = style,
        .focused = true,
    });
    try std.testing.expectEqual(@as(usize, 3), canvas.text_entries.items.len);
    const cursor = &canvas.text_entries.items[1];
    try std.testing.expectEqual(@as(u16, 2), cursor.x);
    try std.testing.expectEqualStrings("b", cursor.bytes());
    try std.testing.expect(cursor.background_color.?.equals(foreground));
}

test "text input edits at its cursor" {
    var field = TextInput(8){};
    try field.set("ac");
    _ = try field.handle(.left);
    _ = try field.handle(.{ .character = 'b' });
    try std.testing.expectEqualStrings("abc", field.value());
    try std.testing.expectEqual(Action.changed, try field.handle(.backspace));
    try std.testing.expectEqualStrings("ac", field.value());
}
