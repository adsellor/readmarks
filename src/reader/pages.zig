//! Where an article's text lives past its first page.
//!
//! The document parser reads a bounded source and emits a bounded number of
//! blocks, so one parse can only ever show so much of an article. Longer
//! articles are therefore cut into pages: the first stays on the article, the
//! rest go into a pool every article shares. Nothing is allocated while the
//! application runs -- the pool is claimed at startup like everything else --
//! so a pool under pressure costs an old article its tail rather than costing
//! a fetch.
//!
//! Pages are keyed by the article's URL rather than by its index. Articles are
//! copied, sorted, compacted, and evicted by value all over the application; a
//! key that travels inside the article itself survives all of it.

const std = @import("std");
const document = @import("document.zig");
const xml = @import("xml.zig");
const limits = @import("limits.zig");
const FixedText = @import("data").FixedText;

pub const Page = FixedText(limits.article_page_bytes_max);

comptime {
    // A page is cut to fit the parser's own ceilings, so every page the pool
    // hands back renders whole. Raising either limit past the parser would put
    // the cut back inside the page, which is the thing pages exist to stop.
    std.debug.assert(limits.article_page_bytes_max <= document.source_bytes_max);
    std.debug.assert(limits.article_page_blocks_max <= document.block_count_max);
}

/// The article a page belongs to. It is the URL's hash, which is what the read
/// state already treats as an article's identity.
pub fn key(url: []const u8) u64 {
    return std.hash.Wyhash.hash(0, url);
}

pub fn Pool(comptime slot_count: u16) type {
    return struct {
        const Self = @This();

        pub const slots_max: u16 = slot_count;

        const Slot = struct {
            key: u64,
            /// Claim order, so a full pool can tell which article's pages have
            /// been sitting here longest.
            stamp: u32,
            /// Which page of the article this is, counting its first as zero.
            /// Nothing here is ever page zero.
            sequence: u16,
            text: Page,
        };

        slots: [slot_count]Slot = undefined,
        /// Live slots are the dense prefix `slots[0..count]`, so nothing here
        /// is ever read while undefined.
        count: u16 = 0,
        next_stamp: u32 = 1,

        pub fn reset(self: *Self) void {
            self.count = 0;
            self.next_stamp = 1;
        }

        /// The article's page `sequence`, or null when it holds no such page.
        pub fn page(self: *const Self, article: u64, sequence: u16) ?[]const u8 {
            var index: u16 = 0;
            while (index < self.count) : (index += 1) {
                const slot = &self.slots[index];
                if (slot.key == article and slot.sequence == sequence) {
                    return slot.text.bytes();
                }
            }
            return null;
        }

        /// Pages held for the article, its first not counted.
        pub fn page_count(self: *const Self, article: u64) u16 {
            var found: u16 = 0;
            var index: u16 = 0;
            while (index < self.count) : (index += 1) {
                if (self.slots[index].key == article) found += 1;
            }
            return found;
        }

        pub fn key_at(self: *const Self, index: u16) u64 {
            std.debug.assert(index < self.count);
            return self.slots[index].key;
        }

        pub fn release(self: *Self, article: u64) void {
            var index: u16 = 0;
            while (index < self.count) {
                if (self.slots[index].key != article) {
                    index += 1;
                    continue;
                }
                self.count -= 1;
                if (index != self.count) self.slots[index] = self.slots[self.count];
            }
        }

        /// Keeps `text` as the article's page `sequence`. Pages are claimed in
        /// order and the caller stops at the first refusal, so an article holds
        /// pages one through n and never a hole in the middle of itself.
        pub fn claim(self: *Self, article: u64, sequence: u16, text: []const u8) bool {
            std.debug.assert(sequence > 0);
            if (text.len > Page.capacity_bytes) return false;
            if (self.count == slot_count and !self.evict(article)) return false;
            std.debug.assert(self.count < slot_count);
            const slot = &self.slots[self.count];
            slot.key = article;
            slot.stamp = self.next_stamp;
            slot.sequence = sequence;
            slot.text.set(text) catch return false;
            self.count += 1;
            self.next_stamp +|= 1;
            return true;
        }

        /// Replaces everything held for the article with what `source` holds
        /// for it. Both pools key pages the same way, so staging a fetch and
        /// keeping it are the same operation twice.
        pub fn adopt(self: *Self, article: u64, source: anytype) void {
            self.release(article);
            var sequence: u16 = 1;
            while (source.page(article, sequence)) |text| : (sequence += 1) {
                if (!self.claim(article, sequence, text)) return;
            }
        }

        /// Frees the pages of whichever article claimed longest ago, so a full
        /// pool gives up an old tail rather than refusing a new one. The
        /// article being written is never the one evicted: an article does not
        /// make room by throwing away the pages it just wrote.
        fn evict(self: *Self, keep: u64) bool {
            var victim: ?u64 = null;
            var oldest: u32 = 0;
            var index: u16 = 0;
            while (index < self.count) : (index += 1) {
                const slot = &self.slots[index];
                if (slot.key == keep) continue;
                if (victim == null or slot.stamp < oldest) {
                    victim = slot.key;
                    oldest = slot.stamp;
                }
            }
            const article = victim orelse return false;
            self.release(article);
            return true;
        }
    };
}

