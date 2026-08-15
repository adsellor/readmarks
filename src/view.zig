const std = @import("std");
const terminal = @import("markix").terminal;
const Application = @import("application.zig").Application;

const reader_view = @import("reader/view.zig");
const bookmarker_view = @import("bookmarker/view.zig");

pub fn render(application: *Application, canvas: *terminal.TerminalCanvas) !void {
    switch (application.experience) {
        .reader => try reader_view.render(application.reader, canvas),
        .bookmarker => try bookmarker_view.render(application.bookmarker, canvas),
    }
}
