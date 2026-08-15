const std = @import("std");
const terminal = @import("markix").terminal;
const layout = @import("markix").layout;
const document = @import("markix").document;
const bookmarks = @import("data").bookmarks;
const bookmark_limits = @import("data").limits;
const data_paths = @import("data").paths;
const Paths = @import("data").Paths;
const FixedText = @import("data").FixedText;
const cache_module = @import("cache.zig");
const fetcher_module = @import("fetcher.zig");
const image_loader_module = @import("image_loader.zig");
const limits = @import("limits.zig");
const model = @import("model.zig");
const parser = @import("parser.zig");
const state_module = @import("state.zig");
const subscriptions = @import("subscriptions.zig");
const transport_module = @import("transport.zig");

const backend = transport_module.backend;

const Message = FixedText(192);
const SearchInput = terminal.widgets.TextInput(limits.search_bytes_max);
const FeedUrlInput = terminal.widgets.TextInput(limits.article_url_bytes_max);
const FeedCategoryInput = terminal.widgets.TextInput(limits.category_name_bytes_max);

pub const Focus = enum { categories, feeds, articles, reader };
pub const Scope = enum { all, unread, category };

const PaneGeometry = struct {
    /// The whole pane (chrome included), for hit-testing which pane a pointer
    /// press falls in.
    bounds: layout.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    /// The list/documented area the rows are drawn in, for mapping a pointer
    /// row to an item. `width == 0` marks the pane as not drawn this frame.
    list: layout.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    row_height: u8 = 1,
};
pub const FeedMode = enum { browse, add_url, add_category, remove_confirm, prune_confirm };

const FetchOutcome = union(enum) {
    update: parser.Update,
    failure: anyerror,
};

const FetchResult = struct {
    worker_index: u16,
    feed_index: u16,
    outcome: FetchOutcome,
};

const FetchResultQueue = std.Io.Queue(FetchResult);

