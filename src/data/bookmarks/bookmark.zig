const std = @import("std");
const limits = @import("../limits.zig");
const page = @import("../page.zig");
const FixedText = @import("fixed_text.zig").FixedText;

pub const Title = FixedText(limits.bookmark_title_bytes_max);
pub const Url = FixedText(limits.bookmark_url_bytes_max);
pub const Tags = FixedText(limits.bookmark_tags_bytes_max);
pub const Notes = FixedText(limits.bookmark_notes_bytes_max);
pub const Description = FixedText(limits.bookmark_description_bytes_max);
pub const Preview = FixedText(limits.bookmark_preview_bytes_max);

pub const Bookmark = struct {
    title: Title,
    url: Url,
    tags: Tags,
    notes: Notes,
    description: Description = .{},
    preview: Preview = .{},
    custom_title: bool,
    favorite: bool = false,
    open_count: u32 = 0,

    pub fn init(
        title: []const u8,
        url: []const u8,
        tags: []const u8,
        notes: []const u8,
    ) !Bookmark {
        if (!valid_url(url)) return error.InvalidUrl;
        const custom_title = title.len > 0;
        return .{
            .title = try Title.init(if (custom_title) title else fallback_title(url)),
            .url = try Url.init(url),
            .tags = try Tags.init(tags),
            .notes = try Notes.init(notes),
            .custom_title = custom_title,
        };
    }

    pub fn apply_metadata(self: *Bookmark, metadata: *const page.Metadata) void {
        if (!self.custom_title and !metadata.title.is_empty()) {
            self.title.set(metadata.title.bytes()) catch unreachable;
        }
        self.description.set(metadata.description.bytes()) catch unreachable;
        self.preview.set(metadata.preview.bytes()) catch unreachable;
    }

    pub fn matches(self: *const Bookmark, query: []const u8) bool {
        if (query.len == 0) return true;
        return contains_ignore_case(self.title.bytes(), query) or
            contains_ignore_case(self.url.bytes(), query) or
            contains_ignore_case(self.tags.bytes(), query) or
            contains_ignore_case(self.notes.bytes(), query) or
            contains_ignore_case(self.description.bytes(), query) or
            contains_ignore_case(self.preview.bytes(), query);
    }

    pub fn host(self: *const Bookmark) []const u8 {
        const url = self.url.bytes();
        const scheme_end = std.mem.indexOf(u8, url, "://");
        const start = if (scheme_end) |index| index + 3 else 0;
        const path_start = std.mem.indexOfScalarPos(u8, url, start, '/') orelse
            url.len;
        return url[start..path_start];
    }

    pub fn has_tag(self: *const Bookmark, expected: []const u8) bool {
        var tags = std.mem.splitScalar(u8, self.tags.bytes(), ',');
        while (tags.next()) |raw_tag| {
            const tag = std.mem.trim(u8, raw_tag, " \t");
            if (std.ascii.eqlIgnoreCase(tag, expected)) return true;
        }
        return false;
    }
};

fn fallback_title(url: []const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://");
    const start = if (scheme_end) |index| index + 3 else 0;
    const path_start = std.mem.indexOfScalarPos(u8, url, start, '/') orelse url.len;
    const host = url[start..path_start];
    return if (host.len > 0) host else url;
}

pub fn valid_url(url: []const u8) bool {
    if (url.len < 4) return false;
    return std.mem.startsWith(u8, url, "https://") or
        std.mem.startsWith(u8, url, "http://") or
        std.mem.startsWith(u8, url, "file://");
}

fn contains_ignore_case(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    const variants = [_]u8{
        std.ascii.toLower(needle[0]),
        std.ascii.toUpper(needle[0]),
    };
    var start: usize = 0;
    while (std.mem.indexOfAnyPos(u8, haystack, start, &variants)) |position| {
        if (matches_ignore_case(haystack[position..], needle)) return true;
        start = position + 1;
    }
    return false;
}

fn matches_ignore_case(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (needle, 0..) |byte, index| {
        if (std.ascii.toLower(haystack[index]) != std.ascii.toLower(byte)) return false;
    }
    return true;
}

test "bookmark validates and searches fields" {
    var bookmark = try Bookmark.init(
        "Tiger Style",
        "https://github.com/tigerbeetle/tigerbeetle",
        "zig,systems",
        "Read the engineering guide",
    );
    try std.testing.expect(bookmark.matches("TIGER"));
    try std.testing.expect(bookmark.matches("SYSTEMS"));
    try std.testing.expect(bookmark.has_tag("ZIG"));
    try std.testing.expectEqualStrings("github.com", bookmark.host());
    try std.testing.expectError(
        error.InvalidUrl,
        Bookmark.init("", "github.com", "", ""),
    );
}

test "page metadata supplies a non-custom title and content preview" {
    var bookmark = try Bookmark.init("", "https://example.com/path", "", "");
    var metadata = page.Metadata{};
    try metadata.title.set("Example page");
    try metadata.description.set("A useful description.");
    try metadata.preview.set("The readable page contents.");
    bookmark.apply_metadata(&metadata);
    try std.testing.expectEqualStrings("Example page", bookmark.title.bytes());
    try std.testing.expectEqualStrings("The readable page contents.", bookmark.preview.bytes());
    try std.testing.expect(!bookmark.custom_title);
}

test "page metadata preserves a custom title" {
    var bookmark = try Bookmark.init("Mine", "https://example.com", "", "");
    var metadata = page.Metadata{};
    try metadata.title.set("Remote title");
    bookmark.apply_metadata(&metadata);
    try std.testing.expectEqualStrings("Mine", bookmark.title.bytes());
    try std.testing.expect(bookmark.custom_title);
}
