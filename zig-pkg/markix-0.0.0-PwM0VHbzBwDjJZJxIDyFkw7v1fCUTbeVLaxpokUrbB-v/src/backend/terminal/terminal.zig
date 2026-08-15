const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const stdin_file_descriptor = posix.STDIN_FILENO;
const stdout_file_descriptor = posix.STDOUT_FILENO;

pub const TerminalSize = struct {
    width: u16,
    height: u16,
};

pub fn enable_raw_mode() !posix.termios {
    std.debug.assert(posix.STDIN_FILENO >= 0);
    std.debug.assert(@sizeOf(posix.termios) > 0);
    const original = try posix.tcgetattr(stdin_file_descriptor);
    var raw = original;

    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.oflag.OPOST = false;
    raw.cflag.CSIZE = .CS8;
    raw.cc[@backingInt(posix.V.MIN)] = 1;
    raw.cc[@backingInt(posix.V.TIME)] = 0;

    try posix.tcsetattr(stdin_file_descriptor, .FLUSH, raw);
    return original;
}

pub fn disable_raw_mode(original: posix.termios) !void {
    try posix.tcsetattr(stdin_file_descriptor, .FLUSH, original);
}

pub fn get_terminal_size() !TerminalSize {
    std.debug.assert(@sizeOf(TerminalSize) > 0);
    std.debug.assert(posix.STDOUT_FILENO >= 0);
    const WindowSize = extern struct {
        row: u16,
        column: u16,
        pixel_width: u16,
        pixel_height: u16,
    };
    var window_size: WindowSize = undefined;
    const request: u32 = switch (builtin.os.tag) {
        .linux => 0x5413,
        .macos, .freebsd, .netbsd, .openbsd, .dragonfly => 0x40087468,
        else => @compileError("unsupported operating system"),
    };

    const result = posix.system.ioctl(
        stdout_file_descriptor,
        request,
        @intFromPtr(&window_size),
    );
    if (result < 0) return error.TerminalSizeQueryFailed;
    if (window_size.column == 0 or window_size.row == 0) {
        return error.InvalidTerminalSize;
    }
    return .{ .width = window_size.column, .height = window_size.row };
}

pub const GraphicsCapabilities = struct {
    kitty: bool = false,
    sixel: bool = false,
};

pub fn query_graphics_capabilities(io: std.Io) !GraphicsCapabilities {
    const original = try enable_raw_mode();
    defer disable_raw_mode(original) catch {};
    const queries =
        "\x1B_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1B\\" ++
        "\x1B[c\x1B[?2;1;0S";
    try std.Io.File.stdout().writeStreamingAll(io, queries);
    var response: [1_024]u8 = undefined;
    const count = try collect_query_responses(&response);
    return parse_graphics_capabilities(response[0..count]);
}

fn collect_query_responses(response: []u8) !usize {
    std.debug.assert(response.len > 0);
    std.debug.assert(response.len <= std.math.maxInt(u16));
    var descriptors = [_]posix.pollfd{.{
        .fd = stdin_file_descriptor,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    var length: usize = 0;
    var attempt: u8 = 0;
    while (attempt < 4 and length < response.len) : (attempt += 1) {
        const ready_count = try posix.poll(&descriptors, 50);
        if (ready_count == 0) continue;
        if (descriptors[0].revents & posix.POLL.IN == 0) continue;
        const count = try posix.read(stdin_file_descriptor, response[length..]);
        if (count == 0) break;
        length += count;
    }
    return length;
}

fn parse_graphics_capabilities(response: []const u8) GraphicsCapabilities {
    return .{
        .kitty = std.mem.indexOf(u8, response, "\x1B_Gi=31;") != null,
        .sixel = device_attributes_include_sixel(response) or
            sixel_geometry_succeeded(response),
    };
}

fn device_attributes_include_sixel(response: []const u8) bool {
    const start = std.mem.indexOf(u8, response, "\x1B[?") orelse return false;
    const suffix = response[start + 3 ..];
    const end = std.mem.indexOfScalar(u8, suffix, 'c') orelse return false;
    var parameters = std.mem.splitScalar(u8, suffix[0..end], ';');
    while (parameters.next()) |parameter| {
        if (std.mem.eql(u8, parameter, "4")) return true;
    }
    return false;
}

fn sixel_geometry_succeeded(response: []const u8) bool {
    const prefix = "\x1B[?2;0;";
    const start = std.mem.indexOf(u8, response, prefix) orelse return false;
    const suffix = response[start + prefix.len ..];
    return std.mem.indexOfScalar(u8, suffix, 'S') != null;
}

test "graphics responses identify negotiated protocols" {
    const both = parse_graphics_capabilities(
        "\x1B_Gi=31;OK\x1B\\\x1B[?62;4;22c",
    );
    try std.testing.expect(both.kitty);
    try std.testing.expect(both.sixel);
    const sixel = parse_graphics_capabilities("\x1B[?2;0;1280;720S");
    try std.testing.expect(!sixel.kitty);
    try std.testing.expect(sixel.sixel);
}
