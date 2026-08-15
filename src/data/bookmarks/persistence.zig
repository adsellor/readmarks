const std = @import("std");
const builtin = @import("builtin");
const limits = @import("../limits.zig");
const Paths = @import("../paths.zig").Paths;
const Bookmark = @import("bookmark.zig").Bookmark;
const Store = @import("store.zig").Store;

fn cwd() std.Io.Dir {
    if (comptime builtin.target.cpu.arch.isWasm()) {
        return .{ .handle = {} };
    } else {
        return std.Io.Dir.cwd();
    }
}

/// Name of the store inside whichever directory holds it.
pub const file_name = "bookmarks.bin";

pub const Persistence = struct {
    directory: [limits.path_bytes_max]u8 = undefined,
    directory_length: u16,
    file_path: [limits.path_bytes_max]u8 = undefined,
    file_path_length: u16,
    buffer: [limits.storage_bytes_max]u8 = undefined,

    pub fn init(paths: *const Paths) !Persistence {
        var persistence: Persistence = undefined;
        try persistence.init_in_place(paths);
        return persistence;
    }

    /// Bookmarks are data: they cannot be recovered by fetching anything.
    pub fn init_in_place(self: *Persistence, paths: *const Paths) !void {
        const directory = try std.fmt.bufPrint(
            &self.directory,
            "{s}",
            .{paths.data.bytes()},
        );
        self.directory_length = @intCast(directory.len);
        const file_path = try std.fmt.bufPrint(
            &self.file_path,
            "{s}/{s}",
            .{ directory, file_name },
        );
        self.file_path_length = @intCast(file_path.len);
    }

    pub fn load(self: *Persistence, io: std.Io, store: *Store) !void {
        const bytes = try self.read(
            io,
            self.file_path[0..self.file_path_length],
        ) orelse return;
        if (bytes.len == self.buffer.len) return error.StorageTooLarge;
        try decode(bytes, store);
    }

    fn read(self: *Persistence, io: std.Io, path: []const u8) !?[]const u8 {
        return cwd().readFile(io, path, &self.buffer) catch |err| switch (err) {
            error.FileNotFound => null,
            else => err,
        };
    }

    pub fn save(self: *Persistence, io: std.Io, store: *const Store) !void {
        const bytes = try encode(store, &self.buffer);
        try cwd().createDirPath(
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

pub fn encode(store: *const Store, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try write_integer(u16, &writer, store.count);
    var index: u16 = 0;
    while (index < store.count) : (index += 1) {
        const bookmark = &store.items[index];
        try writer.writeByte(@intFromBool(bookmark.favorite));
        try writer.writeByte(@intFromBool(bookmark.custom_title));
        try write_integer(u32, &writer, bookmark.open_count);
        try write_bookmark_fields(&writer, bookmark);
    }
    return writer.buffered();
}

fn write_bookmark_fields(writer: *std.Io.Writer, bookmark: *const Bookmark) !void {
    try write_field(writer, bookmark.title.bytes());
    try write_field(writer, bookmark.url.bytes());
    try write_field(writer, bookmark.tags.bytes());
    try write_field(writer, bookmark.notes.bytes());
    try write_field(writer, bookmark.description.bytes());
    try write_field(writer, bookmark.preview.bytes());
}

/// The file is a count followed by that many records, and nothing else. There
/// is no header: the record count, the per-field lengths and the requirement
/// that the last record ends exactly at the end of the file are what a valid
/// store has to satisfy, and anything else fails to decode.
pub fn decode(input: []const u8, store: *Store) !void {
    var cursor: usize = 0;
    const count = try read_integer(u16, input, &cursor);
    if (count > limits.bookmark_count_max) return error.InvalidStorage;
    var decoded = Store{};
    while (decoded.count < count) {
        const bookmark = try decode_bookmark(input, &cursor);
        decoded.add(bookmark) catch return error.InvalidStorage;
    }
    if (cursor != input.len) return error.InvalidStorage;
    store.* = decoded;
}

fn decode_bookmark(input: []const u8, cursor: *usize) !Bookmark {
    if (cursor.* + 1 >= input.len) return error.InvalidStorage;
    const favorite = input[cursor.*] != 0;
    cursor.* += 1;
    const custom_title = input[cursor.*] != 0;
    cursor.* += 1;
    const open_count = try read_integer(u32, input, cursor);
    const title = try read_field(input, cursor);
    const url = try read_field(input, cursor);
    const tags = try read_field(input, cursor);
    const notes = try read_field(input, cursor);
    var bookmark = Bookmark.init(title, url, tags, notes) catch
        return error.InvalidStorage;
    bookmark.favorite = favorite;
    bookmark.custom_title = custom_title;
    bookmark.open_count = open_count;
    const description = try read_field(input, cursor);
    const preview = try read_field(input, cursor);
    bookmark.description.set(description) catch return error.InvalidStorage;
    bookmark.preview.set(preview) catch return error.InvalidStorage;
    return bookmark;
}

fn write_field(writer: *std.Io.Writer, value: []const u8) !void {
    try write_integer(u16, writer, @intCast(value.len));
    try writer.writeAll(value);
}

fn read_field(input: []const u8, cursor: *usize) ![]const u8 {
    const length = try read_integer(u16, input, cursor);
    if (length > input.len -| cursor.*) return error.InvalidStorage;
    const value = input[cursor.*..][0..length];
    cursor.* += length;
    return value;
}

fn write_integer(comptime T: type, writer: *std.Io.Writer, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

fn read_integer(comptime T: type, input: []const u8, cursor: *usize) !T {
    if (@sizeOf(T) > input.len -| cursor.*) return error.InvalidStorage;
    const bytes = input[cursor.*..][0..@sizeOf(T)];
    cursor.* += @sizeOf(T);
    return std.mem.readInt(T, bytes, .little);
}

test "persistence round trips cached metadata and rejects truncation" {
    var source = Store{};
    var bookmark = try Bookmark.init("", "https://tigerbeetle.com", "systems", "Read later");
    bookmark.favorite = true;
    bookmark.open_count = 7;
    try bookmark.description.set("A database.");
    try bookmark.preview.set("Reliable financial transactions.");
    try source.add(bookmark);
    var buffer: [4_096]u8 = undefined;
    const encoded = try encode(&source, &buffer);

    var target = Store{};
    try decode(encoded, &target);
    try std.testing.expectEqual(@as(u16, 1), target.count);
    try std.testing.expect(target.items[0].favorite);
    try std.testing.expectEqualStrings("A database.", target.items[0].description.bytes());
    try std.testing.expectError(
        error.InvalidStorage,
        decode(encoded[0 .. encoded.len - 1], &target),
    );
}
