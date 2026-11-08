const std = @import("std");
const builtin = @import("builtin");
const FixedText = @import("data").FixedText;
const fetcher = @import("fetcher.zig");
const limits = @import("limits.zig");
const model = @import("model.zig");

const Path = FixedText(limits.path_bytes_max);
const FileName = FixedText(48);
const Outcome = union(enum) { success, failure: anyerror };
const ResultQueue = std.Io.Queue(Outcome);

pub const State = enum { idle, loading, ready, failed };

pub const Loader = struct {
    io: std.Io,
    client: std.http.Client,
    task: std.Io.Group = .init,
    result_buffer: [1]Outcome = undefined,
    results: ResultQueue = undefined,
    state: State = .idle,
    requested_url: model.ImageUrl = .{},
    directory: Path = .{},
    file_name: FileName = .{},
    metadata_name: FileName = .{},
    source_name: FileName = .{},
    file_path: Path = .{},
    metadata_path: Path = .{},
    response: [limits.image_response_bytes_max]u8 = undefined,
    redirect_buffer: [8 * 1_024]u8 = undefined,

    pub fn init_in_place(
        self: *Loader,
        allocator: std.mem.Allocator,
        io: std.Io,
        paths: *const @import("data").Paths,
    ) !void {
        self.io = io;
        self.client = .{ .allocator = allocator, .io = io };
        self.task = .init;
        self.results = .init(&self.result_buffer);
        self.state = .idle;
        self.requested_url = .{};
        self.file_name = .{};
        self.metadata_name = .{};
        self.source_name = .{};
        self.file_path = .{};
        self.metadata_path = .{};
        // Downloaded images are a cache: they come back on the next fetch.
        const directory = try std.fmt.bufPrint(
            &self.directory.buffer,
            "{s}/rss-images",
            .{paths.cache.bytes()},
        );
        self.directory.length = @intCast(directory.len);
    }

    pub fn deinit(self: *Loader) void {
        self.task.cancel(self.io);
        self.results.close(self.io);
        self.client.deinit();
    }

    pub fn request(self: *Loader, url: []const u8) !bool {
        if (url.len == 0) return false;
        if (std.mem.eql(u8, self.requested_url.bytes(), url)) return false;
        if (self.state == .loading) return false;
        model.set_truncated(&self.requested_url, url);
        try self.set_paths(url);
        if (!try self.cache_matches(url)) return self.start_fetch();
        self.state = .ready;
        return true;
    }

    pub fn poll(self: *Loader) !bool {
        if (self.state != .loading) return false;
        var completed: [1]Outcome = undefined;
        const count = self.results.get(self.io, &completed, 0) catch |err| {
            return switch (err) {
                error.Closed => false,
                error.Canceled => err,
            };
        };
        if (count == 0) return false;
        try self.task.await(self.io);
        self.state = switch (completed[0]) {
            .success => .ready,
            .failure => .failed,
        };
        return true;
    }

    pub fn ready_path(self: *const Loader, url: []const u8) ?[]const u8 {
        if (self.state != .ready) return null;
        if (!std.mem.eql(u8, self.requested_url.bytes(), url)) return null;
        return self.file_path.bytes();
    }

    fn set_paths(self: *Loader, url: []const u8) !void {
        const hash = std.hash.Wyhash.hash(0, url);
        const slot = hash % limits.image_cache_slots_max;
        const file_name = try std.fmt.bufPrint(
            &self.file_name.buffer,
            "slot-{d:0>2}.png",
            .{slot},
        );
        self.file_name.length = @intCast(file_name.len);
        const metadata_name = try std.fmt.bufPrint(
            &self.metadata_name.buffer,
            "slot-{d:0>2}.url",
            .{slot},
        );
        self.metadata_name.length = @intCast(metadata_name.len);
        const source_name = try std.fmt.bufPrint(
            &self.source_name.buffer,
            "slot-{d:0>2}.source",
            .{slot},
        );
        self.source_name.length = @intCast(source_name.len);
        const path = try std.fmt.bufPrint(
            &self.file_path.buffer,
            "{s}/{s}",
            .{ self.directory.bytes(), self.file_name.bytes() },
        );
        self.file_path.length = @intCast(path.len);
        const metadata_path = try std.fmt.bufPrint(
            &self.metadata_path.buffer,
            "{s}/{s}",
            .{ self.directory.bytes(), self.metadata_name.bytes() },
        );
        self.metadata_path.length = @intCast(metadata_path.len);
    }

    fn cache_matches(self: *Loader, url: []const u8) !bool {
        if (!try valid_png_file(self.io, self.file_path.bytes())) return false;
        var metadata: [limits.article_image_url_bytes_max]u8 = undefined;
        const value = @import("data").cwd().readFile(
            self.io,
            self.metadata_path.bytes(),
            &metadata,
        ) catch |err| {
            if (err == error.FileNotFound) return false;
            return err;
        };
        return std.mem.eql(u8, value, url);
    }

    fn start_fetch(self: *Loader) !bool {
        try fetcher.prepare_tls(&self.client);
        self.task.concurrent(
            self.io,
            image_task,
            .{self},
        ) catch |err| {
            self.state = .failed;
            return err;
        };
        self.state = .loading;
        return true;
    }
};

