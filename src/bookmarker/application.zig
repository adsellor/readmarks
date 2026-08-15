const std = @import("std");
const terminal = @import("markix").terminal;
const layout = @import("markix").layout;
const FixedText = @import("data").FixedText;

const bookmarks = @import("data").bookmarks;
const limits = @import("data").limits;
const Paths = @import("data").Paths;
const page = @import("data").page;
const Rect = layout.Rect;

const SearchInput = terminal.widgets.TextInput(limits.search_bytes_max);
const TitleInput = terminal.widgets.TextInput(limits.bookmark_title_bytes_max);
const UrlInput = terminal.widgets.TextInput(limits.bookmark_url_bytes_max);
const TagsInput = terminal.widgets.TextInput(limits.bookmark_tags_bytes_max);
const NotesInput = terminal.widgets.TextInput(limits.bookmark_notes_bytes_max);
const CommandInput = terminal.widgets.TextInput(limits.search_bytes_max);
const Message = FixedText(160);
const PageUrl = FixedText(limits.bookmark_url_bytes_max);
pub const Tag = FixedText(limits.tag_name_bytes_max);

pub const Mode = enum { browse, search, add, confirm_delete, command, focus };
pub const Field = enum { title, url, tags, notes };
pub const BrowserFocus = enum { scopes, bookmarks, preview };
pub const ScopeKind = enum { all, favorites, tag };
pub const CommandAction = enum {
    add,
    open,
    toggle_favorite,
    refresh,
    browse_all,
    browse_favorites,
};
pub const CommandResult = union(enum) {
    action: CommandAction,
    bookmark: u16,
    tag: u16,
};
pub const MouseListRegion = struct {
    rect: Rect,
    scroll: u16,
    row_height: u8,
};
pub const MouseCategoryRegion = struct {
    rect: Rect,
    scope_index: u16,
};
pub const MouseFieldRegion = struct {
    rect: Rect,
    field: Field,
};
pub const MouseLayout = struct {
    scopes: ?MouseListRegion = null,
    bookmarks: ?MouseListRegion = null,
    preview: ?Rect = null,
    focus: ?MouseListRegion = null,
    focus_modal: ?Rect = null,
    finder_results: ?MouseListRegion = null,
    command_results: ?MouseListRegion = null,
    categories: [3]MouseCategoryRegion = undefined,
    category_count: u8 = 0,
    fields: [4]MouseFieldRegion = undefined,
    field_count: u8 = 0,
};

const PageRequest = struct {
    store_index: u16,
    url: PageUrl,
};

const PageOutcome = union(enum) {
    metadata: page.Metadata,
    failure: anyerror,
};

const PageResult = struct {
    request: PageRequest,
    outcome: PageOutcome,
};

const PageResultQueue = std.Io.Queue(PageResult);

