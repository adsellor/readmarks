//! The command centre: a fuzzy prompt over everything an experience can do or
//! show. One engine and one surface, configured by whoever mounts it, so `:`
//! means the same thing in the reader as it does in the bookmarker.
//!
//! The host owns what a result *is*. This owns the prompt, the selection, the
//! scrolling and the surface they are drawn on.

const std = @import("std");
const markix = @import("markix");
const dom = markix.dom;
const layout = markix.layout;
const widgets = markix.widgets;
const theme = @import("../theme.zig");
const tokens = @import("tokens.zig");
const pane = @import("pane.zig");

const NodeIndex = dom.DomTree.NodeIndex;
const LayoutElement = layout.LayoutElement;
const Rect = layout.Rect;

/// Row the results start on: below the prompt and a blank row, and below the
/// filter row and another blank row when the surface carries filters.
pub const results_row: u16 = 2;
pub const filtered_results_row: u16 = 4;
const filter_row: u16 = 2;
const filter_badge_width: u16 = 8;

pub fn first_result_row(filters: bool) u16 {
    return if (filters) filtered_results_row else results_row;
}

/// What a key did, so the host can refresh results or run the selection
/// without the engine knowing what either means.
pub const Outcome = enum {
    /// Handled; nothing more to do.
    consumed,
    /// The query changed; the host must refill the results.
    query_changed,
    /// Run the selected result.
    activate,
    input_changed,
    submit,
    /// Leave the command centre.
    close,
    /// Leave the application.
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
        pub const Input = widgets.TextInput(query_bytes);
        pub const result_capacity: u16 = capacity;

        /// Whether the centre is up. Owned here rather than by the host, so
        /// opening and closing it is one call and there is no second flag to
        /// keep in step.
        open: bool = false,
        stage: Stage = .picking,
        input: Input = .{},
        results: [capacity]Result = undefined,
        /// How well each result matched, parallel to `results`. Gathering is
        /// done in whatever order the host walks its collections; ranking puts
        /// the best match first regardless of which collection it came from.
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

        /// Starts a fresh pass of result gathering.
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

        /// Ranks what was gathered and puts the selection on the best match.
        ///
        /// The selection goes back to the top rather than staying where it
        /// was: after typing, the row under the cursor is a different result
        /// than it was a keystroke ago, and leaving the highlight on a stale
        /// index is how a palette runs the wrong thing on Enter.
        pub fn finish_results(self: *Self) void {
            std.debug.assert(self.count <= capacity);
            self.rank_results();
            self.selected = 0;
            self.scroll = 0;
            self.ensure_visible();
            std.debug.assert(self.selected == 0);
            std.debug.assert(self.scroll == 0);
        }

        /// Sorts by rank, keeping gather order among equals so an unranked
        /// listing (the empty query) stays in the order the host built it.
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

        /// Applies a key against the caller's bindings. Anything the bindings
        /// do not claim is text, and goes to the prompt.
        pub fn handle(
            self: *Self,
            key: layout.input.Key,
            bindings: Bindings,
        ) !Outcome {
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

/// Mounted nodes of the command centre's surface.
pub const Slot = struct {
    mounted: bool = false,
    /// Set when the surface floats over the workspace rather than filling a
    /// pane slot, in which case it casts a shadow and owns its own rect.
    floating: bool = false,
    filters: bool = false,
    panel: NodeIndex = 0,
    shadow: NodeIndex = 0,
    input: NodeIndex = 0,
    placeholder: NodeIndex = 0,
    prompt_width: u16 = 0,
    filter_badge: NodeIndex = 0,
    filter_items: NodeIndex = 0,
    results: pane.Slot = .{},
    rect: Rect = Rect.init(0, 0, 0, 0),
    filters_rect: Rect = Rect.init(0, 0, 0, 0),
};

/// The scopes a filtered surface offers, and which one is active.
pub const Filters = struct {
    items: []const widgets.SegmentItem,
    selected: u16,
    label: []const u8,
};

/// Every word on the surface. Deliberately without defaults: what the command
/// centre is called, what it prompts with and what it says when it finds
/// nothing are the caller's decisions, not this component's.
pub const Config = struct {
    title: []const u8,
    meta: []const u8,
    prompt: []const u8,
    placeholder: []const u8,
    empty_text: []const u8,
    filters: ?Filters = null,
};

/// Which keys drive the surface. Also without defaults: the caller owns the
/// keymap, and both experiences pass the same one so the centre answers to the
/// same keys wherever it is opened.
pub const Bindings = struct {
    /// Plain keys that step the selection back and forward.
    previous: []const layout.input.Key,
    next: []const layout.input.Key,
    /// Control characters that step the selection.
    previous_control: []const u8,
    next_control: []const u8,
    activate: []const layout.input.Key,
    close: []const layout.input.Key,
    quit_control: []const u8,
};

/// How well `text` answers `query`, or null when it does not answer at all.
///
/// Ranked rather than merely matched because a subsequence match is very
/// permissive: without this, typing an article's name puts an action whose
/// letters happen to appear in order above the article itself.
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
        // A match at a word start reads as deliberate; one mid-word is weaker.
        const boundary = at == 0 or text[at - 1] == ' ' or text[at - 1] == '-';
        const base: u16 = if (boundary) 800 else 700;
        return base -| @as(u16, @intCast(@min(at, 99)));
    }
    if (!markix.layout.fuzzy.matches(text, query)) return null;
    // A scattered subsequence is the weakest kind of match; tighter ones
    // (fewer characters skipped) still beat looser ones.
    const spread = subsequence_spread(text, query) orelse return 400;
    return 500 -| @as(u16, @intCast(@min(spread, 99)));
}