pub const Application = struct {
    io: std.Io,
    http_client: if (backend == .native) std.http.Client else void,
    fetchers: [limits.feed_fetch_concurrency]fetcher_module.Fetcher,
    fetch_transport: if (backend == .web) transport_module.Transport else void,
    fetch_tasks: [limits.feed_fetch_concurrency]std.Io.Group =
        @splat(.init),
    fetch_workers_busy: [limits.feed_fetch_concurrency]bool = @splat(false),
    fetch_result_buffer: [limits.feed_fetch_concurrency]FetchResult = undefined,
    fetch_results: FetchResultQueue = undefined,
    fetch_in_progress: bool = false,
    fetch_busy_count: u16 = 0,
    fetch_next: u16 = 0,
    fetch_stop: u16 = 0,
    fetch_success_count: u16 = 0,
    fetch_failure_count: u16 = 0,
    full_refresh_completed: bool = false,
    refresh_all_active: bool = false,

    feeds: [limits.feed_count_max]model.Feed = undefined,
    feed_count: u16 = 0,
    categories: [limits.category_count_max]model.CategoryName = undefined,
    category_count: u16 = 0,
    filtered_categories: [limits.category_count_max]u16 = undefined,
    filtered_category_count: u16 = 0,
    articles: [limits.article_count_max]model.Article = undefined,
    article_count: u16 = 0,
    unread_article_count: u16 = 0,
    feed_unread_counts: [limits.feed_count_max]u16 = @splat(0),
    read_state: state_module.State = .{},
    state_persistence: state_module.Persistence,
    cache_persistence: cache_module.Persistence,
    image_loader: image_loader_module.Loader,

    bookmark_store: bookmarks.Store = .{},
    bookmark_persistence: bookmarks.Persistence,
    subscription_path: model.FeedUrl = .{},

    filtered_feeds: [limits.feed_count_max]u16 = undefined,
    filtered_feed_count: u16 = 0,
    filtered_articles: [limits.article_count_max]u16 = undefined,
    filtered_article_count: u16 = 0,

    focus: Focus = .articles,
    scope: Scope = .all,
    active_category: model.CategoryName = .{},
    active_feed: ?u16 = null,
    category_cursor: u16 = 0,
    category_scroll: u16 = 0,
    category_viewport: u16 = 1,
    feed_cursor: u16 = 0,
    feed_scroll: u16 = 0,
    feed_viewport: u16 = 1,
    article_cursor: u16 = 0,
    article_scroll: u16 = 0,
    article_viewport: u16 = 1,
    reader_scroll: u16 = 0,
    reader_line_count: u16 = 0,
    reader_viewport: u16 = 1,
    reader_document: document.Document = .{},
    reader_document_article: ?u16 = null,
    reader_document_length: u16 = 0,
    reader_layout_valid: bool = false,
    reader_layout_width: u16 = 0,
    reader_layout_image: bool = false,
    reader_block_lines: [document.block_count_max]u16 = @splat(0),
    pane_geometry: [4]PaneGeometry = @splat(.{}),
    reader_only: bool = false,
    collapsed: [4]bool = @splat(false),
    search_open: bool = false,
    search: SearchInput = .{},
    applied_search: SearchInput = .{},
    /// The pane the applied query filters. A search belongs to the list it was
    /// started from: `/` in Feeds narrows the feed list, not the articles.
    /// There is one query at a time, so applying a new one releases the pane
    /// the last one held.
    search_scope: Focus = .articles,
    feed_mode: FeedMode = .browse,
    feed_url_input: FeedUrlInput = .{},
    feed_category_input: FeedCategoryInput = .{},
    help_open: bool = false,
    message: Message = .{},

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        paths: *const Paths,
    ) !*Application {
        const application = try allocator.create(Application);
        errdefer allocator.destroy(application);
        application.initialize(io);
        if (backend == .native) {
            application.http_client = .{ .allocator = allocator, .io = io };
        }
        try application.image_loader.init_in_place(allocator, io, paths);
        errdefer application.image_loader.deinit();
        try application.state_persistence.init_in_place(paths);
        try application.cache_persistence.init_in_place(paths);
        try application.bookmark_persistence.init_in_place(paths);
        application.fetch_results = .init(&application.fetch_result_buffer);
        try application.set_message("Loading subscriptions");
        return application;
    }

    fn initialize(self: *Application, io: std.Io) void {
        self.io = io;
        self.fetch_tasks = @splat(.init);
        self.fetch_workers_busy = @splat(false);
        self.fetch_in_progress = false;
        self.fetch_busy_count = 0;
        self.fetch_next = 0;
        self.fetch_stop = 0;
        self.fetch_success_count = 0;
        self.fetch_failure_count = 0;
        self.full_refresh_completed = false;
        self.refresh_all_active = false;
        self.feed_count = 0;
        self.category_count = 0;
        self.filtered_category_count = 0;
        self.article_count = 0;
        self.unread_article_count = 0;
        self.feed_unread_counts = @splat(0);
        self.read_state = .{};
        self.bookmark_store = .{};
        self.subscription_path = .{};
        self.filtered_feed_count = 0;
        self.filtered_article_count = 0;
        self.focus = .articles;
        self.scope = .all;
        self.active_category = .{};
        self.active_feed = null;
        self.category_cursor = 0;
        self.category_scroll = 0;
        self.category_viewport = 1;
        self.feed_cursor = 0;
        self.feed_scroll = 0;
        self.feed_viewport = 1;
        self.article_cursor = 0;
        self.article_scroll = 0;
        self.article_viewport = 1;
        self.reader_scroll = 0;
        self.reader_line_count = 0;
        self.reader_viewport = 1;
        self.reader_document = .{};
        self.reader_document_article = null;
        self.reader_document_length = 0;
        self.reader_layout_valid = false;
        self.reader_layout_width = 0;
        self.reader_layout_image = false;
        self.reader_block_lines = @splat(0);
        self.pane_geometry = @splat(.{});
        self.reader_only = false;
        self.collapsed = @splat(false);
        self.search_open = false;
        self.search = .{};
        self.applied_search = .{};
        self.search_scope = .articles;
        self.feed_mode = .browse;
        self.feed_url_input = .{};
        self.feed_category_input = .{};
        self.help_open = false;
        self.message = .{};
        if (backend == .web) self.fetch_transport = .{};
    }

    pub fn destroy(self: *Application, allocator: std.mem.Allocator) void {
        if (backend == .native) {
            var worker_index: u16 = 0;
            while (worker_index < limits.feed_fetch_concurrency) : (worker_index += 1) {
                self.fetch_tasks[worker_index].cancel(self.io);
            }
        }
        self.fetch_results.close(self.io);
        const cache_failure = self.cache_persistence.finish(
            self.io,
            &self.feeds,
            self.feed_count,
            &self.articles,
            self.article_count,
        ) catch |err| failure: {
            std.log.err("failed to finish RSS cache task: {s}", .{@errorName(err)});
            break :failure null;
        };
        if (cache_failure) |err| {
            std.log.err("failed to finish RSS cache save: {s}", .{@errorName(err)});
        }
        self.image_loader.deinit();
        self.cache_persistence.deinit(self.io);
        if (backend == .native) self.http_client.deinit();
        allocator.destroy(self);
    }

    pub fn load(self: *Application, paths: *const Paths) !void {
        self.state_persistence.load(self.io, &self.read_state) catch |err| {
            try self.set_message(@errorName(err));
        };
        var path_buffer: [bookmark_limits.path_bytes_max]u8 = undefined;
        const path = try data_paths.file(
            &path_buffer,
            paths.config.bytes(),
            subscriptions.file_name,
        );
        // The path is kept whether or not the file is there: adding a feed has
        // to know where to write one that does not exist yet.
        self.subscription_path = model.FeedUrl.init(path) catch
            return error.SubscriptionPathTooLong;
        const result = subscriptions.load(
            self.io,
            path,
            &self.feeds,
            &self.fetchers[0].response,
        ) catch |err| {
            try self.report_missing_feeds(err, path);
            return;
        };
        self.feed_count = result.count;
        const cache_fresh = try self.load_cache();
        self.rebuild_categories();
        self.refresh_feeds();
        self.refresh_articles();
        if (!cache_fresh) {
            self.start_refresh_all() catch |err| {
                try self.set_message(@errorName(err));
                return;
            };
        }
        // A skipped line is the one thing here the reader has to act on, so it
        // outranks the routine cache report.
        if (result.skipped > 0) {
            try self.set_message_formatted(
                "{d} feeds loaded; {d} lines in {s} were not understood",
                .{ result.count, result.skipped, subscriptions.file_name },
            );
        } else if (cache_fresh) {
            try self.set_message("Cached articles loaded; press R to refresh");
        } else {
            try self.set_message("Cache stale or empty; refreshing feeds");
        }
    }

    /// There is no feed list yet, which is where every new reader starts.
    fn report_missing_feeds(
        self: *Application,
        err: anyerror,
        path: []const u8,
    ) !void {
        if (err != error.FileNotFound) {
            try self.set_message_formatted(
                "{s}: {s}",
                .{ @errorName(err), path },
            );
            return;
        }
        try self.set_message_formatted(
            "No feeds in {s}. Press A to add one, or run: readmarks import <file>",
            .{path},
        );
    }

    fn load_cache(self: *Application) !bool {
        self.article_count = 0;
        const cached_at = self.cache_persistence.load(
            self.io,
            &self.feeds,
            self.feed_count,
            &self.articles,
            &self.article_count,
        ) catch |err| {
            self.article_count = 0;
            if (err == error.InvalidCache) return false;
            return err;
        } orelse return false;
        self.hydrate_cached_articles();
        return cache_module.is_fresh(cached_at, self.io);
    }

    fn hydrate_cached_articles(self: *Application) void {
        var feed_index: u16 = 0;
        while (feed_index < self.feed_count) : (feed_index += 1) {
            self.feeds[feed_index].article_count = 0;
        }
        var article_index: u16 = 0;
        while (article_index < self.article_count) : (article_index += 1) {
            const article = &self.articles[article_index];
            article.read = self.read_state.contains(article.url.bytes());
            self.feeds[article.feed_index].article_count += 1;
        }
    }

    pub fn handle_key(self: *Application, key: layout.input.Key) !bool {
        if (self.help_open) return self.handle_help(key);
        switch (key) {
            .character => |byte| if (byte == '?') {
                self.help_open = true;
                try self.close_reader();
                return true;
            },
            else => {},
        }
        if (self.feed_mode != .browse) return self.handle_feed_mode(key);
        if (self.search_open) return self.handle_search(key);
        return switch (key) {
            .character => |byte| self.handle_character(byte),
            .enter => self.activate(),
            .escape => self.handle_escape(),
            .tab => self.cycle_focus(1),
            .shift_tab => self.cycle_focus(-1),
            .left => self.cycle_focus(-1),
            .right => self.cycle_focus(1),
            .up => self.move_focused(-1),
            .down => self.move_focused(1),
            .home => self.move_to_edge(false),
            .end => self.move_to_edge(true),
            .control => |byte| self.handle_control(byte),
            .pointer => |pointer| self.handle_pointer(pointer),
            else => true,
        };
    }

    fn handle_pointer(self: *Application, pointer: layout.input.Pointer) bool {
        switch (pointer.action) {
            .press => {
                switch (pointer.button) {
                    .primary => {
                        const pane = self.pane_at(pointer) orelse return true;
                        // A click on a collapsed section expands it; the stale
                        // list geometry cannot map a collapsed row, so don't
                        // select from it.
                        if (self.is_collapsed(pane)) {
                            self.select_pane(pane);
                            return true;
                        }
                        self.select_pane(pane);
                        // Clicking the document only focuses the reader.
                        if (pane == .reader) return true;
                        _ = self.select_at(pane, pointer);
                        // Click an article row to open that exact article in
                        // the internal reader, not the previously focused one
                        // and not the browser.
                        if (pane == .articles) self.open_reader();
                        return true;
                    },
                    .wheel_up => {
                        // Wheel scrolls the pane under the pointer one item at
                        // a time, so a wheel over the document scrolls the
                        // reader rather than whatever pane has focus.
                        const pane = self.pane_at(pointer) orelse return true;
                        self.move_pane(pane, -1);
                        return true;
                    },
                    .wheel_down => {
                        const pane = self.pane_at(pointer) orelse return true;
                        self.move_pane(pane, 1);
                        return true;
                    },
                    else => return true,
                }
            },
            .drag => {
                // Dragging with button pressed - could be used for hover tracking later
                return true;
            },
            .release => {
                // Button released
                return true;
            },
        }
        return true;
    }

    /// Which pane the pointer falls in, or null when it lands outside every
    /// pane drawn this frame. Reader fullscreen fills the surface, so the
    /// other panes must have stale geometry cleared each render.
    fn pane_at(self: *const Application, pointer: layout.input.Pointer) ?Focus {
        const panes = [_]Focus{ .categories, .feeds, .articles, .reader };
        for (panes) |focus| {
            const bounds = self.pane_geometry[focus_index(focus)].bounds;
            if (bounds.width == 0) continue;
            if (pointer.x >= bounds.x and
                pointer.x < bounds.right() and
                pointer.y >= bounds.y and
                pointer.y < bounds.y + bounds.height)
            {
                return focus;
            }
        }
        return null;
    }

    /// Maps the pointer to the item row of a pane and selects it. Returns
    /// false when the pointer is not over the pane's list area.
    fn select_at(self: *Application, focus: Focus, pointer: layout.input.Pointer) bool {
        const geometry = self.pane_geometry[focus_index(focus)];
        if (pointer.y < geometry.list.y) return false;
        const row = @as(u16, pointer.y - geometry.list.y);
        if (row >= geometry.list.height) return false;
        const item_count = switch (focus) {
            .categories => self.category_row_count(),
            .feeds => self.filtered_feed_count + 1,
            .articles => self.filtered_article_count,
            .reader => self.reader_line_count,
        };
        const scroll = switch (focus) {
            .categories => self.category_scroll,
            .feeds => self.feed_scroll,
            .articles => self.article_scroll,
            .reader => self.reader_scroll,
        };
        const row_height: u16 = geometry.row_height;
        const index = @min(scroll +| row / row_height, item_count -| 1);
        switch (focus) {
            .categories => {
                self.category_cursor = index;
                self.apply_category_cursor();
                ensure_visible(self.category_cursor, &self.category_scroll, self.category_viewport);
            },
            .feeds => {
                self.feed_cursor = index;
                self.apply_feed_cursor();
                self.ensure_feed_visible();
            },
            .articles => {
                const previous = self.article_cursor;
                self.article_cursor = index;
                if (previous != self.article_cursor) self.reader_scroll = 0;
                self.ensure_article_visible();
            },
            .reader => return false,
        }
        return true;
    }

    fn select_pane(self: *Application, focus: Focus) void {
        self.focus = focus;
        self.collapsed[focus_index(focus)] = false;
    }

    fn move_pane(self: *Application, focus: Focus, delta: i16) void {
        if (self.is_collapsed(focus)) return;
        switch (focus) {
            .categories => self.move_categories(delta),
            .feeds => self.move_feeds(delta),
            .articles => self.move_articles(delta),
            .reader => self.move_reader(delta),
        }
    }

    fn handle_help(self: *Application, key: layout.input.Key) bool {
        switch (key) {
            .escape => self.help_open = false,
            .character => |byte| if (byte == '?' or byte == 'q') {
                self.help_open = false;
            },
            else => {},
        }
        return true;
    }

    fn handle_character(self: *Application, byte: u8) !bool {
        switch (byte) {
            'q' => return false,
            'j' => _ = self.move_focused(1),
            'k' => _ = self.move_focused(-1),
            'h' => _ = try self.cycle_focus(-1),
            'l' => _ = try self.cycle_focus(1),
            'g' => _ = self.move_to_edge(false),
            'G' => _ = self.move_to_edge(true),
            '/' => try self.begin_search(),
            'o' => try self.open_selected(),
            'i' => try self.open_selected_image(),
            'b' => try self.bookmark_selected(),
            'm' => try self.toggle_read(),
            'u' => self.select_scope(.unread, ""),
            'a' => self.select_scope(.all, ""),
            'r' => try self.start_refresh_selected(),
            'R' => try self.start_refresh_all(),
            'A' => try self.begin_add_feed(),
            'd' => try self.begin_remove_feed(),
            'P' => try self.begin_prune_feeds(),
            'c' => try self.toggle_focused_section(),
            'v' => if (self.reader_only) try self.close_reader() else self.open_reader(),
            else => {},
        }
        return true;
    }

    fn handle_control(self: *Application, byte: u8) !bool {
        switch (byte) {
            'c' => return false,
            'd' => self.move_page(1),
            'u' => self.move_page(-1),
            else => {},
        }
        return true;
    }

    fn handle_feed_mode(self: *Application, key: layout.input.Key) !bool {
        return switch (self.feed_mode) {
            .browse => true,
            .add_url, .add_category => self.handle_add_feed(key),
            .remove_confirm => self.handle_remove_confirm(key),
            .prune_confirm => self.handle_prune_confirm(key),
        };
    }

    fn handle_add_feed(self: *Application, key: layout.input.Key) !bool {
        if (key == .escape) {
            self.feed_mode = .browse;
            try self.set_message("Feed add cancelled");
            return true;
        }
        if (key == .tab or key == .shift_tab) {
            self.feed_mode = if (self.feed_mode == .add_url) .add_category else .add_url;
            return true;
        }
        const action = if (self.feed_mode == .add_url)
            try self.feed_url_input.handle(key)
        else
            try self.feed_category_input.handle(key);
        if (action != .submitted) return true;
        if (self.feed_mode == .add_url) {
            self.feed_mode = .add_category;
            try self.set_message("Enter a category, then press Enter");
        } else {
            try self.commit_add_feed();
        }
        return true;
    }

    fn handle_remove_confirm(self: *Application, key: layout.input.Key) !bool {
        switch (key) {
            .character => |byte| if (byte == 'd') {
                try self.remove_selected_feed();
                return true;
            },
            else => {},
        }
        self.feed_mode = .browse;
        try self.set_message("Feed removal cancelled");
        return true;
    }

    fn handle_prune_confirm(self: *Application, key: layout.input.Key) !bool {
        switch (key) {
            .character => |byte| if (byte == 'P') {
                try self.prune_failed_feeds();
                return true;
            },
            else => {},
        }
        self.feed_mode = .browse;
        try self.set_message("Feed pruning cancelled");
        return true;
    }

    /// Opens a search over the pane in front of the reader.
    ///
    /// The scope is taken now rather than when the query is applied, so the
    /// pane a search narrows is the one it was started from even if something
    /// moves the focus meanwhile. The field starts empty every time: a
    /// half-typed query landing on top of the last one is worse than retyping
    /// a short one, and Esc still clears whatever is applied.
    fn begin_search(self: *Application) !void {
        self.search.clear();
        self.search_scope = search_target(self.focus);
        self.search_open = true;
    }

    /// The document is not a list, so a search started there narrows the
    /// articles behind it.
    fn search_target(focus: Focus) Focus {
        return switch (focus) {
            .categories => .categories,
            .feeds => .feeds,
            .articles, .reader => .articles,
        };
    }

    fn handle_search(self: *Application, key: layout.input.Key) !bool {
        switch (key) {
            .escape => {
                self.search.clear();
                self.applied_search.clear();
                self.search_open = false;
                self.refresh_lists();
                try self.set_message("Search cleared");
                return true;
            },
            .enter => {
                try self.applied_search.set(self.search.value());
                self.search_open = false;
                self.refresh_lists();
                if (self.applied_search.value().len == 0) {
                    try self.set_message("Search cleared");
                } else {
                    try self.set_message_formatted(
                        "Searching {s} for \"{s}\"",
                        .{ pane_name(self.search_scope), self.applied_search.value() },
                    );
                }
                return true;
            },
            .up => {
                self.move_pane(self.search_scope, -1);
                return true;
            },
            .down => {
                self.move_pane(self.search_scope, 1);
                return true;
            },
            .control => |byte| {
                if (byte == 'c') return false;
                if (byte == 'p') self.move_pane(self.search_scope, -1);
                if (byte == 'n') self.move_pane(self.search_scope, 1);
                return true;
            },
            else => {},
        }
        _ = try self.search.handle(key);
        return true;
    }

    /// Rebuilds every list a query can narrow. All three rather than only the
    /// searched one, because applying a search to one pane has to release the
    /// pane the previous search was narrowing.
    fn refresh_lists(self: *Application) void {
        self.refresh_categories();
        self.refresh_feeds();
        self.refresh_articles();
    }

    pub fn pane_name(focus: Focus) []const u8 {
        return switch (focus) {
            .categories => "categories",
            .feeds => "feeds",
            .articles => "articles",
            .reader => "the document",
        };
    }

    /// The applied query, but only for the pane it was applied to. Every other
    /// pane sees no query at all, which is what keeps a feed search out of the
    /// article list.
    pub fn search_query_for(self: *const Application, focus: Focus) []const u8 {
        if (focus != self.search_scope) return "";
        return self.applied_search.value();
    }

    fn handle_escape(self: *Application) !bool {
        if (self.reader_only) try self.close_reader();
        return true;
    }

    fn activate(self: *Application) !bool {
        switch (self.focus) {
            .categories => self.apply_category_cursor(),
            .feeds => self.apply_feed_cursor(),
            .articles => try self.read_selected(),
            .reader => if (self.reader_only) try self.close_reader() else self.open_reader(),
        }
        return true;
    }

    pub fn poll_background(self: *Application) !bool {
        const image_changed = self.image_loader.poll() catch |err| blk: {
            try self.set_message(@errorName(err));
            break :blk false;
        };
        const cache_changed = try self.poll_cache();
        if (!self.fetch_in_progress) {
            return image_changed or cache_changed;
        }
        var completed: [1]FetchResult = undefined;
        while (true) {
            const count = self.fetch_results.get(self.io, &completed, 0) catch |err| {
                return switch (err) {
                    error.Closed => image_changed or cache_changed,
                    error.Canceled => err,
                };
            };
            if (count == 0) break;
            const worker_index = completed[0].worker_index;
            if (backend == .native) {
                self.fetch_tasks[worker_index].await(self.io) catch |err| {
                    try self.set_message(@errorName(err));
                };
            }
            std.debug.assert(self.fetch_workers_busy[worker_index]);
            std.debug.assert(self.fetch_busy_count > 0);
            self.fetch_workers_busy[worker_index] = false;
            self.fetch_busy_count -= 1;
            self.apply_fetch_result(&completed[0]);
        }
        self.schedule_available_feeds() catch |err| {
            try self.set_message(@errorName(err));
        };
        self.fetch_in_progress = self.fetch_busy_count > 0;
        self.refresh_feeds();
        self.refresh_articles();
        self.set_refresh_message() catch {};
        if (!self.fetch_in_progress) {
            if (self.refresh_all_active) self.full_refresh_completed = true;
            self.refresh_all_active = false;
            self.save_cache() catch {};
        }
        return true;
    }

    /// Called from the JS glue via `rm_fetch_response` when a browser
    /// fetch completes. Parses the bytes and queues the result so the
    /// normal `poll_background` drain applies it to the feed/article
    /// state. Native builds never reach this method.
    pub fn web_deliver(
        self: *Application,
        worker_index: u16,
        status: i32,
        data: []const u8,
    ) void {
        if (backend != .web) return;
        if (worker_index >= limits.feed_fetch_concurrency) return;
        const outcome: FetchOutcome = if (self.fetch_transport.deliver(
            worker_index,
            status,
            data,
        )) |update|
            .{ .update = update }
        else |err|
            .{ .failure = err };
        self.fetch_results.putOne(self.io, .{
            .worker_index = worker_index,
            .feed_index = self.fetch_transport.requests[worker_index].feed_index,
            .outcome = outcome,
        }) catch {};
    }

    fn poll_cache(self: *Application) !bool {
        const failure = try self.cache_persistence.poll(
            self.io,
            &self.feeds,
            self.feed_count,
            &self.articles,
            self.article_count,
        );
        if (failure) |err| {
            try self.set_message(@errorName(err));
            return true;
        }
        return false;
    }

    pub fn request_selected_image(self: *Application) !bool {
        const article = self.selected_article() orelse return false;
        return self.image_loader.request(article.image_url.bytes()) catch |err| {
            try self.set_message(@errorName(err));
            return false;
        };
    }

    pub fn selected_image_path(self: *const Application) ?[]const u8 {
        if (self.article_cursor >= self.filtered_article_count) return null;
        const article = &self.articles[self.filtered_articles[self.article_cursor]];
        return self.image_loader.ready_path(article.image_url.bytes());
    }

    fn save_cache(self: *Application) !void {
        self.cache_persistence.request_save(
            self.io,
            &self.feeds,
            self.feed_count,
            &self.articles,
            self.article_count,
        ) catch |err| {
            try self.set_message(@errorName(err));
        };
    }

    fn apply_fetch_result(self: *Application, result: *const FetchResult) void {
        const feed = &self.feeds[result.feed_index];
        feed.fetched = true;
        switch (result.outcome) {
            .failure => {
                feed.failed = true;
                self.fetch_failure_count += 1;
            },
            .update => |*update| {
                feed.failed = false;
                self.fetch_success_count += 1;
                if (!update.title.is_empty() and !feed.title_pinned) {
                    feed.title = update.title;
                }
                self.merge_articles(update);
            },
        }
    }

    fn set_refresh_message(self: *Application) !void {
        if (self.fetch_next < self.fetch_stop or self.fetch_busy_count > 0) {
            var buffer: [96]u8 = undefined;
            const value = try std.fmt.bufPrint(
                &buffer,
                "Refreshing {d}/{d} | {d} articles",
                .{ self.fetch_next, self.fetch_stop, self.article_count },
            );
            try self.set_message(value);
        } else {
            var buffer: [128]u8 = undefined;
            const value = try std.fmt.bufPrint(
                &buffer,
                "Refresh complete | {d} feeds | {d} failed | {d} articles",
                .{ self.fetch_success_count, self.fetch_failure_count, self.article_count },
            );
            try self.set_message(value);
        }
    }

    fn merge_articles(self: *Application, update: *const parser.Update) void {
        var index: u16 = 0;
        while (index < update.article_count) : (index += 1) {
            const source = update.articles[index];
            if (self.find_article(source.url.bytes()) != null) continue;
            self.insert_article(source);
        }
    }

    fn insert_article(self: *Application, source: model.Article) void {
        const destination = if (self.article_count < limits.article_count_max) block: {
            const index = self.article_count;
            self.article_count += 1;
            break :block index;
        } else block: {
            const index = self.oldest_article_index();
            if (source.published_timestamp <=
                self.articles[index].published_timestamp) return;
            const old_feed = self.articles[index].feed_index;
            self.feeds[old_feed].article_count -|= 1;
            break :block index;
        };
        self.articles[destination] = source;
        self.articles[destination].read = self.read_state.contains(source.url.bytes());
        self.feeds[source.feed_index].article_count += 1;
    }

    fn oldest_article_index(self: *const Application) u16 {
        std.debug.assert(self.article_count == limits.article_count_max);
        var oldest: u16 = 0;
        var index: u16 = 1;
        while (index < self.article_count) : (index += 1) {
            if (self.articles[index].published_timestamp <
                self.articles[oldest].published_timestamp) oldest = index;
        }
        return oldest;
    }

    fn find_article(self: *const Application, url: []const u8) ?u16 {
        var index: u16 = 0;
        while (index < self.article_count) : (index += 1) {
            if (std.mem.eql(u8, self.articles[index].url.bytes(), url)) return index;
        }
        return null;
    }

    fn begin_add_feed(self: *Application) !void {
        if (self.fetch_in_progress) {
            try self.set_message("Wait for the current refresh before adding a feed");
            return;
        }
        if (self.feed_count == limits.feed_count_max) {
            try self.set_message("Feed limit reached");
            return;
        }
        self.feed_url_input.clear();
        self.feed_category_input.clear();
        self.feed_mode = .add_url;
        try self.close_reader();
        try self.set_message("Enter a feed URL, then press Enter");
    }

    fn commit_add_feed(self: *Application) !void {
        const feed = subscriptions.make_feed(
            self.feed_url_input.value(),
            self.feed_category_input.value(),
        ) catch |err| {
            try self.set_message(@errorName(err));
            return;
        };
        if (self.find_feed_url(feed.url.bytes()) != null) {
            try self.set_message("Feed is already subscribed");
            return;
        }
        const new_index = self.feed_count;
        self.feeds[new_index] = feed;
        var keep: [limits.feed_count_max]bool = @splat(false);
        @memset(keep[0 .. self.feed_count + 1], true);
        try self.persist_subscriptions(&keep, self.feed_count + 1);
        self.feed_count += 1;
        self.feed_mode = .browse;
        self.full_refresh_completed = false;
        self.rebuild_after_feed_change();
        self.active_feed = new_index;
        self.feed_cursor = new_index + 1;
        self.refresh_articles();
        try self.set_message("Feed added; refreshing it now");
        try self.start_refresh_selected();
    }

    fn begin_remove_feed(self: *Application) !void {
        if (self.focus != .feeds or self.active_feed == null) {
            try self.set_message("Focus a specific feed before removing it");
            return;
        }
        if (self.fetch_in_progress) {
            try self.set_message("Wait for the current refresh before removing a feed");
            return;
        }
        if (self.feed_count <= 1) {
            try self.set_message("The final feed cannot be removed");
            return;
        }
        self.feed_mode = .remove_confirm;
        try self.set_message("Press d again to remove this feed; any other key cancels");
    }

    fn remove_selected_feed(self: *Application) !void {
        const remove_index = self.active_feed orelse return;
        var keep: [limits.feed_count_max]bool = @splat(false);
        @memset(keep[0..self.feed_count], true);
        keep[remove_index] = false;
        try self.persist_subscriptions(&keep, self.feed_count);
        self.apply_feed_keep(&keep);
        self.feed_mode = .browse;
        try self.save_cache();
        try self.set_message("Feed removed");
    }

    fn begin_prune_feeds(self: *Application) !void {
        if (self.fetch_in_progress) {
            try self.set_message("Wait for the current refresh before pruning feeds");
            return;
        }
        if (!self.full_refresh_completed) {
            try self.set_message("Run R and finish a full refresh before pruning");
            return;
        }
        const failed = self.failed_feed_count();
        if (failed == 0) {
            try self.set_message("No unreachable feeds found");
            return;
        }
        self.feed_mode = .prune_confirm;
        var buffer: [128]u8 = undefined;
        const value = try std.fmt.bufPrint(
            &buffer,
            "Press P again to prune {d} failed feeds; any other key cancels",
            .{failed},
        );
        try self.set_message(value);
    }

    fn prune_failed_feeds(self: *Application) !void {
        var keep: [limits.feed_count_max]bool = @splat(false);
        var kept: u16 = 0;
        var index: u16 = 0;
        while (index < self.feed_count) : (index += 1) {
            keep[index] = !self.feeds[index].failed;
            kept += @intFromBool(keep[index]);
        }
        if (kept == 0) {
            self.feed_mode = .browse;
            try self.set_message("Prune refused: every feed failed");
            return;
        }
        try self.persist_subscriptions(&keep, self.feed_count);
        const removed = self.feed_count - kept;
        self.apply_feed_keep(&keep);
        self.feed_mode = .browse;
        try self.save_cache();
        var buffer: [64]u8 = undefined;
        const value = try std.fmt.bufPrint(&buffer, "Pruned {d} failed feeds", .{removed});
        try self.set_message(value);
    }

    fn start_refresh_all(self: *Application) !void {
        if (self.fetch_in_progress) {
            try self.set_message("A feed refresh is already running");
            return;
        }
        if (backend == .native) try fetcher_module.prepare_tls(&self.http_client);
        self.refresh_all_active = true;
        self.full_refresh_completed = false;
        var index: u16 = 0;
        while (index < self.feed_count) : (index += 1) {
            self.feeds[index].fetched = false;
            self.feeds[index].failed = false;
        }
        self.fetch_next = 0;
        self.fetch_stop = self.feed_count;
        self.fetch_success_count = 0;
        self.fetch_failure_count = 0;
        try self.schedule_available_feeds();
    }

    fn start_refresh_selected(self: *Application) !void {
        if (self.fetch_in_progress) {
            try self.set_message("A feed refresh is already running");
            return;
        }
        if (backend == .native) try fetcher_module.prepare_tls(&self.http_client);
        const feed_index = self.active_feed orelse {
            try self.start_refresh_all();
            return;
        };
        self.refresh_all_active = false;
        self.feeds[feed_index].fetched = false;
        self.feeds[feed_index].failed = false;
        self.fetch_next = feed_index;
        self.fetch_stop = feed_index + 1;
        self.fetch_success_count = 0;
        self.fetch_failure_count = 0;
        try self.schedule_available_feeds();
    }

    fn schedule_available_feeds(self: *Application) !void {
        if (backend == .native) {
            std.debug.assert(self.http_client.now != null or std.http.Client.disable_tls);
        }
        var worker_index: u16 = 0;
        while (worker_index < limits.feed_fetch_concurrency) : (worker_index += 1) {
            if (self.fetch_next >= self.fetch_stop) break;
            if (self.fetch_workers_busy[worker_index]) continue;
            try self.schedule_feed(worker_index);
        }
        self.fetch_in_progress = self.fetch_busy_count > 0;
    }

    fn schedule_feed(self: *Application, worker_index: u16) !void {
        std.debug.assert(worker_index < limits.feed_fetch_concurrency);
        std.debug.assert(!self.fetch_workers_busy[worker_index]);
        const feed_index = self.fetch_next;
        self.fetch_next += 1;
        switch (backend) {
            .native => self.fetch_tasks[worker_index].concurrent(
                self.io,
                fetch_task,
                .{
                    self.io,
                    &self.fetchers[worker_index],
                    &self.http_client,
                    &self.fetch_results,
                    worker_index,
                    feed_index,
                    self.feeds[feed_index].url,
                },
            ) catch |err| {
                try self.set_message(@errorName(err));
                return;
            },
            .web => self.fetch_transport.start(
                worker_index,
                feed_index,
                self.feeds[feed_index].url.bytes(),
            ),
        }
        self.fetch_workers_busy[worker_index] = true;
        self.fetch_busy_count += 1;
    }

    fn bookmark_selected(self: *Application) !void {
        const article = self.selected_article() orelse {
            try self.set_message("Nothing selected");
            return;
        };
        self.bookmark_store = .{};
        try self.bookmark_persistence.load(self.io, &self.bookmark_store);
        const feed = &self.feeds[article.feed_index];
        var tags_buffer: [96]u8 = undefined;
        const tags = std.fmt.bufPrint(
            &tags_buffer,
            "rss,{s}",
            .{feed.category.bytes()},
        ) catch "rss";
        var bookmark = bookmarks.Bookmark.init(
            article.title.bytes()[0..@min(
                article.title.bytes().len,
                bookmark_limits.bookmark_title_bytes_max,
            )],
            article.url.bytes(),
            tags,
            feed.title.bytes(),
        ) catch |err| {
            try self.set_message(@errorName(err));
            return;
        };
        model.set_truncated(&bookmark.description, article.summary.bytes());
        model.set_truncated(&bookmark.preview, article.summary.bytes());
        self.bookmark_store.add(bookmark) catch |err| {
            try self.set_message(if (err == error.DuplicateBookmark)
                "Already bookmarked"
            else
                @errorName(err));
            return;
        };
        try self.bookmark_persistence.save(self.io, &self.bookmark_store);
        try self.mark_selected_read();
        try self.set_message("Bookmarked");
    }

    fn open_selected(self: *Application) !void {
        const article = self.selected_article() orelse {
            try self.set_message("Nothing selected");
            return;
        };
        try bookmarks.browser.open(self.io, article.url.bytes());
        try self.mark_selected_read();
        try self.set_message("Opened in browser");
    }

    fn open_selected_image(self: *Application) !void {
        const article = self.selected_article() orelse {
            try self.set_message("Nothing selected");
            return;
        };
        const url = article.image_url.bytes();
        if (url.len == 0) {
            try self.set_message("This article has no image");
            return;
        }
        try bookmarks.browser.open(self.io, url);
        try self.set_message("Opened article image");
    }

    fn toggle_read(self: *Application) !void {
        const article = self.selected_article() orelse return;
        if (article.read) {
            article.read = false;
            self.read_state.mark_unread(article.url.bytes());
        } else {
            article.read = true;
            try self.read_state.mark_read(article.url.bytes());
        }
        try self.state_persistence.save(self.io, &self.read_state);
        self.refresh_feeds();
        self.refresh_articles();
        try self.set_message(if (article.read) "Marked read" else "Marked unread");
    }

    fn mark_selected_read(self: *Application) !void {
        const article = self.selected_article() orelse return;
        if (article.read) return;
        article.read = true;
        try self.read_state.mark_read(article.url.bytes());
        try self.state_persistence.save(self.io, &self.read_state);
        self.refresh_feeds();
        self.refresh_articles();
    }

    pub fn selected_article(self: *Application) ?*model.Article {
        if (self.article_cursor >= self.filtered_article_count) return null;
        return &self.articles[self.filtered_articles[self.article_cursor]];
    }

    pub fn selected_document(self: *Application) ?*const document.Document {
        if (self.article_cursor >= self.filtered_article_count) return null;
        const article_index = self.filtered_articles[self.article_cursor];
        const article = &self.articles[article_index];
        const source = if (article.content.is_empty())
            article.summary.bytes()
        else
            article.content.bytes();
        const source_length: u16 = @intCast(source.len);
        if (self.reader_document_article != article_index or
            self.reader_document_length != source_length)
        {
            self.reader_document = document.parse(source);
            self.reader_document_article = article_index;
            self.reader_document_length = source_length;
            self.reader_layout_valid = false;
        }
        return &self.reader_document;
    }

    pub fn unread_count(self: *const Application) u16 {
        return self.unread_article_count;
    }

    pub fn feed_unread_count(self: *const Application, feed_index: u16) u16 {
        if (feed_index >= self.feed_count) return 0;
        return self.feed_unread_counts[feed_index];
    }

    fn recount_unread(self: *Application) void {
        self.unread_article_count = 0;
        self.feed_unread_counts = @splat(0);
        var index: u16 = 0;
        while (index < self.article_count) : (index += 1) {
            const article = &self.articles[index];
            if (article.read) continue;
            self.unread_article_count += 1;
            self.feed_unread_counts[article.feed_index] += 1;
        }
    }

    fn find_feed_url(self: *const Application, url: []const u8) ?u16 {
        var index: u16 = 0;
        while (index < self.feed_count) : (index += 1) {
            if (std.mem.eql(u8, self.feeds[index].url.bytes(), url)) return index;
        }
        return null;
    }

    fn failed_feed_count(self: *const Application) u16 {
        var count: u16 = 0;
        var index: u16 = 0;
        while (index < self.feed_count) : (index += 1) {
            count += @intFromBool(self.feeds[index].failed);
        }
        return count;
    }

    fn persist_subscriptions(
        self: *Application,
        keep: *const [limits.feed_count_max]bool,
        count: u16,
    ) !void {
        try subscriptions.save(
            self.io,
            self.subscription_path.bytes(),
            &self.feeds,
            count,
            keep,
            &self.fetchers[0].response,
        );
    }

    fn apply_feed_keep(
        self: *Application,
        keep: *const [limits.feed_count_max]bool,
    ) void {
        var feed_map: [limits.feed_count_max]?u16 = @splat(null);
        var next_feed: u16 = 0;
        var feed_index: u16 = 0;
        while (feed_index < self.feed_count) : (feed_index += 1) {
            if (!keep[feed_index]) continue;
            feed_map[feed_index] = next_feed;
            self.feeds[next_feed] = self.feeds[feed_index];
            next_feed += 1;
        }
        self.feed_count = next_feed;
        self.compact_articles(&feed_map);
        self.full_refresh_completed = false;
        self.rebuild_after_feed_change();
    }

    fn compact_articles(
        self: *Application,
        feed_map: *const [limits.feed_count_max]?u16,
    ) void {
        var next_article: u16 = 0;
        var index: u16 = 0;
        while (index < self.article_count) : (index += 1) {
            const mapped = feed_map[self.articles[index].feed_index] orelse continue;
            self.articles[next_article] = self.articles[index];
            self.articles[next_article].feed_index = mapped;
            next_article += 1;
        }
        self.article_count = next_article;
        self.hydrate_cached_articles();
    }

    fn rebuild_after_feed_change(self: *Application) void {
        self.scope = .all;
        self.active_category.clear();
        self.active_feed = null;
        self.category_cursor = 0;
        self.feed_cursor = 0;
        self.article_cursor = 0;
        self.rebuild_categories();
        self.refresh_feeds();
        self.refresh_articles();
    }

    fn rebuild_categories(self: *Application) void {
        self.category_count = 0;
        var feed_index: u16 = 0;
        while (feed_index < self.feed_count) : (feed_index += 1) {
            const category = self.feeds[feed_index].category;
            if (self.find_category(category.bytes()) != null) continue;
            if (self.category_count == limits.category_count_max) break;
            self.categories[self.category_count] = category;
            self.category_count += 1;
        }
        self.refresh_categories();
    }

    /// The categories a search leaves visible.
    ///
    /// The two rows above them -- All articles and Unread -- are ways of
    /// scoping rather than categories, so a search over this pane narrows the
    /// names underneath and leaves those two anchors where they are.
    pub fn refresh_categories(self: *Application) void {
        const query = self.search_query_for(.categories);
        self.filtered_category_count = 0;
        var index: u16 = 0;
        while (index < self.category_count) : (index += 1) {
            if (!model.contains_ignore_case(self.categories[index].bytes(), query)) {
                continue;
            }
            self.filtered_categories[self.filtered_category_count] = index;
            self.filtered_category_count += 1;
        }
        const rows = self.filtered_category_count + 2;
        if (self.category_cursor >= rows) self.category_cursor = rows - 1;
        ensure_visible(
            self.category_cursor,
            &self.category_scroll,
            self.category_viewport,
        );
    }

    /// The category a row of the pane names, or null for the two anchors.
    pub fn category_at(self: *const Application, row: u16) ?*const model.CategoryName {
        if (row < 2) return null;
        const index = row - 2;
        if (index >= self.filtered_category_count) return null;
        return &self.categories[self.filtered_categories[index]];
    }

    pub fn category_row_count(self: *const Application) u16 {
        return self.filtered_category_count + 2;
    }

    fn find_category(self: *const Application, name: []const u8) ?u16 {
        var index: u16 = 0;
        while (index < self.category_count) : (index += 1) {
            if (std.ascii.eqlIgnoreCase(self.categories[index].bytes(), name)) return index;
        }
        return null;
    }

    pub fn refresh_feeds(self: *Application) void {
        self.recount_unread();
        const query = self.search_query_for(.feeds);
        self.filtered_feed_count = 0;
        var index: u16 = 0;
        while (index < self.feed_count) : (index += 1) {
            const feed = &self.feeds[index];
            const visible = switch (self.scope) {
                .all => true,
                .unread => self.feed_unread_count(index) > 0,
                .category => std.ascii.eqlIgnoreCase(
                    feed.category.bytes(),
                    self.active_category.bytes(),
                ),
            };
            if (!visible) continue;
            if (!feed_matches(feed, query)) continue;
            self.filtered_feeds[self.filtered_feed_count] = index;
            self.filtered_feed_count += 1;
        }
        if (self.feed_cursor > self.filtered_feed_count) self.feed_cursor = 0;
        self.ensure_feed_visible();
    }

    /// A feed answers to its name, its address and the group it is filed
    /// under, so searching for a category name in the feeds pane finds that
    /// group's feeds rather than nothing.
    fn feed_matches(feed: *const model.Feed, query: []const u8) bool {
        if (query.len == 0) return true;
        return model.contains_ignore_case(feed.title.bytes(), query) or
            model.contains_ignore_case(feed.url.bytes(), query) or
            model.contains_ignore_case(feed.category.bytes(), query);
    }

    pub fn refresh_articles(self: *Application) void {
        const selected_before = if (self.article_cursor < self.filtered_article_count)
            self.filtered_articles[self.article_cursor]
        else
            null;
        self.filtered_article_count = 0;
        var index: u16 = 0;
        while (index < self.article_count) : (index += 1) {
            const article = &self.articles[index];
            if (!self.article_visible(article)) continue;
            self.filtered_articles[self.filtered_article_count] = index;
            self.filtered_article_count += 1;
        }
        self.sort_filtered_articles();
        const selected_after = if (selected_before) |selected|
            self.find_filtered_article(selected)
        else
            null;
        if (selected_after) |cursor| {
            self.article_cursor = cursor;
        } else if (self.filtered_article_count == 0) {
            self.article_cursor = 0;
        } else if (self.article_cursor >= self.filtered_article_count) {
            self.article_cursor = self.filtered_article_count - 1;
        }
        const selected_now = if (self.article_cursor < self.filtered_article_count)
            self.filtered_articles[self.article_cursor]
        else
            null;
        if (selected_before != selected_now) self.reader_scroll = 0;
        self.ensure_article_visible();
    }

    fn find_filtered_article(self: *const Application, article_index: u16) ?u16 {
        var index: u16 = 0;
        while (index < self.filtered_article_count) : (index += 1) {
            if (self.filtered_articles[index] == article_index) return index;
        }
        return null;
    }

    fn sort_filtered_articles(self: *Application) void {
        std.mem.sortUnstable(
            u16,
            self.filtered_articles[0..self.filtered_article_count],
            self,
            article_index_is_newer,
        );
    }

    fn article_index_is_newer(self: *Application, lhs: u16, rhs: u16) bool {
        return self.article_is_newer(lhs, rhs);
    }

    fn article_is_newer(self: *const Application, lhs: u16, rhs: u16) bool {
        const lhs_time = self.articles[lhs].published_timestamp;
        const rhs_time = self.articles[rhs].published_timestamp;
        if (lhs_time != rhs_time) return lhs_time > rhs_time;
        return lhs > rhs;
    }

    fn article_visible(self: *const Application, article: *const model.Article) bool {
        if (self.scope == .unread and article.read) return false;
        if (self.scope == .category) {
            const category = self.feeds[article.feed_index].category.bytes();
            if (!std.ascii.eqlIgnoreCase(category, self.active_category.bytes())) return false;
        }
        if (self.active_feed) |feed_index| {
            if (article.feed_index != feed_index) return false;
        }
        return article.matches(
            &self.feeds[article.feed_index],
            self.search_query_for(.articles),
        );
    }

    fn select_scope(self: *Application, scope: Scope, category: []const u8) void {
        self.scope = scope;
        self.active_category.clear();
        if (scope == .category) {
            self.active_category.set(category) catch unreachable;
        }
        self.active_feed = null;
        self.feed_cursor = 0;
        self.article_cursor = 0;
        self.refresh_feeds();
        self.refresh_articles();
    }

    fn apply_category_cursor(self: *Application) void {
        if (self.category_cursor == 0) {
            self.select_scope(.all, "");
        } else if (self.category_cursor == 1) {
            self.select_scope(.unread, "");
        } else if (self.category_at(self.category_cursor)) |category| {
            self.select_scope(.category, category.bytes());
        }
    }

    fn apply_feed_cursor(self: *Application) void {
        self.active_feed = if (self.feed_cursor == 0)
            null
        else if (self.feed_cursor - 1 < self.filtered_feed_count)
            self.filtered_feeds[self.feed_cursor - 1]
        else
            null;
        self.article_cursor = 0;
        self.refresh_articles();
    }

    /// The panes the workspace lays out.
    ///
    /// The reader is not one of them. It opens over the workspace -- `v`, a
    /// click on an article, a click on the document -- and closes back to the
    /// articles it came from, so it has a pane only while it is fullscreen.
    /// Cycling through it landed the focus on a pane that was not on screen:
    /// the breadcrumb said Reader and nothing answered a key.
    const workspace_panes = [_]Focus{ .categories, .feeds, .articles };

    fn cycle_focus(self: *Application, delta: i8) !bool {
        std.debug.assert(delta == -1 or delta == 1);
        // Where the cycle goes is decided from the pane being left, including
        // when that is the reader; closing it afterwards would otherwise put
        // the focus on the articles and step from there instead.
        const next = next_workspace_pane(self.focus, delta);
        try self.close_reader();
        self.focus = next;
        std.debug.assert(self.focus != .reader);
        return true;
    }

    fn next_workspace_pane(focus: Focus, delta: i8) Focus {
        std.debug.assert(delta == -1 or delta == 1);
        const count: i8 = workspace_panes.len;
        for (workspace_panes, 0..) |pane, index| {
            if (pane != focus) continue;
            const next = @mod(@as(i8, @intCast(index)) + delta, count);
            return workspace_panes[@intCast(next)];
        }
        // The reader sits past the last pane: stepping back reaches the
        // articles it was opened from, stepping on wraps to the first pane.
        return if (delta > 0) workspace_panes[0] else workspace_panes[count - 1];
    }

    /// Opens the document over the workspace, which is the only state in which
    /// the reader has a pane of its own.
    fn open_reader(self: *Application) void {
        self.reader_only = true;
        self.focus = .reader;
        self.collapsed[focus_index(.reader)] = false;
    }

    /// Reads the selected article in the application rather than the browser,
    /// which is what `o` is for.
    fn read_selected(self: *Application) !void {
        if (self.selected_article() == null) {
            try self.set_message("Nothing selected");
            return;
        }
        self.open_reader();
        try self.set_message("Reading here; o opens it in the browser");
    }

    /// Leaves the fullscreen reader, taking the article as read.
    ///
    /// Dropping `reader_only` on its own would leave the focus naming a pane
    /// the workspace does not draw, so the focus comes back with it.
    ///
    /// The article is marked on the way out rather than on the way in because
    /// marking re-filters the list: in the unread scope, marking on open drops
    /// the article being read out of the filter and swaps the document for the
    /// next one while the reader is still showing it.
    fn close_reader(self: *Application) !void {
        const was_reading = self.reader_only or self.focus == .reader;
        self.reader_only = false;
        if (self.focus == .reader) self.focus = .articles;
        if (was_reading) try self.mark_selected_read();
    }

    pub fn is_collapsed(self: *const Application, focus: Focus) bool {
        return self.collapsed[focus_index(focus)];
    }

    fn toggle_focused_section(self: *Application) !void {
        const index = focus_index(self.focus);
        self.collapsed[index] = !self.collapsed[index];
        try self.close_reader();
    }

    fn move_focused(self: *Application, delta: i16) bool {
        if (self.is_collapsed(self.focus)) return true;
        switch (self.focus) {
            .categories => self.move_categories(delta),
            .feeds => self.move_feeds(delta),
            .articles => self.move_articles(delta),
            .reader => self.move_reader(delta),
        }
        return true;
    }

    fn move_page(self: *Application, direction: i16) void {
        const rows = switch (self.focus) {
            .categories => self.category_viewport,
            .feeds => self.feed_viewport,
            .articles => self.article_viewport,
            .reader => self.reader_viewport,
        };
        _ = self.move_focused(direction * @as(i16, @intCast(@max(rows, 1))));
    }

    fn move_to_edge(self: *Application, last: bool) bool {
        switch (self.focus) {
            .categories => {
                self.category_cursor = if (last) self.category_row_count() - 1 else 0;
                self.apply_category_cursor();
            },
            .feeds => {
                self.feed_cursor = if (last) self.filtered_feed_count else 0;
                self.apply_feed_cursor();
            },
            .articles => {
                self.article_cursor = if (last and self.filtered_article_count > 0)
                    self.filtered_article_count - 1
                else
                    0;
                self.ensure_article_visible();
            },
            .reader => {
                self.reader_scroll = if (last)
                    self.reader_line_count -| self.reader_viewport
                else
                    0;
            },
        }
        return true;
    }

    fn move_categories(self: *Application, delta: i16) void {
        self.category_cursor = move_index(
            self.category_cursor,
            self.category_row_count(),
            delta,
        );
        self.apply_category_cursor();
        ensure_visible(
            self.category_cursor,
            &self.category_scroll,
            self.category_viewport,
        );
    }

    fn move_feeds(self: *Application, delta: i16) void {
        self.feed_cursor = move_index(self.feed_cursor, self.filtered_feed_count + 1, delta);
        self.apply_feed_cursor();
        self.ensure_feed_visible();
    }

    fn move_articles(self: *Application, delta: i16) void {
        const previous = self.article_cursor;
        self.article_cursor = move_index(
            self.article_cursor,
            self.filtered_article_count,
            delta,
        );
        if (previous != self.article_cursor) self.reader_scroll = 0;
        self.ensure_article_visible();
    }

    fn move_reader(self: *Application, delta: i16) void {
        const maximum = self.reader_line_count -| self.reader_viewport;
        self.reader_scroll = move_index_clamped(self.reader_scroll, maximum +| 1, delta);
    }

    pub fn set_category_viewport(self: *Application, rows: u16) void {
        self.category_viewport = @max(rows, 1);
        ensure_visible(self.category_cursor, &self.category_scroll, self.category_viewport);
    }

    pub fn set_feed_viewport(self: *Application, rows: u16) void {
        self.feed_viewport = @max(rows, 1);
        self.ensure_feed_visible();
    }

    pub fn set_article_viewport(self: *Application, rows: u16) void {
        self.article_viewport = @max(rows, 1);
        self.ensure_article_visible();
    }

    pub fn set_reader_metrics(self: *Application, lines: u16, rows: u16) void {
        self.reader_line_count = lines;
        self.reader_viewport = @max(rows, 1);
        self.reader_scroll = @min(self.reader_scroll, lines -| self.reader_viewport);
    }

    pub fn reset_pane_geometry(self: *Application) void {
        self.pane_geometry = @splat(.{});
    }

    pub fn set_pane_bounds(self: *Application, focus: Focus, rect: layout.Rect) void {
        self.pane_geometry[focus_index(focus)].bounds = rect;
    }

    pub fn set_pane_list(self: *Application, focus: Focus, rect: layout.Rect, row_height: u8) void {
        const geometry = &self.pane_geometry[focus_index(focus)];
        geometry.list = rect;
        geometry.row_height = row_height;
    }

    fn ensure_feed_visible(self: *Application) void {
        ensure_visible(self.feed_cursor, &self.feed_scroll, self.feed_viewport);
    }

    fn ensure_article_visible(self: *Application) void {
        ensure_visible(self.article_cursor, &self.article_scroll, self.article_viewport);
    }

    fn set_message(self: *Application, value: []const u8) !void {
        try self.message.set(value);
    }

    fn set_message_formatted(
        self: *Application,
        comptime format: []const u8,
        arguments: anytype,
    ) !void {
        var buffer: [Message.capacity_bytes]u8 = undefined;
        // A message that does not fit is truncated: it is a hint on a status
        // line, not something to fail a load over.
        const value = std.fmt.bufPrint(&buffer, format, arguments) catch &buffer;
        try self.message.set(value);
    }
};