pub const Application = struct {
    io: std.Io,
    page_fetcher: page.Fetcher,
    page_tasks: std.Io.Group = .init,
    page_result_buffer: [1]PageResult = undefined,
    page_results: PageResultQueue = undefined,
    page_fetch_in_progress: bool = false,
    store: bookmarks.Store = .{},
    persistence: bookmarks.Persistence,
    filtered: [limits.bookmark_count_max]u16 = undefined,
    filtered_count: u16 = 0,
    selected: u16 = 0,
    scroll: u16 = 0,
    viewport_rows: u16 = 1,
    mode: Mode = .browse,
    browser_focus: BrowserFocus = .bookmarks,
    scope_kind: ScopeKind = .all,
    active_tag: Tag = .{},
    tags_available: [limits.tag_count_max]Tag = undefined,
    tag_count: u16 = 0,
    scope_cursor: u16 = 0,
    scope_scroll: u16 = 0,
    scope_viewport_rows: u16 = 1,
    preview_scroll: u16 = 0,
    preview_line_count: u16 = 0,
    preview_viewport_rows: u16 = 1,
    narrow_preview: bool = false,
    focus_search_open: bool = false,
    search: SearchInput = .{},
    command: CommandInput = .{},
    command_results: [limits.command_result_count_max]CommandResult = undefined,
    command_result_count: u16 = 0,
    command_selected: u16 = 0,
    command_scroll: u16 = 0,
    command_viewport_rows: u16 = 1,
    title: TitleInput = .{},
    url: UrlInput = .{},
    tags: TagsInput = .{},
    notes: NotesInput = .{},
    field: Field = .url,
    message: Message = .{},
    mouse_layout: MouseLayout = .{},
    /// Persistent DOM view. Kept across frames so node dirty flags mean
    /// something: an edited row stays the only node that repaints.
    dom_view: @import("dom_view.zig").View = .{},

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        paths: *const Paths,
    ) !*Application {
        const application = try allocator.create(Application);
        errdefer allocator.destroy(application);
        application.* = .{
            .io = io,
            .page_fetcher = page.Fetcher.init(allocator, io),
            .persistence = try bookmarks.Persistence.init(paths),
        };
        application.page_results = .init(&application.page_result_buffer);
        try application.set_message("Ready");
        return application;
    }

    pub fn destroy(self: *Application, allocator: std.mem.Allocator) void {
        self.page_tasks.cancel(self.io);
        self.page_results.close(self.io);
        self.page_fetcher.deinit();
        allocator.destroy(self);
    }

    pub fn load(self: *Application) !void {
        try self.persistence.load(self.io, &self.store);
        self.rebuild_tags();
        self.refresh_filter();
        if (self.store.count == 0) {
            try self.set_message("No bookmarks yet. Press a to add one.");
        } else {
            try self.set_message("Bookmarks loaded");
        }
    }

    pub fn handle_key(self: *Application, key: layout.input.Key) !bool {
        switch (key) {
            .pointer => |pointer| return self.handle_pointer(pointer),
            else => {},
        }
        return switch (self.mode) {
            .browse => self.handle_browse(key),
            .search => self.handle_search(key),
            .add => self.handle_add(key),
            .confirm_delete => self.handle_delete_confirmation(key),
            .command => self.handle_command(key),
            .focus => self.handle_focus(key),
        };
    }

    fn handle_pointer(
        self: *Application,
        pointer: layout.input.Pointer,
    ) !bool {
        if (pointer.action != .press) return true;
        return switch (pointer.button) {
            .primary => self.handle_pointer_primary(pointer),
            .wheel_up => self.handle_pointer_wheel(pointer, -3),
            .wheel_down => self.handle_pointer_wheel(pointer, 3),
            else => true,
        };
    }

    fn handle_pointer_primary(
        self: *Application,
        pointer: layout.input.Pointer,
    ) !bool {
        if (self.click_focus_overlay(pointer)) return true;
        if (self.click_form_field(pointer)) return true;
        if (self.click_command_results(pointer)) return true;
        if (self.click_scopes(pointer)) return true;
        if (self.click_bookmarks(pointer)) return true;
        if (contains_optional(self.mouse_layout.preview, pointer.x, pointer.y)) {
            self.browser_focus = .preview;
            return true;
        }
        if (self.click_focus_results(pointer)) return true;
        return true;
    }

    fn click_form_field(
        self: *Application,
        pointer: layout.input.Pointer,
    ) bool {
        var index: u8 = 0;
        while (index < self.mouse_layout.field_count) : (index += 1) {
            const field = self.mouse_layout.fields[index];
            if (!contains(field.rect, pointer.x, pointer.y)) continue;
            self.field = field.field;
            return true;
        }
        return false;
    }

    fn handle_pointer_wheel(
        self: *Application,
        pointer: layout.input.Pointer,
        delta: i16,
    ) bool {
        if (region_contains(self.mouse_layout.finder_results, pointer.x, pointer.y)) {
            self.move_selection(delta);
            return true;
        }
        if (contains_optional(self.mouse_layout.focus_modal, pointer.x, pointer.y)) {
            return true;
        }
        if (region_contains(self.mouse_layout.command_results, pointer.x, pointer.y)) {
            self.move_command_selection(delta);
            return true;
        }
        if (region_contains(self.mouse_layout.scopes, pointer.x, pointer.y)) {
            self.move_scope(if (delta < 0) -1 else 1);
            return true;
        }
        if (region_contains(self.mouse_layout.bookmarks, pointer.x, pointer.y) or
            region_contains(self.mouse_layout.focus, pointer.x, pointer.y))
        {
            self.move_selection(delta);
            return true;
        }
        if (contains_optional(self.mouse_layout.preview, pointer.x, pointer.y)) {
            self.move_preview(delta);
        }
        return true;
    }

    fn click_focus_overlay(
        self: *Application,
        pointer: layout.input.Pointer,
    ) bool {
        var index: u8 = 0;
        while (index < self.mouse_layout.category_count) : (index += 1) {
            const category = self.mouse_layout.categories[index];
            if (!contains(category.rect, pointer.x, pointer.y)) continue;
            self.scope_cursor = category.scope_index;
            self.apply_scope_cursor();
            return true;
        }
        if (self.mouse_layout.finder_results) |region| {
            if (contains(region.rect, pointer.x, pointer.y)) {
                if (list_index(region, pointer.x, pointer.y)) |result_index| {
                    if (result_index < self.filtered_count) {
                        self.selected = result_index;
                        self.ensure_visible();
                    }
                }
                return true;
            }
        }
        const modal = self.mouse_layout.focus_modal orelse return false;
        if (contains(modal, pointer.x, pointer.y)) return true;
        self.focus_search_open = false;
        return false;
    }

    fn click_command_results(
        self: *Application,
        pointer: layout.input.Pointer,
    ) bool {
        const region = self.mouse_layout.command_results orelse return false;
        if (!contains(region.rect, pointer.x, pointer.y)) return false;
        const result_index = list_index(region, pointer.x, pointer.y) orelse
            return true;
        if (result_index < self.command_result_count) {
            self.command_selected = result_index;
            self.ensure_command_visible();
        }
        return true;
    }

    fn click_scopes(
        self: *Application,
        pointer: layout.input.Pointer,
    ) bool {
        const region = self.mouse_layout.scopes orelse return false;
        if (!contains(region.rect, pointer.x, pointer.y)) return false;
        const scope_index = list_index(region, pointer.x, pointer.y) orelse
            return true;
        if (scope_index < self.tag_count + 2) {
            self.scope_cursor = scope_index;
            self.browser_focus = .scopes;
            self.apply_scope_cursor();
        }
        return true;
    }

    fn click_bookmarks(
        self: *Application,
        pointer: layout.input.Pointer,
    ) bool {
        const region = self.mouse_layout.bookmarks orelse return false;
        if (!contains(region.rect, pointer.x, pointer.y)) return false;
        self.browser_focus = .bookmarks;
        self.select_pointer_bookmark(region, pointer);
        return true;
    }

    fn click_focus_results(
        self: *Application,
        pointer: layout.input.Pointer,
    ) bool {
        const region = self.mouse_layout.focus orelse return false;
        if (!contains(region.rect, pointer.x, pointer.y)) return false;
        self.select_pointer_bookmark(region, pointer);
        return true;
    }

    fn select_pointer_bookmark(
        self: *Application,
        region: MouseListRegion,
        pointer: layout.input.Pointer,
    ) void {
        const bookmark_index = list_index(region, pointer.x, pointer.y) orelse
            return;
        if (bookmark_index >= self.filtered_count) return;
        self.selected = bookmark_index;
        self.ensure_visible();
    }

    pub fn poll_background(self: *Application) !bool {
        if (!self.page_fetch_in_progress) return false;
        var completed: [1]PageResult = undefined;
        const count = self.page_results.get(self.io, &completed, 0) catch |err| {
            return switch (err) {
                error.Closed => false,
                error.Canceled => err,
            };
        };
        if (count == 0) return false;
        try self.page_tasks.await(self.io);
        self.page_fetch_in_progress = false;
        try self.apply_page_result(completed[0]);
        return true;
    }

    pub fn selected_bookmark(self: *Application) ?*bookmarks.Bookmark {
        if (self.selected >= self.filtered_count) return null;
        return self.store.get(self.filtered[self.selected]);
    }

    pub fn set_viewport_rows(self: *Application, rows: u16) void {
        self.viewport_rows = @max(rows, 1);
        self.ensure_visible();
    }

    pub fn set_scope_viewport_rows(self: *Application, rows: u16) void {
        self.scope_viewport_rows = @max(rows, 1);
        self.ensure_scope_visible();
    }

    pub fn set_preview_metrics(
        self: *Application,
        line_count: u16,
        viewport_rows: u16,
    ) void {
        self.preview_line_count = line_count;
        self.preview_viewport_rows = @max(viewport_rows, 1);
        const maximum = line_count -| self.preview_viewport_rows;
        self.preview_scroll = @min(self.preview_scroll, maximum);
    }

    fn handle_browse(self: *Application, key: layout.input.Key) !bool {
        switch (key) {
            .character => |byte| switch (byte) {
                'q' => return false,
                'j' => self.move_focused(1),
                'k' => self.move_focused(-1),
                'h' => self.focus_left(),
                'l' => self.focus_right(),
                'g' => self.select_first(),
                'G' => self.select_last(),
                'a' => self.begin_add(),
                '/' => self.mode = .search,
                'o' => try self.open_selected(),
                'f' => try self.toggle_favorite(),
                'r' => try self.refresh_selected_page(),
                '1' => self.select_scope(.all, ""),
                '2' => self.select_scope(.favorites, ""),
                'd' => try self.begin_delete(),
                'v' => self.narrow_preview = !self.narrow_preview,
                ':' => self.begin_command(),
                'z' => try self.begin_focus(),
                else => {},
            },
            .enter => try self.activate_focused(),
            .down => self.move_focused(1),
            .up => self.move_focused(-1),
            .tab => self.cycle_focus(),
            .home => self.select_first(),
            .end => self.select_last(),
            .control => |byte| switch (byte) {
                'c' => return false,
                'd' => self.move_page(1),
                'u' => self.move_page(-1),
                'p' => self.begin_command(),
                else => {},
            },
            else => {},
        }
        return true;
    }

    fn handle_focus(self: *Application, key: layout.input.Key) !bool {
        if (self.focus_search_open) return self.handle_focus_search(key);
        switch (key) {
            .escape => try self.leave_focus(),
            .character => |byte| switch (byte) {
                'q', 'z' => try self.leave_focus(),
                '/' => try self.begin_focus_search(),
                'j' => self.move_selection(1),
                'k' => self.move_selection(-1),
                'g' => self.select_first(),
                'G' => self.select_last(),
                'o' => try self.open_selected(),
                'f' => try self.toggle_favorite(),
                'r' => try self.refresh_selected_page(),
                else => {},
            },
            .enter => try self.open_selected(),
            .down => self.move_selection(1),
            .up => self.move_selection(-1),
            .home => self.select_first(),
            .end => self.select_last(),
            .control => |byte| switch (byte) {
                'c' => return false,
                'd' => self.move_page(1),
                'u' => self.move_page(-1),
                else => {},
            },
            else => {},
        }
        return true;
    }

    fn handle_focus_search(self: *Application, key: layout.input.Key) !bool {
        switch (key) {
            .escape => {
                self.search.clear();
                self.focus_search_open = false;
                self.refresh_filter();
                try self.set_message("Focus search cleared");
                return true;
            },
            .enter => {
                self.focus_search_open = false;
                try self.set_message("Focus filter applied");
                return true;
            },
            .tab, .right => {
                self.cycle_scope(1);
                return true;
            },
            .shift_tab, .left => {
                self.cycle_scope(-1);
                return true;
            },
            .up => {
                self.move_selection(-1);
                return true;
            },
            .down => {
                self.move_selection(1);
                return true;
            },
            .control => |byte| {
                if (byte == 'p' or byte == 'k') {
                    self.move_selection(-1);
                    return true;
                }
                if (byte == 'n') {
                    self.move_selection(1);
                    return true;
                }
                if (byte == 'c') return false;
            },
            else => {},
        }
        const action = try self.search.handle(key);
        if (action == .changed) self.refresh_filter();
        return true;
    }

    fn handle_command(self: *Application, key: layout.input.Key) !bool {
        switch (key) {
            .escape => {
                self.close_command();
                return true;
            },
            .enter => {
                try self.activate_command_result();
                return true;
            },
            .up, .shift_tab => {
                self.move_command_selection(-1);
                return true;
            },
            .down, .tab => {
                self.move_command_selection(1);
                return true;
            },
            .control => |byte| {
                if (byte == 'k' or byte == 'p') {
                    self.move_command_selection(-1);
                    return true;
                }
                if (byte == 'j' or byte == 'n') {
                    self.move_command_selection(1);
                    return true;
                }
            },
            else => {},
        }
        const action = try self.command.handle(key);
        if (action == .changed) self.refresh_command_results();
        return true;
    }

    fn handle_search(self: *Application, key: layout.input.Key) !bool {
        if (key == .escape) {
            self.search.clear();
            self.refresh_filter();
            self.mode = .browse;
            try self.set_message("Search cleared");
            return true;
        }
        const action = try self.search.handle(key);
        switch (action) {
            .changed => self.refresh_filter(),
            .submitted => {
                self.mode = .browse;
                try self.set_message("Filter applied");
            },
            else => {},
        }
        return true;
    }

    fn handle_add(self: *Application, key: layout.input.Key) !bool {
        if (key == .escape) {
            self.mode = .browse;
            try self.set_message("Add cancelled");
            return true;
        }
        if (key == .tab) {
            self.next_field();
            return true;
        }
        if (key == .shift_tab) {
            self.previous_field();
            return true;
        }
        if (key == .enter and self.field == .notes) {
            try self.submit_add();
            return true;
        }
        const action = try self.active_input_handle(key);
        if (action == .submitted) self.next_field();
        return true;
    }

    fn handle_delete_confirmation(
        self: *Application,
        key: layout.input.Key,
    ) !bool {
        if (key == .escape) {
            self.mode = .browse;
            try self.set_message("Delete cancelled");
            return true;
        }
        if (key == .character and key.character == 'd') {
            try self.delete_selected();
        }
        return true;
    }

    fn active_input_handle(
        self: *Application,
        key: layout.input.Key,
    ) !terminal.widgets.TextInputAction {
        return switch (self.field) {
            .title => self.title.handle(key),
            .url => self.url.handle(key),
            .tags => self.tags.handle(key),
            .notes => self.notes.handle(key),
        };
    }

    fn begin_add(self: *Application) void {
        self.title.clear();
        self.url.clear();
        self.tags.clear();
        self.notes.clear();
        self.field = .url;
        self.mode = .add;
    }

    fn begin_command(self: *Application) void {
        self.command.clear();
        self.command_selected = 0;
        self.command_scroll = 0;
        self.mode = .command;
        self.refresh_command_results();
    }

    fn begin_focus(self: *Application) !void {
        self.mode = .focus;
        self.browser_focus = .bookmarks;
        self.focus_search_open = false;
        self.refresh_filter();
        try self.set_message("Focus mode");
    }

    fn leave_focus(self: *Application) !void {
        self.focus_search_open = false;
        self.mode = .browse;
        self.refresh_filter();
        try self.set_message("Workspace restored");
    }

    fn begin_focus_search(self: *Application) !void {
        self.focus_search_open = true;
        try self.set_message("Search and cycle categories");
    }

    fn close_command(self: *Application) void {
        self.command.clear();
        self.command_result_count = 0;
        self.command_selected = 0;
        self.command_scroll = 0;
        self.mode = .browse;
    }

    fn submit_add(self: *Application) !void {
        const bookmark = bookmarks.Bookmark.init(
            self.title.value(),
            self.url.value(),
            self.tags.value(),
            self.notes.value(),
        ) catch |err| {
            try self.set_message(@errorName(err));
            return;
        };
        const store_index = self.store.count;
        self.store.add(bookmark) catch |err| {
            try self.set_message(@errorName(err));
            return;
        };
        try self.persistence.save(self.io, &self.store);
        self.rebuild_tags();
        self.search.clear();
        self.refresh_filter();
        self.select_last();
        self.mode = .browse;
        try self.set_message("Bookmark added");
        if (page_url(bookmark.url.bytes())) {
            try self.begin_page_fetch(store_index);
        }
    }

    fn open_selected(self: *Application) !void {
        const bookmark = self.selected_bookmark() orelse {
            try self.set_message("Nothing selected");
            return;
        };
        try bookmarks.browser.open(self.io, bookmark.url.bytes());
        bookmark.open_count +|= 1;
        try self.persistence.save(self.io, &self.store);
        try self.set_message("Opened in browser");
    }

    fn toggle_favorite(self: *Application) !void {
        const bookmark = self.selected_bookmark() orelse return;
        bookmark.favorite = !bookmark.favorite;
        try self.persistence.save(self.io, &self.store);
        if (self.scope_kind == .favorites and !bookmark.favorite) self.refresh_filter();
        try self.set_message(if (bookmark.favorite) "Favorited" else "Favorite removed");
    }

    fn refresh_selected_page(self: *Application) !void {
        if (self.selected >= self.filtered_count) return;
        try self.begin_page_fetch(self.filtered[self.selected]);
    }

    fn begin_page_fetch(self: *Application, store_index: u16) !void {
        if (self.page_fetch_in_progress) {
            try self.set_message("A page refresh is already running");
            return;
        }
        const bookmark = self.store.get(store_index) orelse return;
        if (!page_url(bookmark.url.bytes())) {
            try self.set_message("Page previews require an HTTP or HTTPS URL");
            return;
        }
        const request = PageRequest{
            .store_index = store_index,
            .url = PageUrl.init(bookmark.url.bytes()) catch unreachable,
        };
        self.page_tasks.concurrent(
            self.io,
            page_fetch_task,
            .{ self.io, &self.page_fetcher, &self.page_results, request },
        ) catch |err| {
            try self.set_message(@errorName(err));
            return;
        };
        self.page_fetch_in_progress = true;
        try self.set_message("Refreshing page title and content...");
    }

    fn apply_page_result(self: *Application, result: PageResult) !void {
        const bookmark = self.store.get(result.request.store_index) orelse {
            try self.set_message("Refresh discarded: bookmark was removed");
            return;
        };
        if (!std.mem.eql(u8, bookmark.url.bytes(), result.request.url.bytes())) {
            try self.set_message("Refresh discarded: bookmark changed");
            return;
        }
        switch (result.outcome) {
            .failure => |err| try self.set_message(@errorName(err)),
            .metadata => |metadata| {
                bookmark.apply_metadata(&metadata);
                // Rewrites bookmark text in place, which mounted rows point at.
                self.dom_view.invalidate();
                try self.persistence.save(self.io, &self.store);
                self.refresh_filter();
                try self.set_message("Page title and content refreshed");
            },
        }
    }

    fn begin_delete(self: *Application) !void {
        if (self.selected_bookmark() == null) return;
        self.mode = .confirm_delete;
        try self.set_message("Press d again to delete, Esc to cancel");
    }

    pub fn set_command_viewport_rows(self: *Application, rows: u16) void {
        self.command_viewport_rows = @max(rows, 1);
        self.ensure_command_visible();
    }

    /// What a result reads as. The view asks rather than reaching into the
    /// store itself: a result is an index into collections only the
    /// application knows the bounds of.
    pub fn command_result_title(self: *Application, result: CommandResult) []const u8 {
        return switch (result) {
            .action => |action| command_action_label(action),
            .bookmark => |index| if (index < self.store.count)
                self.store.items[index].title.bytes()
            else
                "Unavailable bookmark",
            .tag => |index| if (index < self.tag_count)
                self.tags_available[index].bytes()
            else
                "Unavailable tag",
        };
    }

    pub fn command_result_detail(self: *Application, result: CommandResult) []const u8 {
        return switch (result) {
            .action => |action| command_action_detail(action),
            .bookmark => |index| if (index < self.store.count)
                self.store.items[index].host()
            else
                "",
            .tag => "Open this tag as a focused collection",
        };
    }

    fn refresh_command_results(self: *Application) void {
        self.command_result_count = 0;
        const query = self.command.value();
        const actions = std.enums.values(CommandAction);
        for (actions) |action| {
            if (layout.fuzzy.matches(command_action_label(action), query)) {
                self.append_command_result(.{ .action = action });
            }
        }
        var bookmark_index: u16 = 0;
        while (bookmark_index < self.store.count) : (bookmark_index += 1) {
            const bookmark = &self.store.items[bookmark_index];
            if (bookmark_matches_command(bookmark, query)) {
                self.append_command_result(.{ .bookmark = bookmark_index });
            }
        }
        var tag_index: u16 = 0;
        while (tag_index < self.tag_count) : (tag_index += 1) {
            if (layout.fuzzy.matches(self.tags_available[tag_index].bytes(), query)) {
                self.append_command_result(.{ .tag = tag_index });
            }
        }
        if (self.command_result_count == 0) {
            self.command_selected = 0;
            self.command_scroll = 0;
        } else if (self.command_selected >= self.command_result_count) {
            self.command_selected = self.command_result_count - 1;
        }
        self.ensure_command_visible();
    }

    fn append_command_result(self: *Application, result: CommandResult) void {
        std.debug.assert(self.command_result_count < limits.command_result_count_max);
        self.command_results[self.command_result_count] = result;
        self.command_result_count += 1;
    }

    fn move_command_selection(self: *Application, delta: i16) void {
        if (self.command_result_count == 0) return;
        const next = @as(i32, self.command_selected) + delta;
        self.command_selected = @intCast(std.math.clamp(
            next,
            0,
            @as(i32, self.command_result_count) - 1,
        ));
        self.ensure_command_visible();
    }

    fn ensure_command_visible(self: *Application) void {
        if (self.command_selected < self.command_scroll) {
            self.command_scroll = self.command_selected;
        }
        const visible_end = @as(u32, self.command_scroll) + self.command_viewport_rows;
        if (self.command_selected >= visible_end) {
            self.command_scroll =
                self.command_selected - self.command_viewport_rows + 1;
        }
    }

    fn activate_command_result(self: *Application) !void {
        if (self.command_selected >= self.command_result_count) return;
        const result = self.command_results[self.command_selected];
        self.close_command();
        switch (result) {
            .action => |action| try self.activate_command_action(action),
            .bookmark => |store_index| try self.select_command_bookmark(store_index),
            .tag => |tag_index| {
                if (tag_index >= self.tag_count) return;
                const tag = self.tags_available[tag_index];
                self.search.clear();
                self.select_scope(.tag, tag.bytes());
                self.browser_focus = .bookmarks;
                try self.set_message("Tag view selected");
            },
        }
    }

    fn activate_command_action(
        self: *Application,
        action: CommandAction,
    ) !void {
        switch (action) {
            .add => self.begin_add(),
            .open => try self.open_selected(),
            .toggle_favorite => try self.toggle_favorite(),
            .refresh => try self.refresh_selected_page(),
            .browse_all => {
                self.search.clear();
                self.select_scope(.all, "");
                try self.set_message("Showing all bookmarks");
            },
            .browse_favorites => {
                self.search.clear();
                self.select_scope(.favorites, "");
                try self.set_message("Showing favorites");
            },
        }
    }

    fn select_command_bookmark(
        self: *Application,
        store_index: u16,
    ) !void {
        self.search.clear();
        self.select_scope(.all, "");
        var filtered_index: u16 = 0;
        while (filtered_index < self.filtered_count) : (filtered_index += 1) {
            if (self.filtered[filtered_index] != store_index) continue;
            self.selected = filtered_index;
            self.browser_focus = .bookmarks;
            self.ensure_visible();
            try self.set_message("Bookmark selected");
            return;
        }
        try self.set_message("Bookmark is no longer available");
    }

    fn delete_selected(self: *Application) !void {
        if (self.selected >= self.filtered_count) return;
        try self.store.remove(self.filtered[self.selected]);
        try self.persistence.save(self.io, &self.store);
        self.rebuild_tags();
        self.refresh_filter();
        self.mode = .browse;
        try self.set_message("Bookmark deleted");
    }

    fn refresh_filter(self: *Application) void {
        self.filtered_count = 0;
        var index: u16 = 0;
        while (index < self.store.count) : (index += 1) {
            const bookmark = &self.store.items[index];
            const query_matches = if (self.mode == .focus)
                bookmark_matches_command(bookmark, self.search.value())
            else
                bookmark.matches(self.search.value());
            if (!query_matches) continue;
            if (!self.scope_matches(bookmark)) continue;
            self.filtered[self.filtered_count] = index;
            self.filtered_count += 1;
        }
        if (self.filtered_count == 0) {
            self.selected = 0;
            self.scroll = 0;
        } else if (self.selected >= self.filtered_count) {
            self.selected = self.filtered_count - 1;
        }
        self.ensure_visible();
        self.preview_scroll = 0;
    }

    fn scope_matches(self: *const Application, bookmark: *const bookmarks.Bookmark) bool {
        return switch (self.scope_kind) {
            .all => true,
            .favorites => bookmark.favorite,
            .tag => bookmark.has_tag(self.active_tag.bytes()),
        };
    }

    pub fn rebuild_tags(self: *Application) void {
        self.tag_count = 0;
        var bookmark_index: u16 = 0;
        while (bookmark_index < self.store.count) : (bookmark_index += 1) {
            var tags = std.mem.splitScalar(
                u8,
                self.store.items[bookmark_index].tags.bytes(),
                ',',
            );
            while (tags.next()) |raw_tag| self.add_available_tag(raw_tag);
        }
        if (self.scope_kind == .tag and !self.tag_exists(self.active_tag.bytes())) {
            self.select_scope(.all, "");
        }
    }

    fn add_available_tag(self: *Application, raw_tag: []const u8) void {
        const tag = std.mem.trim(u8, raw_tag, " \t");
        if (tag.len == 0 or tag.len > limits.tag_name_bytes_max) return;
        if (self.tag_exists(tag)) return;
        if (self.tag_count >= limits.tag_count_max) return;
        self.tags_available[self.tag_count] = Tag.init(tag) catch unreachable;
        self.tag_count += 1;
    }

    fn tag_exists(self: *const Application, tag: []const u8) bool {
        var index: u16 = 0;
        while (index < self.tag_count) : (index += 1) {
            if (std.ascii.eqlIgnoreCase(self.tags_available[index].bytes(), tag)) return true;
        }
        return false;
    }

    fn select_scope(self: *Application, kind: ScopeKind, tag: []const u8) void {
        self.scope_kind = kind;
        if (kind == .tag) {
            self.active_tag.set(tag) catch unreachable;
            var index: u16 = 0;
            while (index < self.tag_count) : (index += 1) {
                if (std.ascii.eqlIgnoreCase(self.tags_available[index].bytes(), tag)) {
                    self.scope_cursor = index + 2;
                    break;
                }
            }
        } else {
            self.active_tag.clear();
            self.scope_cursor = if (kind == .all) 0 else 1;
        }
        self.selected = 0;
        self.scroll = 0;
        self.refresh_filter();
        self.ensure_scope_visible();
    }

    fn move_focused(self: *Application, delta: i16) void {
        switch (self.browser_focus) {
            .scopes => self.move_scope(delta),
            .bookmarks => self.move_selection(delta),
            .preview => self.move_preview(delta),
        }
    }

    fn move_scope(self: *Application, delta: i16) void {
        const scope_count = @as(i32, self.tag_count) + 2;
        const next = @as(i32, self.scope_cursor) + delta;
        self.scope_cursor = @intCast(std.math.clamp(next, 0, scope_count - 1));
        self.apply_scope_cursor();
        self.ensure_scope_visible();
    }

    fn cycle_scope(self: *Application, delta: i16) void {
        std.debug.assert(delta == -1 or delta == 1);
        const scope_count = @as(i32, self.tag_count) + 2;
        var next = @as(i32, self.scope_cursor) + delta;
        if (next < 0) next = scope_count - 1;
        if (next >= scope_count) next = 0;
        self.scope_cursor = @intCast(next);
        self.apply_scope_cursor();
        self.ensure_scope_visible();
    }

    fn apply_scope_cursor(self: *Application) void {
        if (self.scope_cursor == 0) return self.select_scope(.all, "");
        if (self.scope_cursor == 1) return self.select_scope(.favorites, "");
        const tag_index = self.scope_cursor - 2;
        if (tag_index < self.tag_count) {
            self.select_scope(.tag, self.tags_available[tag_index].bytes());
        }
    }

    fn move_preview(self: *Application, delta: i16) void {
        const maximum = self.preview_line_count -| self.preview_viewport_rows;
        if (delta < 0) {
            self.preview_scroll -|= @intCast(-delta);
        } else {
            self.preview_scroll = @min(
                self.preview_scroll +| @as(u16, @intCast(delta)),
                maximum,
            );
        }
    }

    fn activate_focused(self: *Application) !void {
        switch (self.browser_focus) {
            .scopes => self.apply_scope_cursor(),
            .bookmarks => try self.open_selected(),
            .preview => self.preview_scroll +|= 1,
        }
    }

    fn focus_left(self: *Application) void {
        self.browser_focus = switch (self.browser_focus) {
            .scopes => .scopes,
            .bookmarks => .scopes,
            .preview => .bookmarks,
        };
    }

    fn focus_right(self: *Application) void {
        self.browser_focus = switch (self.browser_focus) {
            .scopes => .bookmarks,
            .bookmarks => .preview,
            .preview => .preview,
        };
    }

    fn cycle_focus(self: *Application) void {
        self.browser_focus = switch (self.browser_focus) {
            .scopes => .bookmarks,
            .bookmarks => .preview,
            .preview => .scopes,
        };
    }

    fn ensure_scope_visible(self: *Application) void {
        if (self.scope_cursor < self.scope_scroll) self.scope_scroll = self.scope_cursor;
        const visible_end = @as(u32, self.scope_scroll) + self.scope_viewport_rows;
        if (self.scope_cursor >= visible_end) {
            self.scope_scroll = self.scope_cursor - self.scope_viewport_rows + 1;
        }
    }

    fn move_selection(self: *Application, delta: i16) void {
        if (self.filtered_count == 0) return;
        const next = @as(i32, self.selected) + delta;
        self.selected = @intCast(std.math.clamp(
            next,
            0,
            @as(i32, self.filtered_count) - 1,
        ));
        self.ensure_visible();
    }

    fn move_page(self: *Application, direction: i16) void {
        const page_size: i16 = @intCast(@min(self.viewport_rows, std.math.maxInt(i16)));
        self.move_selection(direction * @max(page_size - 1, 1));
    }

    fn select_first(self: *Application) void {
        self.selected = 0;
        self.ensure_visible();
    }

    fn select_last(self: *Application) void {
        if (self.filtered_count > 0) self.selected = self.filtered_count - 1;
        self.ensure_visible();
    }

    fn ensure_visible(self: *Application) void {
        if (self.selected < self.scroll) self.scroll = self.selected;
        const visible_end = @as(u32, self.scroll) + self.viewport_rows;
        if (self.selected >= visible_end) {
            self.scroll = self.selected - self.viewport_rows + 1;
        }
    }

    fn next_field(self: *Application) void {
        self.field = switch (self.field) {
            .title => .url,
            .url => .tags,
            .tags => .notes,
            .notes => .title,
        };
    }

    fn previous_field(self: *Application) void {
        self.field = switch (self.field) {
            .title => .notes,
            .url => .title,
            .tags => .url,
            .notes => .tags,
        };
    }

    fn set_message(self: *Application, value: []const u8) !void {
        try self.message.set(value);
    }
};

