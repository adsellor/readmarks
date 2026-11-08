const std = @import("std");
const builtin = @import("builtin");

extern "env" fn js_open_url(url: [*]const u8, url_len: usize) void;

pub fn open(io: std.Io, url: []const u8) !void {
    if (builtin.target.cpu.arch.isWasm()) {
        js_open_url(url.ptr, url.len);
        return;
    }
    const command = command_name();
    var child = try std.process.spawn(io, .{
        .argv = &.{ command, url },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const termination = try child.wait(io);
    if (!termination.eql(.success)) return error.BrowserCommandFailed;
}

pub fn command_name() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "open",
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => "xdg-open",
        else => @compileError("browser opening is unsupported on this operating system"),
    };
}

test "browser command is explicit for the target" {
    try std.testing.expect(command_name().len > 0);
}
