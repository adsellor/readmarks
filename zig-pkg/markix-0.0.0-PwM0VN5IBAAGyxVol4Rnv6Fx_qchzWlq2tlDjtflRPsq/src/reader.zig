const std = @import("std");
const layout = @import("layout.zig");
const screen_mod = @import("backend/cells.zig");
const renderer = @import("backend/renderer.zig");
const event_loop = @import("backend/terminal/event.zig");
const input = @import("utils/input.zig");
const terminal_mod = @import("backend/terminal.zig");

const Renderer = renderer.Renderer;
const Tree = layout.Tree;
const Index = layout.Index;
const none = layout.none;

pub const Viewport = struct {
    screen: *screen_mod.Screen,
    damage: ?*screen_mod.Damage = null,
    scroll: i32 = 0,
    cursor: ?usize = null,
};

pub const Site = struct {
    context: *anyopaque,

    home: []const u8,

    open: *const fn (
        context: *anyopaque,
        href: []const u8,
        viewport: *Viewport,
    ) anyerror!?*const Tree,

    owns: *const fn (context: *anyopaque, href: []const u8) bool,
};

pub const Shortcut = struct {
    key: u8,
    href: []const u8,
};

pub const Options = struct {
    history_max: usize = 16,
    href_max: usize = 512,
    row: layout.Element = .list_item,
    wheel_rows: i32 = 3,
    columns_max: i32 = 400,
    rows_max: i32 = 150,
    draws_max: usize = 4096,
    shortcuts: []const Shortcut = &.{},
};

const Place = struct {
    slot: []u8,
    length: usize = 0,
    scroll: i32 = 0,
    cursor: usize = 0,

    fn href(self: Place) []const u8 {
        return self.slot[0..self.length];
    }

    fn remember(self: *Place, href_: []const u8) bool {
        if (href_.len > self.slot.len) return false;
        @memcpy(self.slot[0..href_.len], href_);
        self.length = href_.len;
        self.scroll = 0;
        self.cursor = 0;
        return true;
    }
};

const State = struct {
    site: Site,
    options: Options,
    screen: screen_mod.Screen,
    damage: screen_mod.Damage,

    history: []Place,
    top: usize = 0,

    tree: ?*const Tree = null,
    cursor_shown: bool = false,

    fn here(self: *State) *Place {
        std.debug.assert(self.top < self.history.len);
        return &self.history[self.top];
    }
};

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    site: Site,
    options: Options,
) !void {
    std.debug.assert(site.home.len > 0);
    std.debug.assert(options.history_max > 0);

    const size = try terminal_mod.get_terminal_size();
    std.debug.assert(size.width > 0 and size.height > 0);

    const history = try gpa.alloc(Place, options.history_max);
    defer gpa.free(history);
    const names = try gpa.alloc(u8, options.history_max * options.href_max);
    defer gpa.free(names);
    for (history, 0..) |*place, at| {
        place.* = .{ .slot = names[at * options.href_max ..][0..options.href_max] };
    }

    var screen = try screen_mod.Screen.alloc(
        gpa,
        options.columns_max,
        options.rows_max,
        true,
    );
    defer screen.free(gpa);
    screen.resize(
        @min(@as(i32, @intCast(size.width)), options.columns_max),
        @min(@as(i32, @intCast(size.height)), options.rows_max),
    );

    var damage = try screen_mod.Damage.alloc(gpa, options.draws_max);
    defer damage.free(gpa);

    var state = State{
        .site = site,
        .options = options,
        .screen = screen,
        .damage = damage,
        .history = history,
    };
    if (!state.history[0].remember(site.home)) return error.HomeTooLong;

    const backend = screen_mod.screen_backend(&state.screen);
    try event_loop.run_event_loop(io, backend, .{}, State, &state, on_event);
}

fn on_event(state: *State, event: event_loop.Event) !event_loop.LoopAction {
    return switch (event) {
        .frame => draw: {
            try draw(state);
            break :draw .wait;
        },
        .resize => .redraw,
        .key => |key| on_key(state, key),
        .poll => if (animates(state)) .redraw else .wait,
    };
}

fn animates(state: *State) bool {
    const tree = state.tree orelse return false;
    return tree.count_of(.canvas) > 0;
}