fn page_url(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://") or
        std.mem.startsWith(u8, url, "https://");
}

fn list_index(
    region: MouseListRegion,
    x: u16,
    y: u16,
) ?u16 {
    std.debug.assert(region.row_height > 0);
    if (!contains(region.rect, x, y)) return null;
    const visible_index = @divFloor(y - region.rect.y, region.row_height);
    return std.math.add(u16, region.scroll, visible_index) catch null;
}

fn region_contains(
    region: ?MouseListRegion,
    x: u16,
    y: u16,
) bool {
    const value = region orelse return false;
    return contains(value.rect, x, y);
}

fn contains_optional(rect: ?Rect, x: u16, y: u16) bool {
    const value = rect orelse return false;
    return contains(value, x, y);
}

fn contains(rect: Rect, x: u16, y: u16) bool {
    if (x < rect.x or y < rect.y) return false;
    if (x >= rect.right()) return false;
    return y < rect.y + rect.height;
}

fn page_fetch_task(
    io: std.Io,
    fetcher: *page.Fetcher,
    results: *PageResultQueue,
    request: PageRequest,
) std.Io.Cancelable!void {
    const outcome: PageOutcome = if (fetcher.fetch(request.url.bytes())) |metadata|
        .{ .metadata = metadata }
    else |err|
        .{ .failure = err };
    results.putOne(io, .{
        .request = request,
        .outcome = outcome,
    }) catch |err| switch (err) {
        error.Closed => return,
        error.Canceled => return error.Canceled,
    };
}

