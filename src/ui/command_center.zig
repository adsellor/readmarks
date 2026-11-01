const std = @import("std");
const markix = @import("markix");
const theme = @import("../theme.zig");
const tokens = @import("tokens.zig");
const fuzzy = @import("fuzzy.zig");
const pane = @import("pane.zig");
const node = @import("node.zig");
const field = @import("field.zig");
const header = @import("header.zig");

const Tree = node.Tree;
const Index = node.Index;
const Rect = node.Rect;
const Key = markix.Key;

pub const results_row: u16 = 2;
pub const filtered_results_row: u16 = 4;
const filter_label_width: u16 = 8;

pub fn first_result_row(filters: bool) u16 {
    return if (filters) filtered_results_row else results_row;
}

pub const Outcome = enum {
    consumed,
    query_changed,
    activate,
    input_changed,
    submit,
    close,
    quit,
};

pub const Stage = enum { picking, collecting };

pub fn Center(
    comptime Result: type,
    comptime capacity: u16,
    comptime query_bytes: usize,
) type {
    return struct {
        const Self = @This();
        pub const Input = markix.widgets.TextInput(query_bytes);
        pub const result_capacity: u16 = capacity;

        open: bool = false,
        stage: Stage = .picking,
        input: Input = .{},
        results: [capacity]Result = undefined,
        ranks: [capacity]u16 = undefined,
        order: [capacity]u16 = undefined,
        count: u16 = 0,
        selected: u16 = 0,
        scroll: u16 = 0,
        viewport: u16 = 1,

        pub fn is_open(self: *const Self) bool {
            return self.open;
        }

        pub fn begin(self: *Self) void {
            self.reset();
            self.open = true;
        }

        pub fn close(self: *Self) void {
            self.reset();
            self.open = false;
        }

        fn reset(self: *Self) void {
            self.stage = .picking;
            self.input.clear();
            self.count = 0;
            self.selected = 0;
            self.scroll = 0;
        }

        pub fn collect(self: *Self) void {
            self.reset();
            self.open = true;
            self.stage = .collecting;
        }

        pub fn is_collecting(self: *const Self) bool {
            return self.open and self.stage == .collecting;
        }

        pub fn query(self: *const Self) []const u8 {
            return self.input.value();
        }

        pub fn reset_results(self: *Self) void {
            self.count = 0;
        }

        pub fn append(self: *Self, result: Result, relevance: u16) void {
            std.debug.assert(self.open);
            std.debug.assert(self.count < capacity);
            if (self.count >= capacity) return;
            self.results[self.count] = result;
            self.ranks[self.count] = relevance;
            self.order[self.count] = self.count;
            self.count += 1;
        }

        pub fn finish_results(self: *Self) void {
            std.debug.assert(self.count <= capacity);
            self.rank_results();
            self.selected = 0;
            self.scroll = 0;
            self.ensure_visible();
            std.debug.assert(self.selected == 0);
            std.debug.assert(self.scroll == 0);
        }

        fn rank_results(self: *Self) void {
            if (self.count < 2) return;
            std.debug.assert(self.count <= capacity);
            const slice = self.order[0..self.count];
            std.mem.sortUnstable(u16, slice, self, less_than);
            var sorted: [capacity]Result = undefined;
            for (slice, 0..) |source, target| sorted[target] = self.results[source];
            @memcpy(self.results[0..self.count], sorted[0..self.count]);
        }

        fn less_than(self: *const Self, left: u16, right: u16) bool {
            if (self.ranks[left] != self.ranks[right]) {
                return self.ranks[left] > self.ranks[right];
            }
            return left < right;
        }

        pub fn selected_result(self: *const Self) ?Result {
            if (self.selected >= self.count) return null;
            return self.results[self.selected];
        }

        pub fn move(self: *Self, delta: i16) void {
            if (self.count == 0) return;
            std.debug.assert(self.selected < self.count);
            const next = @as(i32, self.selected) + delta;
            self.selected = @intCast(std.math.clamp(
                next,
                0,
                @as(i32, self.count) - 1,
            ));
            self.ensure_visible();
        }

        pub fn set_viewport_rows(self: *Self, rows: u16) void {
            self.viewport = @max(rows, 1);
            std.debug.assert(self.viewport > 0);
            self.ensure_visible();
        }

        fn ensure_visible(self: *Self) void {
            std.debug.assert(self.viewport > 0);
            if (self.selected < self.scroll) self.scroll = self.selected;
            const visible_end = @as(u32, self.scroll) + self.viewport;
            if (self.selected >= visible_end) {
                self.scroll = self.selected - self.viewport + 1;
            }
        }

        pub fn handle(
            self: *Self,
            key: Key,
            bindings: Bindings,
        ) !Outcome {
            std.debug.assert(bindings.previous_control.len > 0);
            std.debug.assert(self.count <= capacity);
            if (key == .control) {
                const byte = key.control;
                if (std.mem.indexOfScalar(u8, bindings.quit_control, byte) != null) {
                    return .quit;
                }
                if (std.mem.indexOfScalar(u8, bindings.previous_control, byte) != null) {
                    self.move(-1);
                    return .consumed;
                }
                if (std.mem.indexOfScalar(u8, bindings.next_control, byte) != null) {
                    self.move(1);
                    return .consumed;
                }
            }
            if (key_matches(key, bindings.close)) return .close;
            if (self.stage == .collecting) {
                if (key_matches(key, bindings.activate)) return .submit;
                const typed = self.input.handle(key) catch return .consumed;
                return if (typed == .changed) .input_changed else .consumed;
            }
            if (key_matches(key, bindings.activate)) return .activate;
            if (key_matches(key, bindings.previous)) {
                self.move(-1);
                return .consumed;
            }
            if (key_matches(key, bindings.next)) {
                self.move(1);
                return .consumed;
            }
            const action = self.input.handle(key) catch return .consumed;
            return if (action == .changed) .query_changed else .consumed;
        }
    };
}