fn draw(state: *State) !void {
    const place = state.here();
    var viewport = Viewport{
        .screen = &state.screen,
        .damage = &state.damage,
        .scroll = place.scroll,
        .cursor = place.cursor,
    };
    state.tree = try state.site.open(state.site.context, place.href(), &viewport);
    place.scroll = viewport.scroll;
    state.cursor_shown = viewport.cursor != null;
}

fn on_key(state: *State, key: input.Key) event_loop.LoopAction {
    return switch (key) {
        .character => |ch| switch (ch) {
            'q' => .stop,
            'h' => back(state),
            'g' => to_top(state),
            'G' => to_bottom(state),
            'j', ' ' => advance(state, 1),
            'k' => advance(state, -1),
            'l' => open_cursor(state),
            else => shortcut(state, ch),
        },
        .enter => open_cursor(state),
        .escape, .backspace => back(state),
        .down => advance(state, 1),
        .up => advance(state, -1),
        .home => to_top(state),
        .end => to_bottom(state),
        .pointer => |pointer| on_pointer(state, pointer),
        else => .wait,
    };
}

fn shortcut(state: *State, ch: u8) event_loop.LoopAction {
    for (state.options.shortcuts) |bookmark| {
        if (bookmark.key == ch) return follow(state, bookmark.href);
    }
    return .wait;
}

fn on_pointer(state: *State, pointer: input.Pointer) event_loop.LoopAction {
    std.debug.assert(state.top < state.history.len);
    std.debug.assert(state.options.wheel_rows >= 0);
    switch (pointer.button) {
        .wheel_up => return advance(state, -state.options.wheel_rows),
        .wheel_down => return advance(state, state.options.wheel_rows),
        .primary => {},
        else => return .wait,
    }
    if (pointer.action != .press) return .wait;
    const column: i32 = @intCast(pointer.x);
    const row: i32 = @intCast(pointer.y);
    if (column < 0 or row < 0 or
        column >= state.screen.width or row >= state.screen.height) return .wait;

    const tree = state.tree orelse return .wait;
    const at = state.screen.at_source(column, row);
    if (at == none) return .wait;

    if (has_rows(state)) {
        const on_row = tree.enclosing(at, state.options.row);
        if (on_row != none) state.here().cursor = tree.ordinal_of(on_row);
    }

    const link = tree.enclosing(at, .link);
    if (link != none and tree.at(link).href.len > 0) {
        return follow(state, tree.at(link).href);
    }
    return .redraw;
}

fn advance(state: *State, delta: i32) event_loop.LoopAction {
    if (!has_rows(state)) return scroll_to(state, state.here().scroll + delta);
    const place = state.here();
    const last = rows(state) -| 1;
    const before = place.cursor;
    place.cursor = if (delta > 0)
        @min(last, place.cursor + @as(usize, @intCast(delta)))
    else
        place.cursor -| @as(usize, @intCast(-delta));
    if (place.cursor == before) return .wait;
    keep_cursor_visible(state);
    return .redraw;
}

fn to_top(state: *State) event_loop.LoopAction {
    if (!has_rows(state)) return scroll_to(state, 0);
    return cursor_to(state, 0);
}

fn to_bottom(state: *State) event_loop.LoopAction {
    if (!has_rows(state)) return scroll_to(state, height(state));
    return cursor_to(state, rows(state) -| 1);
}

fn cursor_to(state: *State, row: usize) event_loop.LoopAction {
    const place = state.here();
    if (place.cursor == row) return .wait;
    place.cursor = row;
    keep_cursor_visible(state);
    return .redraw;
}

fn scroll_to(state: *State, row: i32) event_loop.LoopAction {
    const place = state.here();
    const target = @min(bottom(state), @max(0, row));
    if (target == place.scroll) return .wait;
    place.scroll = target;
    return .redraw;
}

fn keep_cursor_visible(state: *State) void {
    const tree = state.tree orelse return;
    const place = state.here();
    const at = tree.nth(state.options.row, place.cursor);
    if (at == none) return;
    const rect = tree.at(at).rect;
    const window = state.screen.height;
    if (rect.y - place.scroll < 0) {
        place.scroll = @max(0, rect.y);
    } else if (rect.y - place.scroll >= window) {
        place.scroll = @max(0, rect.y - window + 1);
    }
}

fn open_cursor(state: *State) event_loop.LoopAction {
    if (!has_rows(state)) return .wait;
    const tree = state.tree orelse return .wait;
    const row = tree.nth(state.options.row, state.here().cursor);
    if (row == none) return .wait;
    const link = tree.first_within(row, .link);
    if (link == none) return .wait;
    return follow(state, tree.at(link).href);
}