pub fn command_action_label(action: CommandAction) []const u8 {
    return switch (action) {
        .add => "Add bookmark",
        .open => "Open selected bookmark",
        .toggle_favorite => "Toggle favorite",
        .refresh => "Refresh page preview",
        .browse_all => "Browse all bookmarks",
        .browse_favorites => "Browse favorites",
    };
}

pub fn command_action_detail(action: CommandAction) []const u8 {
    return switch (action) {
        .add => "Create a saved link",
        .open => "Launch in the default browser",
        .toggle_favorite => "Add or remove the star",
        .refresh => "Fetch title, summary, and content",
        .browse_all => "Reset search and tag filters",
        .browse_favorites => "Show starred links only",
    };
}

fn bookmark_matches_command(
    bookmark: *const bookmarks.Bookmark,
    query: []const u8,
) bool {
    if (layout.fuzzy.matches(bookmark.title.bytes(), query)) return true;
    if (layout.fuzzy.matches(bookmark.url.bytes(), query)) return true;
    if (layout.fuzzy.matches(bookmark.tags.bytes(), query)) return true;
    if (layout.fuzzy.matches(bookmark.notes.bytes(), query)) return true;
    if (layout.fuzzy.matches(bookmark.description.bytes(), query)) return true;
    return layout.fuzzy.matches(bookmark.preview.bytes(), query);
}