fn move_index(index: u16, count: u16, delta: i16) u16 {
    if (count == 0) return 0;
    return move_index_clamped(index, count, delta);
}

fn move_index_clamped(index: u16, count: u16, delta: i16) u16 {
    if (count == 0) return 0;
    const maximum: i32 = count - 1;
    const moved = @as(i32, index) + delta;
    return @intCast(std.math.clamp(moved, 0, maximum));
}

fn ensure_visible(selected: u16, scroll: *u16, viewport: u16) void {
    std.debug.assert(viewport > 0);
    if (selected < scroll.*) scroll.* = selected;
    if (selected >= scroll.* +| viewport) scroll.* = selected - viewport + 1;
}

fn focus_index(focus: Focus) u8 {
    return @intCast(@backingInt(focus));
}

fn fetch_task(
    io: std.Io,
    fetcher: *fetcher_module.Fetcher,
    client: *std.http.Client,
    results: *FetchResultQueue,
    worker_index: u16,
    feed_index: u16,
    url: model.FeedUrl,
) std.Io.Cancelable!void {
    const outcome: FetchOutcome = if (fetcher.fetch(client, url.bytes(), feed_index)) |update|
        .{ .update = update }
    else |err|
        .{ .failure = err };
    results.putOne(io, .{
        .worker_index = worker_index,
        .feed_index = feed_index,
        .outcome = outcome,
    }) catch |err| switch (err) {
        error.Closed => return,
        error.Canceled => return error.Canceled,
    };
}