fn follow(state: *State, href: []const u8) event_loop.LoopAction {
    std.debug.assert(state.top < state.history.len);
    if (href.len == 0) return .wait;
    if (href[0] == '#') return jump(state, href[1..]);
    if (std.mem.eql(u8, href, state.site.home)) return home(state);
    if (std.mem.eql(u8, href, state.here().href())) return .wait;
    if (!state.site.owns(state.site.context, href)) return .wait;

    if (state.top + 1 < state.history.len) state.top += 1;
    std.debug.assert(state.top < state.history.len);
    if (!state.history[state.top].remember(href)) {
        if (state.top > 0) state.top -= 1;
        return .wait;
    }
    forget(state);
    return .redraw;
}

fn jump(state: *State, id: []const u8) event_loop.LoopAction {
    const tree = state.tree orelse return .wait;
    const at = tree.with_id(id);
    if (at == none) return .wait;
    return scroll_to(state, tree.at(at).rect.y);
}

fn back(state: *State) event_loop.LoopAction {
    if (state.top == 0) return .wait;
    state.top -= 1;
    forget(state);
    return .redraw;
}

fn home(state: *State) event_loop.LoopAction {
    if (state.top == 0) return .wait;
    state.top = 0;
    forget(state);
    return .redraw;
}

fn forget(state: *State) void {
    state.tree = null;
    state.cursor_shown = false;
}

fn has_rows(state: *State) bool {
    return state.cursor_shown and rows(state) > 0;
}

fn rows(state: *State) usize {
    const tree = state.tree orelse return 0;
    return tree.count_of(state.options.row);
}

fn height(state: *State) i32 {
    const tree = state.tree orelse return 0;
    return screen_mod.height_of(tree);
}

fn bottom(state: *State) i32 {
    const tree = state.tree orelse return 0;
    return screen_mod.scroll_max(tree, state.screen.height);
}

const testing = std.testing;
const el = layout.dsl;

const Fake = struct {
    nodes: [64]layout.Node = undefined,
    styles: [64]layout.Style = undefined,
    tree: Tree = undefined,
    draws: usize = 0,
    scratch: [64]u8 = undefined,

    const columns: i32 = 40;

    fn site(self: *Fake) Site {
        self.tree = Tree.init(&self.nodes);
        return .{ .context = self, .home = "/", .open = open, .owns = owns };
    }

    fn path(self: *Fake, slot: usize, name: []const u8) []const u8 {
        const room = self.scratch[slot * 16 ..][0..name.len];
        @memcpy(room, name);
        return room;
    }

    fn owns(context: *anyopaque, href: []const u8) bool {
        _ = context;
        for ([_][]const u8{ "/", "/one/", "/two/" }) |page| {
            if (std.mem.eql(u8, href, page)) return true;
        }
        return false;
    }

    fn open(
        context: *anyopaque,
        href: []const u8,
        viewport: *Viewport,
    ) anyerror!?*const Tree {
        const self: *Fake = @ptrCast(@alignCast(context));
        if (!owns(context, href)) return null;
        const listing = std.mem.eql(u8, href, "/");

        self.draws += 1;
        self.tree.reset();
        @memset(&self.scratch, 'x');
        if (listing) {
            try self.build_listing();
        } else {
            viewport.cursor = null;
            try build_article(&self.tree);
        }
        Renderer.resolve(.terminal, &self.tree, columns);

        const focus = if (viewport.cursor) |row|
            self.tree.nth(.list_item, row)
        else
            none;
        viewport.scroll = @max(0, @min(
            screen_mod.scroll_max(&self.tree, viewport.screen.height),
            viewport.scroll,
        ));
        try (Renderer{ .terminal = .{
            .screen = viewport.screen,
            .styles = &self.styles,
            .damage = viewport.damage,
            .options = .{
                .scroll = viewport.scroll,
                .focus = focus,
                .focus_style = .{ .bold = true },
            },
        } }).draw(&self.tree);
        return &self.tree;
    }

    fn build_listing(self: *Fake) !void {
        try el.mount(&self.tree, el.column(.{ .width = .{ .fixed = columns } }, .{
            el.list(.{ .width = .{ .fixed = columns } }, .{
                el.item(.{ .width = .{ .grow = .{} } }, .{
                    el.link("One", self.path(0, "/one/"), .{ .display = .block }),
                }),
                el.item(.{ .width = .{ .grow = .{} } }, .{
                    el.link("Two", self.path(1, "/two/"), .{ .display = .block }),
                }),
            }),
        }));
    }

    fn build_article(tree: *Tree) !void {
        try el.mount(tree, el.column(.{ .width = .{ .fixed = columns } }, .{
            el.text("top", .{
                .width = .{ .fixed = columns },
                .height = .{ .fixed = 30 },
            }),
            el.heading(1, "Deep", .{
                .width = .{ .fixed = columns },
                .id = "deep",
            }),
            el.paragraph(
                "Prose enough to run past the bottom of a short window, " ++
                    "so that scrolling has somewhere to go and a click after " ++
                    "it has a row to land on.",
                .{ .width = .{ .fixed = columns } },
            ),
            el.rich(.{ .width = .{ .fixed = columns } }, .{
                el.run("and ", .{}),
                el.link("back", "/", .{}),
            }),
        }));
    }
};