test "application supports vim navigation and live search" {
    const application = try Application.create(
        std.testing.allocator,
        std.testing.io,
        &@import("data").paths.testing_paths,
    );
    defer application.destroy(std.testing.allocator);
    try application.store.add(try bookmarks.Bookmark.init("One", "https://one.test", "", ""));
    try application.store.add(try bookmarks.Bookmark.init("Two", "https://two.test", "", ""));
    application.refresh_filter();
    try std.testing.expect(try application.handle_key(.{ .character = 'j' }));
    try std.testing.expectEqual(@as(u16, 1), application.selected);
    try std.testing.expect(try application.handle_key(.{ .character = '/' }));
    try std.testing.expect(try application.handle_key(.{ .character = 'T' }));
    try std.testing.expect(try application.handle_key(.{ .character = 'w' }));
    try std.testing.expectEqual(@as(u16, 1), application.filtered_count);
}

test "application browses favorites and exact tags" {
    const application = try Application.create(
        std.testing.allocator,
        std.testing.io,
        &@import("data").paths.testing_paths,
    );
    defer application.destroy(std.testing.allocator);
    var zig = try bookmarks.Bookmark.init("Zig", "https://ziglang.org", "code, systems", "");
    zig.favorite = true;
    try application.store.add(zig);
    try application.store.add(
        try bookmarks.Bookmark.init("Docs", "https://example.com", "reading", ""),
    );
    application.rebuild_tags();

    application.select_scope(.favorites, "");
    try std.testing.expectEqual(@as(u16, 1), application.filtered_count);
    application.select_scope(.tag, "systems");
    try std.testing.expectEqual(@as(u16, 1), application.filtered_count);
    try std.testing.expectEqualStrings(
        "Zig",
        application.selected_bookmark().?.title.bytes(),
    );
}

