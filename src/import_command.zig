const std = @import("std");
const data = @import("data");
const limits = @import("reader/limits.zig");
const model = @import("reader/model.zig");
const import = @import("reader/import.zig");
const subscriptions = @import("reader/subscriptions.zig");

// `readmarks import <file>...`
//
// Reads another tool's subscription list and merges it into readmarks' own, in
// place: the feed list already on disk is loaded first, so importing adds to it
// rather than replacing it, and a feed that is already there is left alone.
// That makes running an import twice harmless, which matters because the first
// thing anyone does after an import is run it again with the other file.

const Options = struct {
    format: import.Format = .auto,
    /// Report what would change without writing anything.
    dry_run: bool = false,
};

/// Everything the command reads or writes lives here rather than on the stack:
/// a feed list and its parse buffer are megabytes together, and the reader's
/// stack is sized for feed parsing, not for this.
const Workspace = struct {
    feeds: [limits.feed_count_max]model.Feed = undefined,
    keep: [limits.feed_count_max]bool = @splat(true),
    source: [limits.feed_response_bytes_max]u8 = undefined,
    storage: [limits.feed_response_bytes_max]u8 = undefined,
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const data.Paths,
    arguments: *std.process.Args.Iterator,
) !void {
    const workspace = try allocator.create(Workspace);
    defer allocator.destroy(workspace);
    workspace.* = .{};

    var options = Options{};
    var path_buffer: [data.limits.path_bytes_max]u8 = undefined;
    const destination = try data.paths.file(
        &path_buffer,
        paths.config.bytes(),
        subscriptions.file_name,
    );

    // The list already on disk is the starting point, so an import adds to it.
    var feed_count: u16 = 0;
    if (subscriptions.load(
        io,
        destination,
        &workspace.feeds,
        &workspace.storage,
    )) |loaded| {
        feed_count = loaded.count;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const started_with = feed_count;

    var totals = import.Result{};
    var files: u16 = 0;
    while (arguments.next()) |argument| {
        if (try parse_option(io, argument, &options)) continue;
        files += 1;
        const source = data.cwd().readFile(
            io,
            argument,
            &workspace.source,
        ) catch |err| {
            try report(io, "readmarks import: cannot read ", argument);
            try report(io, "  ", @errorName(err));
            return error.Reported;
        };
        if (source.len == workspace.source.len) return error.ImportFileTooLarge;
        const result = try import.merge(
            source,
            options.format,
            &workspace.feeds,
            &feed_count,
        );
        try report_file(io, argument, result);
        totals.added += result.added;
        totals.duplicates += result.duplicates;
        totals.skipped += result.skipped;
    }
    if (files == 0) {
        try write(io, "readmarks import: give it a file to import\n");
        return error.Reported;
    }
    if (options.dry_run) {
        try write(io, "Nothing written: this was a dry run.\n");
        return;
    }
    if (totals.added == 0) {
        try write(io, "Nothing new to add; the feed list is unchanged.\n");
        return;
    }
    try subscriptions.save(
        io,
        destination,
        &workspace.feeds,
        feed_count,
        &workspace.keep,
        &workspace.storage,
    );
    try report_totals(io, destination, started_with, feed_count, totals);
}

fn parse_option(io: std.Io, argument: []const u8, options: *Options) !bool {
    if (!std.mem.startsWith(u8, argument, "-")) return false;
    if (std.mem.eql(u8, argument, "--dry-run")) {
        options.dry_run = true;
        return true;
    }
    const prefix = "--format=";
    if (std.mem.startsWith(u8, argument, prefix)) {
        const name = argument[prefix.len..];
        options.format = import.Format.parse(name) orelse {
            try report(io, "readmarks import: unknown format ", name);
            try write(io, "Formats: auto, opml, newsboat, list, readmarks\n");
            return error.Reported;
        };
        return true;
    }
    try report(io, "readmarks import: unknown option ", argument);
    return error.Reported;
}

fn report_file(io: std.Io, path: []const u8, result: import.Result) !void {
    var buffer: [512]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buffer,
        "{s}: read as {s}, {d} added, {d} already there, {d} skipped\n",
        .{
            path,
            @tagName(result.format),
            result.added,
            result.duplicates,
            result.skipped,
        },
    ) catch return;
    try write(io, line);
}

fn report_totals(
    io: std.Io,
    destination: []const u8,
    started_with: u16,
    feed_count: u16,
    totals: import.Result,
) !void {
    var buffer: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buffer,
        "{s}: {d} feeds ({d} added to {d}).\n",
        .{ destination, feed_count, totals.added, started_with },
    ) catch return;
    try write(io, line);
}

fn report(io: std.Io, message: []const u8, detail: []const u8) !void {
    try write(io, message);
    try write(io, detail);
    try write(io, "\n");
}

fn write(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}