const Reading = struct {
    fake: Fake = .{},
    cells: [Fake.columns * 12]screen_mod.Cell = undefined,
    sources: [Fake.columns * 12]Index = undefined,
    history: [4]Place = undefined,
    names: [4 * 32]u8 = undefined,
    draws: [2][64]screen_mod.Damage.Draw = undefined,
    state: State = undefined,

    fn open(self: *Reading) !void {
        var screen = screen_mod.Screen.init(&self.cells, Fake.columns, 12);
        screen.sources = &self.sources;
        for (&self.history, 0..) |*place, at| {
            place.* = .{ .slot = self.names[at * 32 ..][0..32] };
        }
        self.state = .{
            .site = self.fake.site(),
            .options = .{
                .history_max = self.history.len,
                .href_max = 32,
                .shortcuts = &.{.{ .key = 't', .href = "/two/" }},
            },
            .screen = screen,
            .damage = screen_mod.Damage.init(.{ &self.draws[0], &self.draws[1] }),
            .history = &self.history,
        };
        std.debug.assert(self.state.history[0].remember("/"));
        try draw(&self.state);
    }

    fn press(self: *Reading, key: input.Key) !event_loop.LoopAction {
        const action = on_key(&self.state, key);
        if (action == .redraw) try draw(&self.state);
        return action;
    }
};

test "a cursor steps over the rows and stops at the ends" {
    var reading = Reading{};
    try reading.open();
    try testing.expect(has_rows(&reading.state));
    try testing.expectEqual(@as(usize, 2), rows(&reading.state));

    try testing.expectEqual(event_loop.LoopAction.redraw, try reading.press(.{ .character = 'j' }));
    try testing.expectEqual(@as(usize, 1), reading.state.here().cursor);
    try testing.expectEqual(event_loop.LoopAction.wait, try reading.press(.{ .character = 'j' }));
    try testing.expectEqual(@as(usize, 1), reading.state.here().cursor);

    try testing.expectEqual(event_loop.LoopAction.redraw, try reading.press(.{ .character = 'k' }));
    try testing.expectEqual(@as(usize, 0), reading.state.here().cursor);
    try testing.expectEqual(event_loop.LoopAction.wait, try reading.press(.{ .character = 'k' }));
}

test "opening a row follows the link that row carries, and back returns to it" {
    var reading = Reading{};
    try reading.open();
    const state = &reading.state;

    _ = try reading.press(.{ .character = 'j' });
    try testing.expectEqual(event_loop.LoopAction.redraw, try reading.press(.enter));
    try testing.expectEqual(@as(usize, 1), state.top);
    try testing.expectEqualStrings("/two/", state.here().href());

    try testing.expect(!has_rows(state));
    try testing.expectEqual(@as(i32, 0), state.here().scroll);
    try testing.expectEqual(event_loop.LoopAction.redraw, try reading.press(.{ .character = 'j' }));
    try testing.expect(state.here().scroll > 0);

    try testing.expectEqual(event_loop.LoopAction.redraw, try reading.press(.backspace));
    try testing.expectEqual(@as(usize, 0), state.top);
    try testing.expectEqualStrings("/", state.here().href());
    try testing.expectEqual(@as(usize, 1), state.here().cursor);
}

