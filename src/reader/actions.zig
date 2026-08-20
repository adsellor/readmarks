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
pub const add_feed: Index = 1;

pub const table = [_]Action{
    .{
        .label = "Search articles",
        .detail = "Narrow the list as you type",
        .arguments = &.{.{
            .placeholder = "article, feed, URL, or summary",
            .live = true,
        }},
        .begin = begin_search,
        .run = run_search,
    },
    .{
        .label = "Add a feed",
        .detail = "Subscribe to a new feed",
        .arguments = &.{
            .{ .placeholder = "https://example.com/feed.xml" },
            .{ .placeholder = "category (blank for Unsorted)" },
        },
        .run = run_add_feed,
    },
    .{
        .label = "Open article in browser",
        .detail = "Launch in the default browser",
        .run = run_open,
    },
    .{
        .label = "Read article here",
        .detail = "Open the full-screen reader",
        .run = run_read,
    },
    .{
        .label = "Save article to bookmarks",
        .detail = "Keep it in the bookmark library",
        .run = run_bookmark,
    },
    .{
        .label = "Toggle read",
        .detail = "Mark the selection read or unread",
        .run = run_toggle_read,
    },
    .{
        .label = "Mark everything shown as read",
        .detail = "Clear the unread count for this view",
        .run = run_mark_shown_read,
    },
    .{
        .label = "Refresh this feed",
        .detail = "Fetch the focused feed",
        .run = run_refresh_feed,
    },
    .{
        .label = "Refresh every feed",
        .detail = "Fetch every subscription",
        .run = run_refresh_all,
    },
    .{
        .label = "Prune unreachable feeds",
        .detail = "Drop failed feeds that have no articles",
        .run = run_prune,
    },
    .{
        .label = "Browse all articles",
        .detail = "Reset the scope",
        .run = run_browse_all,
    },
    .{
        .label = "Browse unread",
        .detail = "Show what is still unread",
        .run = run_browse_unread,
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

fn begin_search(self: *Application) !void {
    self.search_scope = Application.search_target(self.focus);
}

fn run_search(self: *Application, values: []const []const u8) !void {
    try self.applied_search.set(values[0]);
    self.refresh_lists();
}

fn run_add_feed(self: *Application, values: []const []const u8) !void {
    if (values[0].len == 0) {
        try self.set_message("Feed add cancelled");
        return;
    }
    try self.feed_url_input.set(values[0]);
    try self.feed_category_input.set(if (values.len > 1) values[1] else "");
    try self.commit_add_feed();
}

fn run_open(self: *Application, _: []const []const u8) !void {
    try self.open_selected();
}

fn run_read(self: *Application, _: []const []const u8) !void {
    try self.read_selected();
}

fn run_bookmark(self: *Application, _: []const []const u8) !void {
    try self.bookmark_selected();
}

fn run_toggle_read(self: *Application, _: []const []const u8) !void {
    try self.toggle_read();
}

fn run_mark_shown_read(self: *Application, _: []const []const u8) !void {
    try self.mark_shown_read();
}

fn run_refresh_feed(self: *Application, _: []const []const u8) !void {
    try self.start_refresh_selected();
}

fn run_refresh_all(self: *Application, _: []const []const u8) !void {
    try self.start_refresh_all();
}

fn run_prune(self: *Application, _: []const []const u8) !void {
    try self.begin_prune_feeds();
}

fn run_browse_all(self: *Application, _: []const []const u8) !void {
    self.select_scope(.all, "");
    try self.set_message("Showing all articles");
}

fn run_browse_unread(self: *Application, _: []const []const u8) !void {
    self.select_scope(.unread, "");
    try self.set_message("Showing unread");
}
