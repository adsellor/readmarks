const Application = @import("application.zig").Application;
const Display = @import("ui/display.zig").Display;

const reader_view = @import("reader/view.zig");
const bookmarker_view = @import("bookmarker/view.zig");

pub fn render(application: *Application, display: *Display) !void {
    switch (application.experience) {
        .reader => try reader_view.render(application.reader, display),
        .bookmarker => try bookmarker_view.render(application.bookmarker, display),
    }
}