pub const Filters = struct {
    items: []const header.Segment,
    selected: u16,
    label: []const u8,
};

pub const Config = struct {
    title: []const u8,
    meta: []const u8,
    prompt: []const u8,
    placeholder: []const u8,
    empty_text: []const u8,
    filters: ?Filters = null,
};

pub const Bindings = struct {
    previous: []const Key,
    next: []const Key,
    previous_control: []const u8,
    next_control: []const u8,
    activate: []const Key,
    close: []const Key,
    quit_control: []const u8,
};

pub fn rank(text: []const u8, query: []const u8) ?u16 {
    std.debug.assert(text.len <= std.math.maxInt(u16));
    std.debug.assert(query.len <= std.math.maxInt(u16));
    if (query.len == 0) return 0;
    if (text.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(text, query)) return 1000;
    if (starts_with_ignore_case(text, query)) {
        return 900 -| @as(u16, @intCast(@min(text.len - query.len, 99)));
    }
    if (index_ignore_case(text, query)) |at| {
        const boundary = at == 0 or text[at - 1] == ' ' or text[at - 1] == '-';
        const base: u16 = if (boundary) 800 else 700;
        return base -| @as(u16, @intCast(@min(at, 99)));
    }
    if (!fuzzy.matches(text, query)) return null;
    const spread = subsequence_spread(text, query) orelse return 400;
    return 500 -| @as(u16, @intCast(@min(spread, 99)));
}

pub fn rank_any(fields: []const []const u8, query: []const u8) ?u16 {
    var best: ?u16 = null;
    for (fields) |text| {
        const value = rank(text, query) orelse continue;
        if (best == null or value > best.?) best = value;
    }
    return best;
}

fn starts_with_ignore_case(text: []const u8, prefix: []const u8) bool {
    if (prefix.len > text.len) return false;
    for (text[0..prefix.len], prefix) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}

fn index_ignore_case(text: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > text.len) return null;
    var start: usize = 0;
    while (start + needle.len <= text.len) : (start += 1) {
        if (starts_with_ignore_case(text[start..], needle)) return start;
    }
    return null;
}

fn subsequence_spread(text: []const u8, query: []const u8) ?usize {
    std.debug.assert(query.len > 0);
    std.debug.assert(query.len <= text.len);
    var first: ?usize = null;
    var last: usize = 0;
    var index: usize = 0;
    for (text, 0..) |byte, position| {
        if (index >= query.len) break;
        if (std.ascii.toLower(byte) != std.ascii.toLower(query[index])) continue;
        if (first == null) first = position;
        last = position;
        index += 1;
    }
    if (index < query.len) return null;
    const start = first orelse return null;
    return (last - start + 1) - query.len;
}

fn key_matches(key: Key, candidates: []const Key) bool {
    for (candidates) |candidate| {
        if (std.meta.activeTag(key) != std.meta.activeTag(candidate)) continue;
        return switch (key) {
            .character => |byte| byte == candidate.character,
            .control => |byte| byte == candidate.control,
            else => true,
        };
    }
    return false;
}

pub fn rect_for(bounds: Rect) Rect {
    return tokens.overlay_rect(bounds, 84, 17);
}

pub fn rows_for(rect: Rect, filters: bool) u16 {
    const visual = tokens.command_list_visual;
    std.debug.assert(visual.row_height > 0);
    const inner = tokens.content_rect(tokens.overlay_chrome, rect);
    const results = @max(0, inner.height - first_result_row(filters));
    const rows = @max(@divFloor(results, visual.row_height), 1);
    return @intCast(@min(rows, pane.rows_max));
}

