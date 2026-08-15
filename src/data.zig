pub const bookmarks = @import("data/bookmarks.zig");
pub const FixedText = @import("data/bookmarks/fixed_text.zig").FixedText;
pub const http = @import("data/http.zig");
pub const paths = @import("data/paths.zig");
pub const Paths = paths.Paths;
pub const limits = @import("data/limits.zig");
pub const page = @import("data/page.zig");

const std = @import("std");
const builtin = @import("builtin");

pub fn cwd() std.Io.Dir {
    if (comptime builtin.target.cpu.arch.isWasm()) {
        return .{ .handle = {} };
    } else {
        return std.Io.Dir.cwd();
    }
}