test "filters honor category, feed, unread, and search scopes" {
    const application = try Application.create(
        std.testing.allocator,
        std.testing.io,
        &@import("data").paths.testing_paths,
    );
    defer application.destroy(std.testing.allocator);
    application.feed_count = 2;
    application.feeds[0] = .{
        .title = try model.FeedTitle.init("Systems"),
        .url = try model.FeedUrl.init("https://one.test/rss"),
        .category = try model.CategoryName.init("Tech"),
    };
    application.feeds[1] = .{
        .title = try model.FeedTitle.init("Ideas"),
        .url = try model.FeedUrl.init("https://two.test/rss"),
        .category = try model.CategoryName.init("Context"),
    };
    application.article_count = 2;
    application.articles[0] = .{
        .title = try model.ArticleTitle.init("Zig release"),
        .url = try model.ArticleUrl.init("https://one.test/zig"),
        .feed_index = 0,
        .published_timestamp = 100,
    };
    application.articles[1] = .{
        .title = try model.ArticleTitle.init("A long essay"),
        .url = try model.ArticleUrl.init("https://two.test/essay"),
        .feed_index = 1,
        .published_timestamp = 200,
        .read = true,
    };
    application.rebuild_categories();
    _ = try application.handle_key(.{ .character = '?' });
    try std.testing.expect(application.help_open);
    _ = try application.handle_key(.{ .character = '?' });
    try std.testing.expect(!application.help_open);
    application.select_scope(.all, "");
    try std.testing.expectEqual(@as(u16, 1), application.filtered_articles[0]);
    application.focus = .articles;
    _ = try application.handle_character('c');
    try std.testing.expect(application.is_collapsed(.articles));
    _ = try application.handle_character('c');
    try std.testing.expect(!application.is_collapsed(.articles));
    _ = try application.handle_character('v');
    try std.testing.expect(application.reader_only);
    try std.testing.expectEqual(Focus.reader, application.focus);
    _ = try application.handle_key(.escape);
    try std.testing.expect(!application.reader_only);
    application.select_scope(.category, "Tech");
    try std.testing.expectEqual(@as(u16, 1), application.filtered_article_count);
    application.select_scope(.unread, "");
    try std.testing.expectEqual(@as(u16, 1), application.filtered_article_count);
    _ = try application.search.handle(.{ .character = 'Z' });
    application.refresh_articles();
    try std.testing.expectEqual(@as(u16, 1), application.filtered_article_count);
}