pub fn filters_rect(rect: Rect) Rect {
    const inner = tokens.content_rect(tokens.overlay_chrome, rect);
    const offset = filter_label_width + 1;
    return Rect.init(inner.x + offset, inner.y + 2, @max(0, inner.width - offset), 1);
}

pub fn results_rect(rect: Rect, filters: bool) Rect {
    const inner = tokens.content_rect(tokens.overlay_chrome, rect);
    const top = first_result_row(filters);
    return Rect.init(inner.x, inner.y + top, inner.width, @max(0, inner.height - top));
}

pub const Surface = struct {
    panel: pane.Panel,
    results: Index,
    width: i32,
};

pub fn surface(tree: *Tree, rect: Rect, config: Config, query: []const u8, cursor: u16) !Surface {
    std.debug.assert(tree.len == 0);
    std.debug.assert(cursor <= query.len);
    const palette = theme.palette;
    var frame = pane.frame_for(.command, true);
    frame.chrome = tokens.overlay_chrome;
    frame.title = config.title;
    frame.meta = config.meta;
    const panel = try pane.floating(tree, rect, frame);
    const inner = tokens.content_rect(tokens.overlay_chrome, rect);
    _ = try field.field(tree, panel.body, .{
        .prompt = config.prompt,
        .placeholder = config.placeholder,
        .value = query,
        .cursor = cursor,
        .look = field.command_look(),
    }, inner.width);
    _ = try node.spacer(tree, panel.body, node.grow, node.fixed(1));
    if (config.filters) |filters| {
        const strip = try node.line(tree, panel.body, .{});
        try header.badge(tree, strip, filters.label, theme.chip(
            palette.inverse_foreground,
            palette.accent_cool,
        ));
        try node.run(tree, strip, " ", .{});
        try header.segments(
            tree,
            strip,
            filters.items,
            filters.selected,
            theme.chip(palette.inverse_foreground, palette.command),
            .{ .foreground = palette.muted, .background = palette.panel, .dim = true },
        );
        _ = try node.spacer(tree, panel.body, node.grow, node.fixed(1));
    }
    const results = try node.box(tree, panel.body, .{});
    return .{ .panel = panel, .results = results, .width = inner.width };
}

pub fn fill(
    tree: *Tree,
    into: Surface,
    rows: u16,
    center: anytype,
    host: anytype,
    empty_text: []const u8,
) !void {
    std.debug.assert(rows <= pane.rows_max);
    std.debug.assert(center.count <= @TypeOf(center.*).result_capacity);
    var highlight = center.query();
    var scan: u16 = 0;
    while (scan < rows and center.scroll + scan < center.count) : (scan += 1) {
        const title = host.command_result_title(center.results[center.scroll + scan]);
        if (pane.is_ascii(title)) continue;
        highlight = "";
        break;
    }
    const list = pane.List{
        .role = .command,
        .focused = true,
        .empty_text = empty_text,
        .highlight = highlight,
        .visual = tokens.command_list_visual,
        .item_count = center.count,
        .scroll = center.scroll,
        .selected = center.selected,
    };
    if (center.count == 0) return pane.empty(tree, into.results, list);
    var row: u16 = 0;
    while (row < rows and center.scroll + row < center.count) : (row += 1) {
        const index = center.scroll + row;
        const result = center.results[index];
        try pane.item(tree, into.results, list, into.width, .{
            .title = host.command_result_title(result),
            .subtitle = host.command_result_detail(result),
            .marker = host.command_result_marker(result),
        }, index == center.selected);
    }
}

pub fn filter_hit_boxes(rect: Rect, items: []const header.Segment, out: []Rect) u8 {
    std.debug.assert(items.len <= std.math.maxInt(u8));
    std.debug.assert(out.len <= std.math.maxInt(u8));
    var column: i32 = 0;
    var index: u8 = 0;
    while (index < items.len and index < out.len) : (index += 1) {
        if (column >= rect.width) break;
        const width = @min(node.columns(items[index].label) + 2, rect.width - column);
        out[index] = Rect.init(rect.x + column, rect.y, width, 1);
        column += width + 1;
    }
    return index;
}