/// Walks a content body one page at a time.
pub const Split = struct {
    source: []const u8,
    cursor: usize = 0,

    pub fn next(self: *Split) ?[]const u8 {
        if (self.cursor >= self.source.len) return null;
        const end = page_end(self.source, self.cursor);
        std.debug.assert(end > self.cursor);
        std.debug.assert(end <= self.source.len);
        const bytes = self.source[self.cursor..end];
        self.cursor = end;
        return bytes;
    }
};

/// Where the page starting at `start` ends.
///
/// The cut lands between blocks -- where the document parser's own walk sits
/// between one element and the next -- so no page opens an element the next
/// page closes. A single block too large for a page is the one case that still
/// splits mid-element: there is no boundary inside it to prefer.
pub fn page_end(source: []const u8, start: usize) usize {
    const capacity = limits.article_page_bytes_max;
    var cursor = start;
    var settled = start;
    var blocks: u16 = 0;
    while (cursor < source.len) {
        const open = std.mem.indexOfScalarPos(u8, source, cursor, '<') orelse break;
        const open_end = std.mem.indexOfScalarPos(u8, source, open, '>') orelse break;
        const name = tag_name(source[open .. open_end + 1]);
        if (std.ascii.eqlIgnoreCase(name, "img")) {
            cursor = open_end + 1;
        } else if (is_block_tag(name)) {
            const close = xml.find_close_tag(source, open_end + 1, name) orelse {
                cursor = open_end + 1;
                continue;
            };
            const close_end = std.mem.indexOfScalarPos(u8, source, close, '>') orelse break;
            cursor = close_end + 1;
        } else {
            cursor = open_end + 1;
            continue;
        }
        // The walk now sits between blocks, so a cut here keeps every element
        // whole. Take it only while the page is still within both ceilings.
        blocks += 1;
        if (cursor - start > capacity or blocks > limits.article_page_blocks_max) {
            if (settled > start) return settled;
            return start + @min(@as(usize, capacity), source.len - start);
        }
        settled = cursor;
    }
    // Whatever trails the last block belongs to this page if it fits.
    if (source.len - start <= capacity) return source.len;
    if (settled > start) return settled;
    return start + capacity;
}

