const std = @import("std");
const Key = @import("../utils/input.zig").Key;

pub const Action = enum { ignored, changed, submitted, cancelled };

pub const Split = struct {
    before: []const u8,
    at: []const u8,
    after: []const u8,
};

const blank = " ";

pub fn split_text(value: []const u8, cursor: u16, width: u16) Split {
    std.debug.assert(cursor <= value.len);
    std.debug.assert(value.len <= std.math.maxInt(u16));
    if (width == 0) return .{ .before = "", .at = "", .after = "" };
    const length: u16 = @intCast(value.len);
    const start: u16 = if (cursor >= width) cursor - width + 1 else 0;
    const end: u16 = @min(length, start + width);
    std.debug.assert(start <= cursor);
    if (cursor >= end) return .{ .before = value[start..cursor], .at = blank, .after = "" };
    return .{
        .before = value[start..cursor],
        .at = value[cursor .. cursor + 1],
        .after = value[cursor + 1 .. end],
    };
}

pub fn TextInput(comptime capacity: u16) type {
    comptime std.debug.assert(capacity > 0);
    return struct {
        const Self = @This();

        pub const bytes_max = capacity;

        bytes: [capacity]u8 = undefined,
        length: u16 = 0,
        cursor: u16 = 0,

        pub fn value(self: *const Self) []const u8 {
            std.debug.assert(self.length <= capacity);
            return self.bytes[0..self.length];
        }

        pub fn set(self: *Self, source: []const u8) !void {
            if (source.len > capacity) return error.TextTooLong;
            @memcpy(self.bytes[0..source.len], source);
            self.length = @intCast(source.len);
            self.cursor = self.length;
            std.debug.assert(self.cursor <= capacity);
        }

        pub fn clear(self: *Self) void {
            self.length = 0;
            self.cursor = 0;
        }

        pub fn handle(self: *Self, key: Key) !Action {
            std.debug.assert(self.cursor <= self.length);
            return switch (key) {
                .character => |byte| self.insert(byte),
                .backspace => self.backspace(),
                .delete => self.delete(),
                .left => self.move_to(self.cursor -| 1),
                .right => self.move_to(@min(self.cursor +| 1, self.length)),
                .home => self.move_to(0),
                .end => self.move_to(self.length),
                .enter => .submitted,
                .escape => .cancelled,
                else => .ignored,
            };
        }

        pub fn split(self: *const Self, width: u16) Split {
            std.debug.assert(self.cursor <= self.length);
            return split_text(self.value(), self.cursor, width);
        }

        fn insert(self: *Self, byte: u8) !Action {
            if (!std.ascii.isPrint(byte)) return .ignored;
            if (self.length >= capacity) return error.TextInputFull;
            std.mem.copyBackwards(
                u8,
                self.bytes[self.cursor + 1 .. self.length + 1],
                self.bytes[self.cursor..self.length],
            );
            self.bytes[self.cursor] = byte;
            self.length += 1;
            self.cursor += 1;
            std.debug.assert(self.cursor <= self.length);
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
            std.debug.assert(self.cursor < self.length);
            std.mem.copyForwards(
                u8,
                self.bytes[self.cursor .. self.length - 1],
                self.bytes[self.cursor + 1 .. self.length],
            );
            self.length -= 1;
            std.debug.assert(self.cursor <= self.length);
            return .changed;
        }

        fn move_to(self: *Self, cursor: u16) Action {
            std.debug.assert(cursor <= self.length);
            if (cursor == self.cursor) return .ignored;
            self.cursor = cursor;
            return .changed;
        }
    };
}

const testing = std.testing;

test "text input edits at its cursor" {
    var field = TextInput(8){};
    try field.set("ac");
    _ = try field.handle(.left);
    _ = try field.handle(.{ .character = 'b' });
    try testing.expectEqualStrings("abc", field.value());
    try testing.expectEqual(Action.changed, try field.handle(.backspace));
    try testing.expectEqualStrings("ac", field.value());
    try testing.expectEqual(Action.changed, try field.handle(.delete));
    try testing.expectEqualStrings("a", field.value());
    try testing.expectEqual(Action.ignored, try field.handle(.delete));
}

test "a full input refuses the next byte" {
    var field = TextInput(2){};
    try field.set("ab");
    try testing.expectError(error.TextInputFull, field.handle(.{ .character = 'c' }));
    try testing.expectError(error.TextTooLong, field.set("abc"));
}

test "enter submits and escape cancels without editing" {
    var field = TextInput(4){};
    try field.set("go");
    try testing.expectEqual(Action.submitted, try field.handle(.enter));
    try testing.expectEqual(Action.cancelled, try field.handle(.escape));
    try testing.expectEqual(Action.ignored, try field.handle(.{ .character = 0x07 }));
    try testing.expectEqualStrings("go", field.value());
}

test "the split puts the cursor on a cell of its own" {
    var field = TextInput(8){};
    try field.set("abc");
    _ = try field.handle(.left);
    const middle = field.split(8);
    try testing.expectEqualStrings("ab", middle.before);
    try testing.expectEqualStrings("c", middle.at);
    try testing.expectEqualStrings("", middle.after);
    _ = try field.handle(.end);
    const tail = field.split(8);
    try testing.expectEqualStrings("abc", tail.before);
    try testing.expectEqualStrings(" ", tail.at);
}

test "a narrow split scrolls to keep the cursor in view" {
    var field = TextInput(16){};
    try field.set("abcdefgh");
    const window = field.split(4);
    try testing.expectEqualStrings("fgh", window.before);
    try testing.expectEqualStrings(" ", window.at);
    _ = try field.handle(.home);
    const start = field.split(4);
    try testing.expectEqualStrings("", start.before);
    try testing.expectEqualStrings("a", start.at);
    try testing.expectEqualStrings("bcd", start.after);
    try testing.expectEqual(@as(usize, 0), field.split(0).at.len);
}
