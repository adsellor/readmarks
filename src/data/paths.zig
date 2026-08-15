const std = @import("std");
const limits = @import("limits.zig");
const FixedText = @import("bookmarks/fixed_text.zig").FixedText;

pub const Path = FixedText(limits.path_bytes_max);

/// Directory the application owns inside each base directory.
pub const application_directory = "readmarks";

/// Where the application kept everything before it followed the base directory
/// specification. Read from when the new location holds nothing yet, so an
/// upgrade keeps its bookmarks and read marks; never written to.
pub const legacy_directory = ".markix";

pub const Environment = struct {
    home: []const u8,
    config_home: ?[]const u8 = null,
    data_home: ?[]const u8 = null,
    cache_home: ?[]const u8 = null,
};

/// Where the application keeps its files, following the XDG base directory
/// specification.
///
/// Three roots because the three kinds of file have three different fates. The
/// feed list is written by hand and belongs with a user's dotfiles, so it is
/// configuration. Bookmarks and read marks cannot be recovered by refetching,
/// so they are data. The article cache and downloaded images can, so they are
/// cache, and a user is free to delete them.
pub const Paths = struct {
    config: Path,
    data: Path,
    cache: Path,
    legacy: Path,

    pub fn resolve(environment: Environment) !Paths {
        return .{
            .config = try root(
                environment.config_home,
                environment.home,
                ".config",
            ),
            .data = try root(
                environment.data_home,
                environment.home,
                ".local/share",
            ),
            .cache = try root(
                environment.cache_home,
                environment.home,
                ".cache",
            ),
            .legacy = try join_path(environment.home, legacy_directory),
        };
    }

    /// The layout a home directory alone implies, which is the layout the
    /// specification defines when nothing is exported.
    pub fn under_home(home: []const u8) !Paths {
        return resolve(.{ .home = home });
    }
};

/// The layout tests run against: a home under the system temporary directory,
/// with nothing exported, so a test writes where a default install would.
pub const testing_paths: Paths = Paths.under_home("/tmp") catch unreachable;

/// `<base>/readmarks`, where the base is the exported variable when it names
/// one and the specification's default otherwise. An exported but empty
/// variable counts as unset, which the specification requires.
fn root(exported: ?[]const u8, home: []const u8, fallback: []const u8) !Path {
    if (exported) |value| {
        if (value.len > 0) return join_path(value, application_directory);
    }
    var buffer: [limits.path_bytes_max]u8 = undefined;
    const base = try std.fmt.bufPrint(&buffer, "{s}/{s}", .{ home, fallback });
    return join_path(base, application_directory);
}

fn join_path(directory: []const u8, name: []const u8) !Path {
    var buffer: [limits.path_bytes_max]u8 = undefined;
    return Path.init(try std.fmt.bufPrint(
        &buffer,
        "{s}/{s}",
        .{ directory, name },
    ));
}

/// A file inside one of the roots. The buffer belongs to the caller: a path is
/// built where it is used rather than held.
pub fn file(
    buffer: *[limits.path_bytes_max]u8,
    directory: []const u8,
    name: []const u8,
) ![]const u8 {
    std.debug.assert(directory.len > 0);
    std.debug.assert(name.len > 0);
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ directory, name });
}

test "each root follows its exported variable" {
    const paths = try Paths.resolve(.{
        .home = "/home/reader",
        .config_home = "/config",
        .data_home = "/data",
        .cache_home = "/cache",
    });
    try std.testing.expectEqualStrings("/config/readmarks", paths.config.bytes());
    try std.testing.expectEqualStrings("/data/readmarks", paths.data.bytes());
    try std.testing.expectEqualStrings("/cache/readmarks", paths.cache.bytes());
}

test "unset and empty variables fall back to the specified defaults" {
    const unset = try Paths.under_home("/home/reader");
    try std.testing.expectEqualStrings(
        "/home/reader/.config/readmarks",
        unset.config.bytes(),
    );
    try std.testing.expectEqualStrings(
        "/home/reader/.local/share/readmarks",
        unset.data.bytes(),
    );
    try std.testing.expectEqualStrings(
        "/home/reader/.cache/readmarks",
        unset.cache.bytes(),
    );
    try std.testing.expectEqualStrings("/home/reader/.markix", unset.legacy.bytes());

    const empty = try Paths.resolve(.{ .home = "/home/reader", .cache_home = "" });
    try std.testing.expectEqualStrings(
        "/home/reader/.cache/readmarks",
        empty.cache.bytes(),
    );
}

test "a file sits inside the root it belongs to" {
    const paths = try Paths.under_home("/home/reader");
    var buffer: [limits.path_bytes_max]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/home/reader/.config/readmarks/feeds",
        try file(&buffer, paths.config.bytes(), "feeds"),
    );
    try std.testing.expectEqualStrings(
        "/home/reader/.cache/readmarks/rss-cache.bin",
        try file(&buffer, paths.cache.bytes(), "rss-cache.bin"),
    );
}
