const std = @import("std");
const limits = @import("limits.zig");
const utils_input = @import("../../utils/input.zig");
pub const Key = utils_input.Key;
pub const Pointer = utils_input.Pointer;
pub const PointerButton = utils_input.PointerButton;

const ParsedPointer = struct {
    pointer: utils_input.Pointer,
    consumed: usize,
};

pub const Batch = struct {
    keys: [limits.input_keys_max]Key = undefined,
    count: u8 = 0,

    pub fn append(self: *Batch, key: Key) error{InputBatchFull}!void {
        if (self.count >= limits.input_keys_max) return error.InputBatchFull;
        self.keys[self.count] = key;
        self.count += 1;
    }

    pub fn items(self: *const Batch) []const Key {
        return self.keys[0..self.count];
    }
};

pub fn parse(bytes: []const u8) !Batch {
    var batch = Batch{};
    var index: usize = 0;
    while (index < bytes.len) {
        if (bytes[index] == 0x1b) {
            index += try parse_escape(bytes[index..], &batch);
        } else {
            try batch.append(parse_byte(bytes[index]));
            index += 1;
        }
    }
    return batch;
}

fn parse_byte(byte: u8) Key {
    return switch (byte) {
        '\r', '\n' => .enter,
        '\t' => .tab,
        0x7f, 0x08 => .backspace,
        1...7, 11...12, 14...26 => .{ .control = byte + 'a' - 1 },
        else => .{ .character = byte },
    };
}

fn parse_escape(bytes: []const u8, batch: *Batch) !usize {
    std.debug.assert(bytes.len > 0);
    std.debug.assert(batch.count <= batch.keys.len);
    std.debug.assert(bytes.len > 0);
    if (bytes.len == 1 or bytes[1] != '[') {
        try batch.append(.escape);
        return 1;
    }
    if (bytes.len < 3) {
        try batch.append(.escape);
        return 1;
    }
    if (bytes[2] == '<') {
        if (parse_pointer(bytes)) |parsed| {
            try batch.append(.{ .pointer = parsed.pointer });
            return parsed.consumed;
        }
    }
    const key: ?Key = switch (bytes[2]) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'Z' => .shift_tab,
        '3' => if (bytes.len >= 4 and bytes[3] == '~') .delete else null,
        else => null,
    };
    if (key) |parsed| {
        try batch.append(parsed);
        return if (bytes[2] == '3') 4 else 3;
    }
    try batch.append(.escape);
    return 1;
}

fn parse_pointer(bytes: []const u8) ?ParsedPointer {
    std.debug.assert(bytes.len > 0);
    std.debug.assert(bytes.len <= std.math.maxInt(u16));
    if (bytes.len < 9) return null;
    if (bytes[0] != 0x1b) return null;
    if (bytes[1] != '[') return null;
    if (bytes[2] != '<') return null;

    var cursor: usize = 3;
    const code = parse_number(bytes, &cursor) orelse return null;
    if (cursor >= bytes.len or bytes[cursor] != ';') return null;
    cursor += 1;
    const column = parse_number(bytes, &cursor) orelse return null;
    if (cursor >= bytes.len or bytes[cursor] != ';') return null;
    cursor += 1;
    const row = parse_number(bytes, &cursor) orelse return null;
    if (cursor >= bytes.len) return null;
    const final = bytes[cursor];
    if (final != 'M' and final != 'm') return null;
    if (column == 0 or row == 0) return null;

    return .{
        .pointer = .{
            .x = column - 1,
            .y = row - 1,
            .action = pointer_action(code, final),
            .button = pointer_button(code, final),
        },
        .consumed = cursor + 1,
    };
}

fn parse_number(bytes: []const u8, cursor: *usize) ?u16 {
    std.debug.assert(cursor.* <= bytes.len);
    const start = cursor.*;
    var value: u32 = 0;
    while (cursor.* < bytes.len) : (cursor.* += 1) {
        const byte = bytes[cursor.*];
        if (byte < '0' or byte > '9') break;
        value = value * 10 + byte - '0';
        if (value > std.math.maxInt(u16)) return null;
    }
    if (cursor.* == start) return null;
    return @intCast(value);
}

fn pointer_action(code: u16, final: u8) utils_input.PointerAction {
    if (final == 'm') return .release;
    if (code & 3 == 3) return .release;
    if (code & 32 != 0) return .drag;
    return .press;
}

fn pointer_button(code: u16, final: u8) utils_input.PointerButton {
    if (final == 'm' or code & 3 == 3) return .none;
    if (code & 64 != 0) {
        return if (code & 1 == 0) .wheel_up else .wheel_down;
    }
    return switch (code & 3) {
        0 => .primary,
        1 => .middle,
        2 => .secondary,
        else => .none,
    };
}

test "terminal input parser handles text controls and ANSI sequences" {
    const batch = try parse("ab\t\x1b[A\x1b[3~\x7f");
    try std.testing.expectEqual(@as(u8, 6), batch.count);
    try std.testing.expectEqual(Key{ .character = 'a' }, batch.keys[0]);
    try std.testing.expectEqual(Key{ .character = 'b' }, batch.keys[1]);
    try std.testing.expectEqual(Key.tab, batch.keys[2]);
    try std.testing.expectEqual(Key.up, batch.keys[3]);
    try std.testing.expectEqual(Key.delete, batch.keys[4]);
    try std.testing.expectEqual(Key.backspace, batch.keys[5]);
}

test "terminal input parser handles bounded SGR pointer events" {
    const batch = try parse(
        "\x1b[<0;8;4M\x1b[<32;12;5M\x1b[<0;12;5m\x1b[<64;2;3M",
    );
    try std.testing.expectEqual(@as(u8, 4), batch.count);
    try std.testing.expectEqual(Key{ .pointer = .{
        .x = 7,
        .y = 3,
        .action = .press,
        .button = .primary,
    } }, batch.keys[0]);
    try std.testing.expectEqual(Key{ .pointer = .{
        .x = 11,
        .y = 4,
        .action = .drag,
        .button = .primary,
    } }, batch.keys[1]);
    try std.testing.expectEqual(Key{ .pointer = .{
        .x = 11,
        .y = 4,
        .action = .release,
        .button = .none,
    } }, batch.keys[2]);
    try std.testing.expectEqual(Key{ .pointer = .{
        .x = 1,
        .y = 2,
        .action = .press,
        .button = .wheel_up,
    } }, batch.keys[3]);
}

test "terminal input parser rejects malformed SGR pointer coordinates" {
    try std.testing.expectEqual(@as(?ParsedPointer, null), parse_pointer("\x1b[<0;0;1M"));
    try std.testing.expectEqual(@as(?ParsedPointer, null), parse_pointer("\x1b[<0;1;0M"));
    try std.testing.expectEqual(
        @as(?ParsedPointer, null),
        parse_pointer("\x1b[<0;65536;1M"),
    );
}
