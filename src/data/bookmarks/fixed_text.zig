const std = @import("std");

pub fn FixedText(comptime capacity: u16) type {
    return struct {
        const Self = @This();

        /// Bytes this text can hold, for callers formatting into a scratch
        /// buffer before setting it.
        pub const capacity_bytes: u16 = capacity;

        buffer: [capacity]u8 = undefined,
        length: u16 = 0,

        pub fn init(value: []const u8) error{TextTooLong}!Self {
            var text = Self{};
            try text.set(value);
            return text;
        }

        pub fn set(self: *Self, value: []const u8) error{TextTooLong}!void {
            if (value.len > capacity) return error.TextTooLong;
            @memcpy(self.buffer[0..value.len], value);
            self.length = @intCast(value.len);
        }

        pub fn clear(self: *Self) void {
            self.length = 0;
        }

        pub fn bytes(self: *const Self) []const u8 {
            return self.buffer[0..self.length];
        }

        pub fn is_empty(self: *const Self) bool {
            return self.length == 0;
        }
    };
}

test "fixed text rejects overflow without changing content" {
    const Text = FixedText(4);
    var text = try Text.init("four");
    try std.testing.expectError(error.TextTooLong, text.set("fours"));
    try std.testing.expectEqualStrings("four", text.bytes());
    text.clear();
    try std.testing.expect(text.is_empty());
}