test "enter reads the article here and leaving it marks it read" {
    const application = try Application.create(
        std.testing.allocator,
        std.testing.io,
        &@import("data").paths.testing_paths,
    );
    defer application.destroy(std.testing.allocator);
    application.feed_count = 1;
    application.feeds[0] = .{
        .title = try model.FeedTitle.init("Systems"),
        .url = try model.FeedUrl.init("https://one.test/rss"),
        .category = try model.CategoryName.init("Tech"),
    };
    application.article_count = 1;
    application.articles[0] = .{
        .title = try model.ArticleTitle.init("Zig release"),
        .url = try model.ArticleUrl.init("https://one.test/zig"),
        .feed_index = 0,
        .published_timestamp = 100,
    };
    application.rebuild_categories();
    application.select_scope(.unread, "");
    application.focus = .articles;

    // Enter opens the document here rather than handing the article to the
    // browser, which is what o is for.
    _ = try application.handle_key(.enter);
    try std.testing.expect(application.reader_only);
    try std.testing.expectEqual(Focus.reader, application.focus);
    // Still unread while it is being read: marking it here would drop it out
    // of the unread scope and swap the document under the reader.
    try std.testing.expect(!application.articles[0].read);
    try std.testing.expectEqual(@as(u16, 1), application.filtered_article_count);

    _ = try application.handle_key(.escape);
    try std.testing.expect(!application.reader_only);
    try std.testing.expectEqual(Focus.articles, application.focus);
    try std.testing.expect(application.articles[0].read);

    // Moving between panes without ever opening the reader leaves the article
    // alone.
    application.select_scope(.all, "");
    application.articles[0].read = false;
    application.read_state.mark_unread(application.articles[0].url.bytes());
    _ = try application.handle_character('l');
    _ = try application.handle_character('h');
    try std.testing.expect(!application.articles[0].read);
}

