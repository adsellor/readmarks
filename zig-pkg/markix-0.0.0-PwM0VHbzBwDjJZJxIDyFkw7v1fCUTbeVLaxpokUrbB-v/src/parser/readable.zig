const std = @import("std");
const xml = @import("xml.zig");

pub fn extract(html: []const u8, target: anytype) bool {
    const names = [_][]const u8{ "article", "main", "body" };
    for (names) |name| {
        const start = xml.find_open_tag(html, 0, name) orelse continue;
        const content_start = std.mem.indexOfScalarPos(u8, html, start, '>') orelse continue;
        const close = xml.find_close_tag(html, content_start + 1, name) orelse html.len;
        const source = html[content_start + 1 .. close];
        const length = @min(source.len, target.buffer.len);
        target.set(source[0..length]) catch unreachable;
        return length > 0;
    }
    return false;
}

test "readable extraction prefers article markup" {
    const Text = struct {
        buffer: [256]u8 = undefined,
        length: u16 = 0,

        fn set(self: *@This(), value: []const u8) !void {
            if (value.len > self.buffer.len) return error.TextTooLong;
            @memcpy(self.buffer[0..value.len], value);
            self.length = @intCast(value.len);
        }

        fn bytes(self: *const @This()) []const u8 {
            return self.buffer[0..self.length];
        }
    };
    const html =
        \\<html><body><nav>Menu</nav><article><h1>Title</h1>
        \\<p>Complete body.</p></article><footer>Footer</footer></body></html>
    ;
    var content = Text{};
    try std.testing.expect(extract(html, &content));
    try std.testing.expectEqualStrings(
        "<h1>Title</h1>\n<p>Complete body.</p>",
        content.bytes(),
    );
}
