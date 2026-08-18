const std = @import("std");
const Key = @import("../../utils/input.zig").Key;
const PointerAction = @import("../../utils/input.zig").PointerAction;

// Input bridge between JS and the web backend. JS pushes fixed-size
// encoded keys into a queue; the update loop drains and decodes them
// into the canonical Key union.
//
// Tags are the declaration order of the Key union (see
// utils/input.zig): character=0, control=1, pointer=2, enter=3,
// escape=4, backspace=5, delete=6, tab=7, shift_tab=8, up=9, down=10,
// left=11, right=12, home=13, end=14. The test below pins this order.

pub const pointer_index = std.meta.fieldIndex(Key, "pointer").?;
pub const KeyTag = std.meta.Tag(Key);
pub const tag_count = @typeInfo(KeyTag).@"enum".field_names.len;

pub const EncodedKey = extern struct {
    tag: u32,
    a: u32,
    b: u32,
    c: u32,

    pub fn character(value: u8) EncodedKey {
        return .{ .tag = 0, .a = value, .b = 0, .c = 0 };
    }

    pub fn control(value: u8) EncodedKey {
        return .{ .tag = 1, .a = value, .b = 0, .c = 0 };
    }

    pub fn plain(tag: u32) EncodedKey {
        return .{ .tag = tag, .a = 0, .b = 0, .c = 0 };
    }

    pub fn pointer_event(
        x: u16,
        y: u16,
        action: PointerAction,
        button: u8,
    ) EncodedKey {
        return .{
            .tag = pointer_index,
            .a = x,
            .b = y,
            .c = @backingInt(action) | (@as(u32, button) << 8),
        };
    }
};

pub fn decode(encoded: EncodedKey) Key {
    std.debug.assert(tag_count > 0);
    std.debug.assert(pointer_index < tag_count);
    if (encoded.tag >= tag_count) return .{ .character = '?' };
    if (encoded.tag == pointer_index) {
        const action: PointerAction =
            @fromBackingInt(@intCast(@as(u8, @intCast(encoded.c & 0xFF))));
        const button: @import("../../utils/input.zig").PointerButton =
            @fromBackingInt(@intCast(@as(u8, @intCast(encoded.c >> 8))));
        return .{ .pointer = .{
            .x = @intCast(encoded.a),
            .y = @intCast(encoded.b),
            .action = action,
            .button = button,
        } };
    }
    const key_tag: KeyTag = @fromBackingInt(@intCast(encoded.tag));
    return switch (key_tag) {
        .character => .{ .character = @intCast(encoded.a) },
        .control => .{ .control = @intCast(encoded.a) },
        .pointer => unreachable,
        inline else => |tag| @unionInit(Key, @tagName(tag), {}),
    };
}

pub fn Queue(comptime capacity: usize) type {
    return struct {
        entries: [capacity]EncodedKey = undefined,
        head: usize = 0,
        tail: usize = 0,

        pub fn push(self: *@This(), encoded: EncodedKey) void {
            const next = (self.tail + 1) % capacity;
            if (next == self.head) return;
            self.entries[self.tail] = encoded;
            self.tail = next;
        }

        pub fn drain(self: *@This(), keys: []Key) usize {
            var count: usize = 0;
            while (self.head != self.tail and count < keys.len) : (count += 1) {
                keys[count] = decode(self.entries[self.head]);
                self.head = (self.head + 1) % capacity;
            }
            return count;
        }
    };
}

test "documented tag order pins the Key union declaration order" {
    try std.testing.expectEqual(@as(usize, 0), std.meta.fieldIndex(Key, "character").?);
    try std.testing.expectEqual(@as(usize, 1), std.meta.fieldIndex(Key, "control").?);
    try std.testing.expectEqual(@as(usize, 2), pointer_index);
    try std.testing.expectEqual(@as(usize, 3), std.meta.fieldIndex(Key, "enter").?);
    try std.testing.expectEqual(@as(usize, 8), std.meta.fieldIndex(Key, "shift_tab").?);
    try std.testing.expectEqual(@as(usize, 14), std.meta.fieldIndex(Key, "end").?);
}

test "encoded keys decode to the canonical union" {
    try std.testing.expectEqual(Key{ .character = 'a' }, decode(EncodedKey.character('a')));
    try std.testing.expectEqual(Key{ .control = 3 }, decode(EncodedKey.control(3)));
    try std.testing.expectEqual(Key{ .enter = {} }, decode(EncodedKey.plain(3)));
    try std.testing.expectEqual(Key{ .shift_tab = {} }, decode(EncodedKey.plain(8)));
    try std.testing.expectEqual(Key{ .up = {} }, decode(EncodedKey.plain(9)));
    const pressed = decode(EncodedKey.pointer_event(12, 34, .press, 0));
    try std.testing.expectEqual(@as(u16, 12), pressed.pointer.x);
    try std.testing.expectEqual(@as(u16, 34), pressed.pointer.y);
    try std.testing.expectEqual(PointerAction.press, pressed.pointer.action);
}

test "queue keeps a bounded ring and decodes in order" {
    var queue = Queue(4){};
    queue.push(EncodedKey.character('x'));
    queue.push(EncodedKey.plain(9));
    queue.push(EncodedKey.character('y'));
    queue.push(EncodedKey.character('z'));
    queue.push(EncodedKey.character('w'));
    var keys: [8]Key = undefined;
    const count = queue.drain(&keys);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(Key{ .character = 'x' }, keys[0]);
    try std.testing.expectEqual(Key{ .up = {} }, keys[1]);
    try std.testing.expectEqual(Key{ .character = 'y' }, keys[2]);
}