/// Two categories, three feeds and two articles, enough for a search to have
/// something to leave out in every pane.
fn searchable_application() !*Application {
    const application = try Application.create(
        std.testing.allocator,
        std.testing.io,
        &@import("data").paths.testing_paths,
    );
    errdefer application.destroy(std.testing.allocator);
    application.feed_count = 3;
    application.feeds[0] = try subscriptions.make_feed("https://zig.test/rss", "Systems");
    application.feeds[1] = try subscriptions.make_feed("https://beetle.test/rss", "Systems");
    application.feeds[2] = try subscriptions.make_feed("https://poetry.test/rss", "Letters");
    try application.feeds[0].title.set("Zig Devlog");
    try application.feeds[1].title.set("TigerBeetle");
    try application.feeds[2].title.set("Poetry Daily");
    application.article_count = 2;
    application.articles[0] = .{
        .title = try model.ArticleTitle.init("Zig release notes"),
        .url = try model.ArticleUrl.init("https://zig.test/release"),
        .feed_index = 0,
        .published_timestamp = 200,
    };
    application.articles[1] = .{
        .title = try model.ArticleTitle.init("A poem"),
        .url = try model.ArticleUrl.init("https://poetry.test/poem"),
        .feed_index = 2,
        .published_timestamp = 100,
    };
    application.rebuild_categories();
    application.refresh_feeds();
    application.refresh_articles();
    return application;
}