fn image_task(loader: *Loader) std.Io.Cancelable!void {
    const outcome: Outcome = if (fetch_image(loader))
        .success
    else |err|
        .{ .failure = err };
    loader.results.putOne(loader.io, outcome) catch |err| switch (err) {
        error.Closed => return,
        error.Canceled => return error.Canceled,
    };
}

fn fetch_image(loader: *Loader) !void {
    var writer = std.Io.Writer.fixed(&loader.response);
    const result = try @import("data").http.fetch(&loader.client, .{
        .url = loader.requested_url.bytes(),
        .response_writer = &writer,
        .redirect_buffer = &loader.redirect_buffer,
        .user_agent = "markix-rss/0.1",
    });
    if (result.status.class() != .success) return error.ImageRequestFailed;
    const bytes = writer.buffered();
    if (bytes.len == loader.response.len) return error.ImageResponseTooLarge;
    try @import("data").cwd().createDirPath(loader.io, loader.directory.bytes());
    if (is_png(bytes)) {
        try write_atomic(loader, loader.file_name.bytes(), bytes);
    } else {
        try write_atomic(loader, loader.source_name.bytes(), bytes);
        defer std.Io.Dir.deleteFileAbsolute(
            loader.io,
            source_path(loader),
        ) catch {};
        try convert_to_png(loader);
    }
    if (!try valid_png_file(loader.io, loader.file_path.bytes())) {
        return error.InvalidConvertedImage;
    }
    try write_atomic(
        loader,
        loader.metadata_name.bytes(),
        loader.requested_url.bytes(),
    );
}

fn write_atomic(loader: *Loader, name: []const u8, bytes: []const u8) !void {
    var directory = try std.Io.Dir.openDirAbsolute(
        loader.io,
        loader.directory.bytes(),
        .{},
    );
    defer directory.close(loader.io);
    var atomic_file = try directory.createFileAtomic(
        loader.io,
        name,
        .{ .replace = true },
    );
    defer atomic_file.deinit(loader.io);
    try atomic_file.file.writeStreamingAll(loader.io, bytes);
    try atomic_file.replace(loader.io);
}

fn convert_to_png(loader: *Loader) !void {
    const command = switch (builtin.os.tag) {
        .macos => "/usr/bin/sips",
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => "magick",
        else => return error.ImageConversionUnsupported,
    };
    const arguments: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{
            command,
            "-s",
            "format",
            "png",
            source_path(loader),
            "--out",
            loader.file_path.bytes(),
        },
        else => &.{ command, source_path(loader), loader.file_path.bytes() },
    };
    var child = try std.process.spawn(loader.io, .{
        .argv = arguments,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const termination = try child.wait(loader.io);
    if (!termination.eql(.success)) return error.ImageConversionFailed;
}

fn source_path(loader: *Loader) []const u8 {
    const path = std.fmt.bufPrint(
        &loader.redirect_buffer,
        "{s}/{s}",
        .{ loader.directory.bytes(), loader.source_name.bytes() },
    ) catch return "";
    return path;
}

fn is_png(bytes: []const u8) bool {
    const signature = "\x89PNG\r\n\x1a\n";
    return std.mem.startsWith(u8, bytes, signature);
}

fn valid_png_file(io: std.Io, path: []const u8) !bool {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) return false;
        return err;
    };
    defer file.close(io);
    var signature: [8]u8 = undefined;
    const count = try file.readPositionalAll(io, &signature, 0);
    return count == signature.len and is_png(&signature);
}

test "image cache paths are stable and slot-bounded" {
    var loader: Loader = undefined;
    try loader.init_in_place(std.testing.allocator, std.testing.io, &@import("data").paths.testing_paths);
    defer loader.deinit();
    try loader.set_paths("https://example.com/one.jpg");
    const first_path = loader.file_path.bytes();
    var first: [limits.path_bytes_max]u8 = undefined;
    @memcpy(first[0..first_path.len], first_path);
    try loader.set_paths("https://example.com/one.jpg");
    try std.testing.expectEqualStrings(first[0..first_path.len], loader.file_path.bytes());
    try loader.set_paths("https://example.com/two.jpg");
    try std.testing.expect(std.mem.endsWith(u8, loader.file_path.bytes(), ".png"));
}