test "a click resolves through the cells to the link under it" {
    var reading = Reading{};
    try reading.open();
    const state = &reading.state;

    const row = state.tree.?.nth(.list_item, 1);
    const rect = state.tree.?.at(row).rect;
    const action = on_pointer(state, .{
        .x = @intCast(rect.x),
        .y = @intCast(rect.y),
        .action = .press,
        .button = .primary,
    });
    try testing.expectEqual(event_loop.LoopAction.redraw, action);
    try testing.expectEqualStrings("/two/", state.here().href());

    try testing.expectEqual(
        event_loop.LoopAction.wait,
        on_pointer(state, .{ .x = 0, .y = 11, .action = .press, .button = .primary }),
    );
}

test "an anchor scrolls to the box that carries the id" {
    var reading = Reading{};
    try reading.open();
    const state = &reading.state;
    _ = try reading.press(.enter);
    try testing.expectEqualStrings("/one/", state.here().href());

    try testing.expectEqual(event_loop.LoopAction.redraw, follow(state, "#deep"));
    const at = state.tree.?.with_id("deep");
    const row = state.tree.?.at(at).rect.y;
    try testing.expectEqual(@min(row, bottom(state)), state.here().scroll);
    try testing.expect(row - state.here().scroll >= 0);
    try testing.expect(row - state.here().scroll < state.screen.height);
    try testing.expectEqual(event_loop.LoopAction.wait, follow(state, "#nowhere"));
}

test "home is the way back however deep a reader went" {
    var reading = Reading{};
    try reading.open();
    const state = &reading.state;
    _ = try reading.press(.enter);
    try testing.expectEqual(@as(usize, 1), state.top);

    try testing.expectEqual(event_loop.LoopAction.redraw, follow(state, "/"));
    try testing.expectEqual(@as(usize, 0), state.top);
    try testing.expectEqual(event_loop.LoopAction.wait, follow(state, "/"));
    try testing.expectEqual(event_loop.LoopAction.wait, back(state));
}

test "a shortcut goes straight to a page, and an unknown href goes nowhere" {
    var reading = Reading{};
    try reading.open();
    const state = &reading.state;

    try testing.expectEqual(event_loop.LoopAction.redraw, try reading.press(.{ .character = 't' }));
    try testing.expectEqualStrings("/two/", state.here().href());

    const drawn = reading.fake.draws;
    try testing.expectEqual(event_loop.LoopAction.wait, follow(state, "https://elsewhere/"));
    try testing.expectEqualStrings("/two/", state.here().href());
    try testing.expectEqual(drawn, reading.fake.draws);
}

test "history has a floor: the deepest page is replaced, not stacked past" {
    var reading = Reading{};
    try reading.open();
    const state = &reading.state;
    for (0..8) |at| {
        _ = follow(state, if (at % 2 == 0) "/one/" else "/two/");
    }
    try testing.expectEqual(reading.history.len - 1, state.top);
    try testing.expectEqual(event_loop.LoopAction.redraw, back(state));
    try testing.expectEqual(reading.history.len - 2, state.top);
}

test "a page opened from a link is still that page when it is drawn again" {
    var reading = Reading{};
    try reading.open();
    const state = &reading.state;

    try testing.expectEqual(event_loop.LoopAction.redraw, try reading.press(.enter));
    try testing.expectEqualStrings("/one/", state.here().href());

    try draw(state);
    try testing.expectEqualStrings("/one/", state.here().href());
    try testing.expect(state.tree != null);
    try testing.expect(height(state) > 0);

    _ = try reading.press(.{ .character = 'j' });
    try testing.expectEqual(@as(i32, 1), state.here().scroll);
    _ = try reading.press(.{ .character = 'j' });
    try testing.expectEqual(@as(i32, 2), state.here().scroll);
}

test "a frame is drawn at a fixed origin" {
    var cells: [4 * 2]screen_mod.Cell = undefined;
    var screen = screen_mod.Screen.init(&cells, 4, 2);
    screen.clear(.{});
    _ = screen.write(0, 0, "hi", .{});

    var bytes: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeAll(screen_mod.home);
    try screen_mod.write_ansi(&writer, &screen, .{ .last_newline = false });
    const frame = writer.buffered();

    try testing.expect(std.mem.startsWith(u8, frame, "\x1b[H"));
    try testing.expect(!std.mem.endsWith(u8, frame, "\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, frame, "\r\n"));
}