test "command deck fuzzy filters and selects a bookmark" {
    const application = try Application.create(
        std.testing.allocator,
        std.testing.io,
        &@import("data").paths.testing_paths,
    );
    defer application.destroy(std.testing.allocator);
    try application.store.add(
        try bookmarks.Bookmark.init("Other", "https://other.test", "", ""),
    );
    try application.store.add(
        try bookmarks.Bookmark.init("Tiger Style", "https://tiger.test", "systems", ""),
    );
    application.rebuild_tags();
    application.refresh_filter();

    _ = try application.handle_key(.{ .character = ':' });
    _ = try application.handle_key(.{ .character = 't' });
    _ = try application.handle_key(.{ .character = 'g' });
    _ = try application.handle_key(.{ .character = 's' });
    try std.testing.expectEqual(Mode.command, application.mode);
    try std.testing.expectEqual(@as(u16, 1), application.command_result_count);
    _ = try application.handle_key(.enter);
    try std.testing.expectEqual(Mode.browse, application.mode);
    try std.testing.expectEqualStrings(
        "Tiger Style",
        application.selected_bookmark().?.title.bytes(),
    );
}

test "focus mode fuzzy searches and cycles categories" {
    const application = try Application.create(
        std.testing.allocator,
        std.testing.io,
        &@import("data").paths.testing_paths,
    );
    defer application.destroy(std.testing.allocator);
    var tiger = try bookmarks.Bookmark.init(
        "Tiger Style",
        "https://tiger.test",
        "systems",
        "",
    );
    tiger.favorite = true;
    try application.store.add(tiger);
    try application.store.add(
        try bookmarks.Bookmark.init("Other", "https://other.test", "", ""),
    );
    application.rebuild_tags();
    application.refresh_filter();

    _ = try application.handle_key(.{ .character = 'z' });
    _ = try application.handle_key(.{ .character = '/' });
    _ = try application.handle_key(.{ .character = 't' });
    _ = try application.handle_key(.{ .character = 'g' });
    _ = try application.handle_key(.{ .character = 's' });
    try std.testing.expectEqual(Mode.focus, application.mode);
    try std.testing.expect(application.focus_search_open);
    try std.testing.expectEqual(@as(u16, 1), application.filtered_count);
    _ = try application.handle_key(.escape);
    try std.testing.expect(!application.focus_search_open);
    try std.testing.expectEqual(@as(u16, 2), application.filtered_count);

    _ = try application.handle_key(.{ .character = '/' });
    _ = try application.handle_key(.tab);
    try std.testing.expectEqual(ScopeKind.favorites, application.scope_kind);
    try std.testing.expectEqual(@as(u16, 1), application.filtered_count);
    _ = try application.handle_key(.enter);
    try std.testing.expect(!application.focus_search_open);
}