fn search_for(application: *Application, query: []const u8) !void {
    _ = try application.handle_character('/');
    for (query) |byte| {
        _ = try application.handle_key(.{ .character = byte });
    }
    _ = try application.handle_key(.enter);
}

test "a search narrows the pane it was started from" {
    const application = try searchable_application();
    defer application.destroy(std.testing.allocator);

    // Feeds: the query filters the feed list and leaves the articles alone.
    application.focus = .feeds;
    try search_for(application, "zig");
    try std.testing.expectEqual(Focus.feeds, application.search_scope);
    try std.testing.expectEqual(@as(u16, 1), application.filtered_feed_count);
    try std.testing.expectEqualStrings(
        "Zig Devlog",
        application.feeds[application.filtered_feeds[0]].title.bytes(),
    );
    try std.testing.expectEqual(@as(u16, 2), application.filtered_article_count);
    try std.testing.expectEqual(@as(u16, 2), application.filtered_category_count);

    // Categories: the same keystroke on the next pane over means the category
    // list, and it releases the feed list it was holding.
    application.focus = .categories;
    try search_for(application, "let");
    try std.testing.expectEqual(Focus.categories, application.search_scope);
    try std.testing.expectEqual(@as(u16, 1), application.filtered_category_count);
    try std.testing.expectEqualStrings(
        "Letters",
        application.category_at(2).?.bytes(),
    );
    try std.testing.expectEqual(@as(u16, 3), application.filtered_feed_count);

    // Articles: unchanged from before there were pane searches.
    application.focus = .articles;
    try search_for(application, "poem");
    try std.testing.expectEqual(@as(u16, 1), application.filtered_article_count);
    try std.testing.expectEqual(@as(u16, 2), application.filtered_category_count);
    try std.testing.expectEqual(@as(u16, 3), application.filtered_feed_count);
}