const TestResult = struct { index: u16 };
const test_bindings = @import("../command.zig").bindings;
const TestCenter = Center(TestResult, 8, 32);
test "the centre moves, wraps its viewport and reports what a key meant" {
    var center = TestCenter{};
    center.begin();
    center.set_viewport_rows(2);
    var index: u16 = 0;
    while (index < 5) : (index += 1) center.append(.{ .index = index }, 0);
    center.finish_results();

    try std.testing.expectEqual(Outcome.consumed, try center.handle(.down, test_bindings));
    try std.testing.expectEqual(@as(u16, 1), center.selected);
    try std.testing.expectEqual(
        Outcome.consumed,
        try center.handle(.{ .control = 'n' }, test_bindings),
    );
    try std.testing.expectEqual(@as(u16, 2), center.selected);
    try std.testing.expectEqual(@as(u16, 1), center.scroll);
    try std.testing.expectEqual(Outcome.activate, try center.handle(.enter, test_bindings));
    try std.testing.expectEqual(Outcome.close, try center.handle(.escape, test_bindings));
    try std.testing.expectEqual(
        Outcome.quit,
        try center.handle(.{ .control = 'c' }, test_bindings),
    );
    try std.testing.expectEqual(
        Outcome.query_changed,
        try center.handle(.{ .character = 'a' }, test_bindings),
    );
    try std.testing.expectEqualStrings("a", center.query());
}

test "fewer results than the selection pulls it back into range" {
    var center = TestCenter{};
    center.begin();
    center.set_viewport_rows(4);
    var index: u16 = 0;
    while (index < 6) : (index += 1) center.append(.{ .index = index }, 0);
    center.finish_results();
    center.move(5);
    try std.testing.expectEqual(@as(u16, 5), center.selected);

    center.reset_results();
    center.append(.{ .index = 0 }, 0);
    center.finish_results();
    try std.testing.expectEqual(@as(u16, 0), center.selected);
    try std.testing.expectEqual(@as(u16, 0), center.scroll);
}

test "ranking puts the tightest match first" {
    const exact = rank("Unread", "Unread").?;
    const prefix = rank("Unread articles", "Unread").?;
    const word = rank("Show Unread", "Unread").?;
    const scattered = rank("Under a red sky", "unred").?;
    try std.testing.expect(exact > prefix);
    try std.testing.expect(prefix > word);
    try std.testing.expect(word > scattered);
    try std.testing.expect(rank("nothing here", "zzz") == null);
}

test "a shorter title outranks a longer one holding the same prefix" {
    try std.testing.expect(rank("Zig News", "zig").? > rank("Zig 0.15 Released", "zig").?);
}

test "results are ordered by rank, not by the order they were gathered" {
    var center = TestCenter{};
    center.begin();
    center.set_viewport_rows(8);
    center.append(.{ .index = 10 }, 400);
    center.append(.{ .index = 11 }, 900);
    center.append(.{ .index = 12 }, 700);
    center.finish_results();
    try std.testing.expectEqual(@as(u16, 11), center.results[0].index);
    try std.testing.expectEqual(@as(u16, 12), center.results[1].index);
    try std.testing.expectEqual(@as(u16, 10), center.results[2].index);
}

test "equal ranks keep the order they were gathered in" {
    var center = TestCenter{};
    center.begin();
    center.set_viewport_rows(8);
    var index: u16 = 0;
    while (index < 5) : (index += 1) center.append(.{ .index = index }, 0);
    center.finish_results();
    index = 0;
    while (index < 5) : (index += 1) {
        try std.testing.expectEqual(index, center.results[index].index);
    }
}

test "a new query puts the selection back on the best match" {
    var center = TestCenter{};
    center.begin();
    center.set_viewport_rows(8);
    var index: u16 = 0;
    while (index < 6) : (index += 1) center.append(.{ .index = index }, 0);
    center.finish_results();
    center.move(3);
    try std.testing.expectEqual(@as(u16, 3), center.selected);

    center.reset_results();
    index = 0;
    while (index < 6) : (index += 1) center.append(.{ .index = 100 + index }, 0);
    center.finish_results();
    try std.testing.expectEqual(@as(u16, 0), center.selected);
    try std.testing.expectEqual(@as(u16, 0), center.scroll);
    try std.testing.expectEqual(@as(u16, 100), center.selected_result().?.index);
}

test "a match stays legible on the row it is selected on" {
    try std.testing.expect(!pane.Role.command.selection(true).eql(theme.palette.command));
}

test "filter hit boxes follow the badges they cover" {
    const items = [_]header.Segment{ .{ .label = "All" }, .{ .label = "Unread" } };
    var boxes: [4]Rect = undefined;
    const count = filter_hit_boxes(Rect.init(10, 4, 40, 1), &items, &boxes);
    try std.testing.expectEqual(@as(u8, 2), count);
    try std.testing.expectEqual(Rect.init(10, 4, 5, 1), boxes[0]);
    try std.testing.expectEqual(Rect.init(16, 4, 8, 1), boxes[1]);
}