test "mouse clicks and wheels target registered list geometry" {
    const application = try Application.create(
        std.testing.allocator,
        std.testing.io,
        &@import("data").paths.testing_paths,
    );
    defer application.destroy(std.testing.allocator);
    try application.store.add(
        try bookmarks.Bookmark.init("One", "https://one.test", "", ""),
    );
    try application.store.add(
        try bookmarks.Bookmark.init("Two", "https://two.test", "", ""),
    );
    try application.store.add(
        try bookmarks.Bookmark.init("Three", "https://three.test", "", ""),
    );
    application.refresh_filter();
    application.mouse_layout.bookmarks = .{
        .rect = Rect.init(10, 4, 30, 6),
        .scroll = 0,
        .row_height = 2,
    };
    _ = try application.handle_key(.{ .pointer = .{
        .x = 12,
        .y = 6,
        .action = .press,
        .button = .primary,
    } });
    try std.testing.expectEqual(@as(u16, 1), application.selected);
    _ = try application.handle_key(.{ .pointer = .{
        .x = 12,
        .y = 6,
        .action = .press,
        .button = .wheel_down,
    } });
    try std.testing.expectEqual(@as(u16, 2), application.selected);
}

test "mouse selects telescope categories results and form fields" {
    const application = try Application.create(
        std.testing.allocator,
        std.testing.io,
        &@import("data").paths.testing_paths,
    );
    defer application.destroy(std.testing.allocator);
    var favorite = try bookmarks.Bookmark.init("One", "https://one.test", "", "");
    favorite.favorite = true;
    try application.store.add(favorite);
    try application.store.add(
        try bookmarks.Bookmark.init("Two", "https://two.test", "", ""),
    );
    application.refresh_filter();
    application.mode = .focus;
    application.focus_search_open = true;
    application.mouse_layout.focus_modal = Rect.init(10, 4, 40, 12);
    application.mouse_layout.finder_results = .{
        .rect = Rect.init(12, 9, 36, 6),
        .scroll = 0,
        .row_height = 2,
    };
    application.mouse_layout.categories[0] = .{
        .rect = Rect.init(12, 7, 10, 1),
        .scope_index = 1,
    };
    application.mouse_layout.category_count = 1;
    _ = try application.handle_key(.{ .pointer = .{
        .x = 14,
        .y = 11,
        .action = .press,
        .button = .primary,
    } });
    try std.testing.expectEqual(@as(u16, 1), application.selected);
    _ = try application.handle_key(.{ .pointer = .{
        .x = 14,
        .y = 7,
        .action = .press,
        .button = .primary,
    } });
    try std.testing.expectEqual(ScopeKind.favorites, application.scope_kind);

    application.mode = .add;
    application.mouse_layout = .{};
    application.mouse_layout.fields[0] = .{
        .rect = Rect.init(20, 5, 30, 1),
        .field = .tags,
    };
    application.mouse_layout.field_count = 1;
    _ = try application.handle_key(.{ .pointer = .{
        .x = 25,
        .y = 5,
        .action = .press,
        .button = .primary,
    } });
    try std.testing.expectEqual(Field.tags, application.field);
}
