const std = @import("std");
const limits = @import("../limits.zig");
const Bookmark = @import("bookmark.zig").Bookmark;

pub const Store = struct {
    items: [limits.bookmark_count_max]Bookmark = undefined,
    count: u16 = 0,

    pub fn add(self: *Store, bookmark: Bookmark) !void {
        if (self.count >= limits.bookmark_count_max) return error.StoreFull;
        if (self.find_url(bookmark.url.bytes()) != null) {
            return error.DuplicateBookmark;
        }
        self.items[self.count] = bookmark;
        self.count += 1;
    }

    pub fn remove(self: *Store, index: u16) !void {
        if (index >= self.count) return error.IndexOutOfBounds;
        var cursor = index;
        while (cursor + 1 < self.count) : (cursor += 1) {
            self.items[cursor] = self.items[cursor + 1];
        }
        self.count -= 1;
    }

    pub fn get(self: *Store, index: u16) ?*Bookmark {
        if (index >= self.count) return null;
        return &self.items[index];
    }

    fn find_url(self: *const Store, url: []const u8) ?u16 {
        var index: u16 = 0;
        while (index < self.count) : (index += 1) {
            if (std.mem.eql(u8, self.items[index].url.bytes(), url)) return index;
        }
        return null;
    }
};

test "store rejects duplicates and removes bookmarks" {
    var store = Store{};
    try store.add(try Bookmark.init("Alpha", "https://alpha.test", "one", ""));
    try store.add(try Bookmark.init("Beta", "https://beta.test", "two", ""));
    try std.testing.expectError(
        error.DuplicateBookmark,
        store.add(try Bookmark.init("Duplicate", "https://beta.test", "", "")),
    );
    try store.remove(0);
    try std.testing.expectEqual(@as(u16, 1), store.count);
    try std.testing.expectEqualStrings("Beta", store.items[0].title.bytes());
}
