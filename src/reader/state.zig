const std = @import("std");
const limits = @import("limits.zig");
const Paths = @import("data").Paths;

pub const State = struct {
    hashes: [limits.read_count_max]u64 = undefined,
    count: u16 = 0,

    pub fn contains(self: *const State, url: []const u8) bool {
        const expected = url_hash(url);
        var index: u16 = 0;
        while (index < self.count) : (index += 1) {
            if (self.hashes[index] == expected) return true;
        }
        return false;
    }

    pub fn mark_read(self: *State, url: []const u8) !void {
        if (self.contains(url)) return;
        if (self.count == limits.read_count_max) return error.ReadStateFull;
        self.hashes[self.count] = url_hash(url);
        self.count += 1;
    }

    pub fn mark_unread(self: *State, url: []const u8) void {
        const expected = url_hash(url);
        var index: u16 = 0;
        while (index < self.count) : (index += 1) {
            if (self.hashes[index] != expected) continue;
            self.hashes[index] = self.hashes[self.count - 1];
            self.count -= 1;
            return;
        }
    }
};

pub const file_name = "rss-state.bin";

pub const Persistence = struct {
    directory: [limits.path_bytes_max]u8 = undefined,
    directory_length: u16,
    file_path: [limits.path_bytes_max]u8 = undefined,
    file_path_length: u16,
    buffer: [limits.state_bytes_max]u8 = undefined,

    pub fn init(paths: *const Paths) !Persistence {
        var persistence: Persistence = undefined;
        try persistence.init_in_place(paths);
        return persistence;
    }

    /// Read marks are data: refetching every feed does not bring them back.
    pub fn init_in_place(self: *Persistence, paths: *const Paths) !void {
        const directory = try std.fmt.bufPrint(
            &self.directory,
            "{s}",
            .{paths.data.bytes()},
        );
        self.directory_length = @intCast(directory.len);
        const path = try std.fmt.bufPrint(
            &self.file_path,
            "{s}/{s}",
            .{ directory, file_name },
        );
        self.file_path_length = @intCast(path.len);
    }

    pub fn load(self: *Persistence, io: std.Io, state: *State) !void {
        const bytes = try self.read(
            io,
            self.file_path[0..self.file_path_length],
        ) orelse return;
        if (bytes.len == self.buffer.len) return error.StateFileTooLarge;
        try decode(bytes, state);
    }

    fn read(self: *Persistence, io: std.Io, path: []const u8) !?[]const u8 {
        return @import("data").cwd().readFile(io, path, &self.buffer) catch |err| {
            return switch (err) {
                error.FileNotFound => null,
                else => err,
            };
        };
    }

    pub fn save(self: *Persistence, io: std.Io, state: *const State) !void {
        const bytes = try encode(state, &self.buffer);
        try @import("data").cwd().createDirPath(
            io,
            self.directory[0..self.directory_length],
        );
        var directory = try std.Io.Dir.openDirAbsolute(
            io,
            self.directory[0..self.directory_length],
            .{},
        );
        defer directory.close(io);
        var atomic_file = try directory.createFileAtomic(
            io,
            file_name,
            .{ .replace = true },
        );
        defer atomic_file.deinit(io);
        try atomic_file.file.writeStreamingAll(io, bytes);
        try atomic_file.replace(io);
    }
};

pub fn encode(state: *const State, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try write_integer(u16, &writer, state.count);
    var index: u16 = 0;
    while (index < state.count) : (index += 1) {
        try write_integer(u64, &writer, state.hashes[index]);
    }
    return writer.buffered();
}

pub fn decode(input: []const u8, state: *State) !void {
    var cursor: usize = 0;
    const count = try read_integer(u16, input, &cursor);
    if (count > limits.read_count_max) return error.InvalidState;
    var decoded = State{};
    while (decoded.count < count) : (decoded.count += 1) {
        decoded.hashes[decoded.count] = try read_integer(u64, input, &cursor);
    }
    if (cursor != input.len) return error.InvalidState;
    state.* = decoded;
}

fn url_hash(url: []const u8) u64 {
    return std.hash.Wyhash.hash(0, url);
}

fn write_integer(comptime T: type, writer: *std.Io.Writer, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

fn read_integer(comptime T: type, input: []const u8, cursor: *usize) !T {
    if (@sizeOf(T) > input.len -| cursor.*) return error.InvalidState;
    const bytes = input[cursor.*..][0..@sizeOf(T)];
    cursor.* += @sizeOf(T);
    return std.mem.readInt(T, bytes, .little);
}

test "read state toggles and round trips" {
    var state = State{};
    try state.mark_read("https://example.com/one");
    try std.testing.expect(state.contains("https://example.com/one"));
    var buffer: [256]u8 = undefined;
    const encoded = try encode(&state, &buffer);
    var decoded = State{};
    try decode(encoded, &decoded);
    try std.testing.expect(decoded.contains("https://example.com/one"));
    decoded.mark_unread("https://example.com/one");
    try std.testing.expect(!decoded.contains("https://example.com/one"));
    try std.testing.expectError(
        error.InvalidState,
        decode(encoded[0 .. encoded.len - 1], &decoded),
    );
}