test "a feed search matches names, addresses and categories" {
    const application = try searchable_application();
    defer application.destroy(std.testing.allocator);
    application.focus = .feeds;

    try search_for(application, "Systems");
    try std.testing.expectEqual(@as(u16, 2), application.filtered_feed_count);
    try search_for(application, "beetle.test");
    try std.testing.expectEqual(@as(u16, 1), application.filtered_feed_count);
}

test "clearing a search restores the pane it narrowed" {
    const application = try searchable_application();
    defer application.destroy(std.testing.allocator);
    application.focus = .feeds;
    try search_for(application, "zig");
    try std.testing.expectEqual(@as(u16, 1), application.filtered_feed_count);

    _ = try application.handle_character('/');
    _ = try application.handle_key(.escape);
    try std.testing.expectEqual(@as(u16, 3), application.filtered_feed_count);
    try std.testing.expectEqual(@as(usize, 0), application.applied_search.value().len);
}

test "the category cursor follows the rows a search leaves" {
    const application = try searchable_application();
    defer application.destroy(std.testing.allocator);
    application.focus = .categories;
    // Two anchors plus two categories; the cursor sits on the last row.
    application.category_cursor = 3;
    application.apply_category_cursor();

    try search_for(application, "let");
    // One category left, so three rows -- the cursor cannot still be on row 3.
    try std.testing.expectEqual(@as(u16, 3), application.category_row_count());
    try std.testing.expect(application.category_cursor < 3);
    // And selecting the remaining row scopes to that category, not to whatever
    // sat at that index before the search.
    application.category_cursor = 2;
    application.apply_category_cursor();
    try std.testing.expectEqualStrings("Letters", application.active_category.bytes());
}

test "a new search starts from an empty field" {
    // Otherwise the next query is typed onto the end of the last one.
    const application = try searchable_application();
    defer application.destroy(std.testing.allocator);
    application.focus = .feeds;
    try search_for(application, "zig");

    _ = try application.handle_character('/');
    try std.testing.expectEqual(@as(usize, 0), application.search.value().len);
    try search_for(application, "beetle");
    try std.testing.expectEqual(@as(u16, 1), application.filtered_feed_count);
    try std.testing.expectEqualStrings(
        "TigerBeetle",
        application.feeds[application.filtered_feeds[0]].title.bytes(),
    );
}

test "focus cycles only through panes the workspace draws" {
    // The workspace has no reader pane. Cycling into one focused a pane that
    // was never laid out: the breadcrumb said Reader and h/j/k answered from a
    // pane that was not on screen.
    const application = try Application.create(
        std.testing.allocator,
        std.testing.io,
        &@import("data").paths.testing_paths,
    );
    defer application.destroy(std.testing.allocator);

    application.focus = .categories;
    var step: u8 = 0;
    while (step < 8) : (step += 1) {
        _ = try application.handle_character('l');
        try std.testing.expect(application.focus != .reader);
    }
    while (step > 0) : (step -= 1) {
        _ = try application.handle_character('h');
        try std.testing.expect(application.focus != .reader);
    }
    try std.testing.expectEqual(Focus.categories, application.focus);

    // The reader is reachable, and stepping out of it lands on the articles it
    // was opened from rather than on nothing.
    _ = try application.handle_character('v');
    try std.testing.expect(application.reader_only);
    try std.testing.expectEqual(Focus.reader, application.focus);
    _ = try application.handle_character('h');
    try std.testing.expectEqual(Focus.articles, application.focus);
    try std.testing.expect(!application.reader_only);

    // Every other way out of fullscreen brings the focus back too.
    _ = try application.handle_character('v');
    _ = try application.handle_character('c');
    try std.testing.expectEqual(Focus.articles, application.focus);
    _ = try application.handle_character('v');
    _ = try application.handle_key(.{ .character = '?' });
    try std.testing.expectEqual(Focus.articles, application.focus);
}