/// The best rank across several fields, for a result that can match on more
/// than one of them.
pub fn rank_any(fields: []const []const u8, query: []const u8) ?u16 {
    var best: ?u16 = null;
    for (fields) |field| {
        const value = rank(field, query) orelse continue;
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

/// Characters between the first and last matched position, beyond the query's
/// own length: zero for a contiguous run, larger the more scattered the match.
fn subsequence_spread(text: []const u8, query: []const u8) ?usize {
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

fn key_matches(key: layout.input.Key, candidates: []const layout.input.Key) bool {
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

pub const MountOptions = struct {
    prompt_width: u16 = 2,
    /// Box to ask for. A placement is clipped to its parent, so asking for the
    /// frame's width asks for all of whatever slot the surface is given.
    width: u16,
    rows: u16,
    filters: bool = false,
    /// Where to float, relative to the parent. Absent means fill the slot.
    placement: ?Rect = null,
};

/// Rows of results a surface of this size can show.
pub fn rows_for(rect: Rect, filters: bool) u16 {
    std.debug.assert(tokens.command_list_visual.row_height > 0);
    const inner = widgets.panel_content_rect(tokens.overlay_chrome, rect);
    const results = inner.height -| first_result_row(filters);
    return @min(
        @max(@divFloor(results, tokens.command_list_visual.row_height), 1),
        pane.rows_max,
    );
}

pub fn rect_for(bounds: Rect) Rect {
    return tokens.overlay_rect(bounds, 84, 17);
}

pub fn mount(
    tree: *dom.DomTree,
    parent: NodeIndex,
    options: MountOptions,
) !Slot {
    var slot = Slot{
        .mounted = true,
        .floating = options.placement != null,
        .filters = options.filters,
    };
    if (options.placement) |rect| {
        slot.shadow = try tree.append_child(parent, .{
            .kind = .panel,
            .props = .{ .panel = .{
                .chrome = .{ .rail_width = 0, .content_padding_left = 0 },
                .style = shadow_style(),
            } },
            .layout = LayoutElement.placed_free(
                rect.x + 1,
                rect.y + 1,
                rect.width,
                rect.height,
            ),
        });
    }
    slot.panel = try tree.append_child(parent, .{
        .kind = .panel,
        .props = .{ .panel = .{
            .chrome = tokens.overlay_chrome,
            .style = theme.command_panel,
        } },
        .layout = if (options.placement) |rect|
            LayoutElement.placed_free(rect.x, rect.y, rect.width, rect.height)
        else
            LayoutElement.free(),
        .focused = true,
    });
    slot.input = try tree.append_child(slot.panel, .{
        .kind = .text_input,
        .props = .{ .text_input = .{} },
        .layout = LayoutElement.placed(0, 0, options.width, 1),
    });
    slot.prompt_width = options.prompt_width;
    slot.placeholder = try tree.append_child(slot.panel, .{
        .kind = .label,
        .props = .{ .label = .{} },
        .layout = LayoutElement.placed(
            options.prompt_width + 1,
            0,
            options.width -| (options.prompt_width + 1),
            1,
        ),
    });
    if (options.filters) {
        slot.filter_badge = try tree.append_child(slot.panel, .{
            .kind = .badge,
            .props = .{ .badge = .{} },
            .layout = LayoutElement.placed(0, filter_row, filter_badge_width, 1),
        });
        slot.filter_items = try tree.append_child(slot.panel, .{
            .kind = .segmented,
            .props = .{ .segmented = .{} },
            .layout = LayoutElement.placed(
                filter_badge_width + 1,
                filter_row,
                options.width -| (filter_badge_width + 1),
                1,
            ),
        });
    }
    slot.results = try pane.mount_list(
        tree,
        slot.panel,
        Rect.init(
            0,
            first_result_row(options.filters),
            options.width,
            @max(options.rows * @as(u16, tokens.command_list_visual.row_height), 1),
        ),
        options.rows,
        tokens.command_list_visual,
        theme.command_panel,
    );
    return slot;
}

fn shadow_style() markix.Style {
    var style = theme.panel_style;
    style.background = theme.shadow;
    return style;
}

/// Writes the surface: its panel, shadow, filter row and prompt. The results
/// are written separately, because the list underneath is sometimes the
/// engine's own and sometimes the host's -- zen mode filters the collection in
/// place rather than gathering a new one.
pub fn update_surface(
    tree: *dom.DomTree,
    slot: *const Slot,
    config: Config,
    query: []const u8,
    cursor: u16,
) void {
    if (!slot.mounted) return;
    tree.set_props(slot.panel, .{ .panel = .{
        .style = theme.command_panel,
        .chrome = tokens.overlay_chrome,
        .title = config.title,
        .meta = config.meta,
    } });
    if (slot.floating) {
        tree.set_props(slot.shadow, .{ .panel = .{
            .style = shadow_style(),
            .chrome = .{ .rail_width = 0, .content_padding_left = 0 },
        } });
    }
    if (config.filters) |filters| update_filters(tree, slot, filters);
    tree.set_focused(slot.input, true);
    tree.set_props(slot.input, .{ .text_input = .{
        .style = theme.command_field,
        .prompt = config.prompt,
        .placeholder = config.placeholder,
        .value = query,
        .cursor = cursor,
    } });
    if (slot.placeholder != 0) {
        var style = theme.command_field;
        style.foreground = theme.muted;
        tree.set_props(slot.placeholder, .{ .label = .{
            .text = if (query.len == 0) config.placeholder else "",
            .style = style,
        } });
    }
    tree.set_focused(slot.results.list, true);
}

/// Writes the whole surface from the engine's state. `host` supplies what a
/// result reads as: `command_result_title`, `command_result_detail` and
/// `command_result_marker`.
pub fn update(
    tree: *dom.DomTree,
    slot: *const Slot,
    center: anytype,
    host: anytype,
    config: Config,
) void {
    if (!slot.mounted) return;
    update_surface(tree, slot, config, center.query(), center.input.cursor);
    var highlight = center.query();
    var scan: u16 = 0;
    while (scan < slot.results.row_count) : (scan += 1) {
        const index = center.scroll + scan;
        if (index >= center.count) break;
        if (pane.is_ascii(host.command_result_title(center.results[index]))) continue;
        highlight = "";
        break;
    }
    pane.update_list(tree, &slot.results, .{
        .role = .command,
        .focused = true,
        .empty_text = config.empty_text,
        .highlight = highlight,
        .visual = tokens.command_list_visual,
        .item_count = center.count,
        .scroll = center.scroll,
        .selected = center.selected,
    });
    var row: u16 = 0;
    while (row < slot.results.row_count) : (row += 1) {
        const index = center.scroll + row;
        if (index >= center.count) {
            pane.set_row(tree, &slot.results, row, null, false);
            continue;
        }
        const result = center.results[index];
        pane.set_row(tree, &slot.results, row, .{
            .title = host.command_result_title(result),
            .subtitle = host.command_result_detail(result),
            .marker = host.command_result_marker(result),
        }, index == center.selected);
    }
}

fn update_filters(tree: *dom.DomTree, slot: *const Slot, filters: Filters) void {
    if (slot.filter_items == 0) return;
    tree.set_props(slot.filter_badge, .{ .badge = .{
        .text = filters.label,
        .style = .{
            .foreground = theme.inverse_foreground,
            .background = theme.accent_cool,
            .attributes = .{ .bold = true },
            .padding = 1,
        },
    } });
    tree.set_props(slot.filter_items, .{ .segmented = .{
        .active_style = .{
            .foreground = theme.inverse_foreground,
            .background = theme.command,
            .attributes = .{ .bold = true },
        },
        .idle_style = .{
            .foreground = theme.muted,
            .background = theme.command_panel.background,
            .attributes = .{ .dim = true },
        },
        .gap = 1,
        .items = filters.items,
        .selected = filters.selected,
    } });
}

pub fn capture_rects(tree: *dom.DomTree, slot: *Slot) void {
    if (!slot.mounted) return;
    pane.capture_rects(tree, &slot.results);
    if (tree.get(slot.panel)) |node| slot.rect = node.rect();
    if (slot.filter_items != 0) {
        if (tree.get(slot.filter_items)) |node| slot.filters_rect = node.rect();
    }
}

/// Where each filter badge landed, walking the segmented widget's own maths so
/// a hit box is the badge the user sees.
pub fn filter_hit_boxes(
    slot: *const Slot,
    items: []const widgets.SegmentItem,
    out: []Rect,
) u8 {
    if (slot.filter_items == 0) return 0;
    const rect = slot.filters_rect;
    var column: u16 = 0;
    var index: u8 = 0;
    while (index < items.len and index < out.len) : (index += 1) {
        if (column >= rect.width) break;
        const available = rect.width - column;
        const width = @min(@as(u16, @intCast(items[index].label.len + 2)), available);
        out[index] = Rect.init(rect.x + column, rect.y, width, 1);
        column += width;
        if (column < rect.width) column += 1;
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
    // The window followed the selection rather than the selection leaving it.
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
    // Exact beats prefix beats word-start beats mid-word beats scattered.
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

    // Typing gathers a fresh set; leaving the highlight on row 3 would run
    // whatever now happens to sit there.
    center.reset_results();
    index = 0;
    while (index < 6) : (index += 1) center.append(.{ .index = 100 + index }, 0);
    center.finish_results();
    try std.testing.expectEqual(@as(u16, 0), center.selected);
    try std.testing.expectEqual(@as(u16, 0), center.scroll);
    try std.testing.expectEqual(@as(u16, 100), center.selected_result().?.index);
}

test "a match stays legible on the row it is selected on" {
    // The match runs are painted in `command` on top of the selected row's
    // background; if the two were the same colour the match would vanish
    // exactly when the user moved onto it.
    try std.testing.expect(
        !theme.command_panel.selected_background.equals(theme.command),
    );
}
