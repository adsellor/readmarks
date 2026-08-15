const application_module = @import("application.zig");

const Application = application_module.Application;

pub const Index = u8;

pub const Argument = struct {
    placeholder: []const u8,
    live: bool = false,
};

pub const arguments_max = 2;

pub const Action = struct {
    label: []const u8,
    detail: []const u8,
    arguments: []const Argument = &.{},
    begin: ?*const fn (*Application) anyerror!void = null,
    run: *const fn (*Application, []const []const u8) anyerror!void,
};

pub const search: Index = 0;
pub const add: Index = 1;

pub const table = [_]Action{
    .{
        .label = "Search bookmarks",
        .detail = "Narrow the library as you type",
        .arguments = &.{.{
            .placeholder = "title, URL, tag, note, or page text",
            .live = true,
        }},
        .run = run_search,
    },
    .{
        .label = "Add bookmark",
        .detail = "Save a link and fetch its page",
        .arguments = &.{
            .{ .placeholder = "https://example.com" },
            .{ .placeholder = "tags, comma separated (optional)" },
        },
        .run = run_add,
    },
    .{
        .label = "Add bookmark with details",
        .detail = "Set the title, tags and note yourself",
        .run = run_add_detailed,
    },
    .{
        .label = "Open selected bookmark",
        .detail = "Launch in the default browser",
        .run = run_open,
    },
    .{
        .label = "Toggle favourite",
        .detail = "Add or remove the star",
        .run = run_toggle_favorite,
    },
    .{
        .label = "Refresh page preview",
        .detail = "Fetch title, summary, and content",
        .run = run_refresh,
    },
    .{
        .label = "Delete selected bookmark",
        .detail = "Remove it from the library",
        .run = run_delete,
    },
    .{
        .label = "Browse all bookmarks",
        .detail = "Reset search and tag filters",
        .run = run_browse_all,
    },
    .{
        .label = "Browse favourites",
        .detail = "Show starred links only",
        .run = run_browse_favorites,
    },
};

pub fn label(index: Index) []const u8 {
    return if (index < table.len) table[index].label else "";
}

pub fn detail(index: Index) []const u8 {
    return if (index < table.len) table[index].detail else "";
}

pub fn arguments(index: Index) []const Argument {
    return if (index < table.len) table[index].arguments else &.{};
}

fn run_search(self: *Application, values: []const []const u8) !void {
    try self.search.set(values[0]);
    self.refresh_filter();
}

fn run_add(self: *Application, values: []const []const u8) !void {
    if (values[0].len == 0) {
        try self.set_message("Add cancelled");
        return;
    }
    try self.url.set(values[0]);
    self.title.clear();
    try self.tags.set(if (values.len > 1) values[1] else "");
    self.notes.clear();
    try self.submit_add();
}

fn run_add_detailed(self: *Application, _: []const []const u8) !void {
    self.begin_add();
}

fn run_open(self: *Application, _: []const []const u8) !void {
    try self.open_selected();
}

fn run_toggle_favorite(self: *Application, _: []const []const u8) !void {
    try self.toggle_favorite();
}

fn run_refresh(self: *Application, _: []const []const u8) !void {
    try self.refresh_selected_page();
}

fn run_delete(self: *Application, _: []const []const u8) !void {
    try self.delete_selected();
}

fn run_browse_all(self: *Application, _: []const []const u8) !void {
    self.search.clear();
    self.select_scope(.all, "");
    try self.set_message("Showing all bookmarks");
}

fn run_browse_favorites(self: *Application, _: []const []const u8) !void {
    self.search.clear();
    self.select_scope(.favorites, "");
    try self.set_message("Showing favourites");
}