/// The tags the document parser turns into blocks. It is the parser's own
/// list, mirrored here because pagination has to count what it will count.
fn is_block_tag(name: []const u8) bool {
    if (name.len == 2 and
        (name[0] | 0x20) == 'h' and
        name[1] >= '1' and name[1] <= '6') return true;
    const names = [_][]const u8{ "p", "li", "blockquote", "pre", "code", "a" };
    for (names) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

fn tag_name(tag: []const u8) []const u8 {
    if (tag.len < 2) return "";
    var start: usize = 1;
    if (tag[start] == '/') start += 1;
    const end = std.mem.indexOfAnyPos(u8, tag, start, " \t\r\n/>") orelse (tag.len - 1);
    return tag[start..end];
}

/// Builds a body of a known size without leaning on the repeat operator.
inline fn repeated(comptime chunk: []const u8, comptime times: usize) []const u8 {
    comptime var built: []const u8 = "";
    comptime var index: usize = 0;
    inline while (index < times) : (index += 1) built = built ++ chunk;
    return built;
}

test "a body longer than one page splits between whole elements" {
    const paragraph = "<p>" ++ repeated("word ", 400) ++ "</p>";
    const body = repeated(paragraph, 24);
    try std.testing.expect(body.len > limits.article_page_bytes_max);

    var split = Split{ .source = body };
    var seen: usize = 0;
    var page_count: u16 = 0;
    while (split.next()) |page| : (page_count += 1) {
        try std.testing.expect(page.len <= limits.article_page_bytes_max);
        // Every page starts an element and ends one, which is what keeps the
        // parser from meeting a tag the previous page opened.
        try std.testing.expect(std.mem.startsWith(u8, page, "<p>"));
        try std.testing.expect(std.mem.endsWith(u8, page, "</p>"));
        seen += page.len;
    }
    try std.testing.expect(page_count > 1);
    // Pagination moves the cut, it does not drop text.
    try std.testing.expectEqual(body.len, seen);
}

test "a body that fits stays a single page" {
    var split = Split{ .source = "<p>Short enough.</p>" };
    try std.testing.expectEqualStrings("<p>Short enough.</p>", split.next().?);
    try std.testing.expect(split.next() == null);
}

test "a page is cut at the block ceiling before the parser reaches its own" {
    const body = repeated("<p>a</p>", limits.article_page_blocks_max + 40);
    var split = Split{ .source = body };
    const first = split.next() orelse return error.NoPage;
    const blocks = std.mem.count(u8, first, "<p>");
    try std.testing.expect(blocks <= limits.article_page_blocks_max);
    try std.testing.expect(blocks > 0);
    try std.testing.expect(split.next() != null);
}

test "pooled pages survive the article moving and go when it does" {
    const TestPool = Pool(4);
    var pool = try std.testing.allocator.create(TestPool);
    defer std.testing.allocator.destroy(pool);
    pool.* = .{};

    const one = key("https://one.test/article");
    const two = key("https://two.test/article");
    try std.testing.expect(pool.claim(one, 1, "<p>one page two</p>"));
    try std.testing.expect(pool.claim(one, 2, "<p>one page three</p>"));
    try std.testing.expect(pool.claim(two, 1, "<p>two page two</p>"));

    try std.testing.expectEqual(@as(u16, 2), pool.page_count(one));
    try std.testing.expectEqualStrings("<p>one page three</p>", pool.page(one, 2).?);
    try std.testing.expect(pool.page(one, 3) == null);

    pool.release(one);
    try std.testing.expectEqual(@as(u16, 0), pool.page_count(one));
    // Releasing swaps the tail down over the hole, so the survivor is intact.
    try std.testing.expectEqualStrings("<p>two page two</p>", pool.page(two, 1).?);
}

test "a full pool gives up the oldest article rather than the newest" {
    const TestPool = Pool(2);
    var pool = try std.testing.allocator.create(TestPool);
    defer std.testing.allocator.destroy(pool);
    pool.* = .{};

    const old = key("https://old.test/article");
    const new = key("https://new.test/article");
    try std.testing.expect(pool.claim(old, 1, "<p>old</p>"));
    try std.testing.expect(pool.claim(new, 1, "<p>new</p>"));
    try std.testing.expect(pool.claim(new, 2, "<p>new tail</p>"));

    try std.testing.expectEqual(@as(u16, 0), pool.page_count(old));
    try std.testing.expectEqual(@as(u16, 2), pool.page_count(new));

    // Nothing is left to evict but the article being written, and an article
    // does not make room by discarding what it just wrote.
    try std.testing.expect(!pool.claim(new, 3, "<p>refused</p>"));
    try std.testing.expectEqual(@as(u16, 2), pool.page_count(new));
}

test "one pool adopts another's pages for an article" {
    const Staging = Pool(4);
    const Kept = Pool(4);
    var staging = try std.testing.allocator.create(Staging);
    defer std.testing.allocator.destroy(staging);
    var kept = try std.testing.allocator.create(Kept);
    defer std.testing.allocator.destroy(kept);
    staging.* = .{};
    kept.* = .{};

    const article = key("https://example.test/long");
    try std.testing.expect(staging.claim(article, 1, "<p>second</p>"));
    try std.testing.expect(staging.claim(article, 2, "<p>third</p>"));

    kept.adopt(article, staging);
    try std.testing.expectEqual(@as(u16, 2), kept.page_count(article));
    try std.testing.expectEqualStrings("<p>third</p>", kept.page(article, 2).?);

    // Adopting again replaces rather than duplicates, so a refetched article
    // does not accumulate copies of itself.
    kept.adopt(article, staging);
    try std.testing.expectEqual(@as(u16, 2), kept.page_count(article));
}
