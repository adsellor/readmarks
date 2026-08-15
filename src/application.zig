const std = @import("std");
const layout = @import("markix").layout;
const Paths = @import("data").Paths;

const reader_app = @import("reader/application.zig");
const bookmarker_app = @import("bookmarker/application.zig");

pub const Experience = enum { reader, bookmarker };

pub const Application = struct {
    io: std.Io,
    reader: *reader_app.Application,
    bookmarker: *bookmarker_app.Application,
    experience: Experience = .reader,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        paths: *const Paths,
    ) !*Application {
        const application = try allocator.create(Application);
        errdefer allocator.destroy(application);
        application.io = io;
        application.experience = .reader;
        application.reader = try reader_app.Application.create(allocator, io, paths);
        errdefer application.reader.destroy(allocator);
        application.bookmarker = try bookmarker_app.Application.create(
            allocator,
            io,
            paths,
        );
        errdefer application.bookmarker.destroy(allocator);
        return application;
    }

    pub fn destroy(self: *Application, allocator: std.mem.Allocator) void {
        self.bookmarker.destroy(allocator);
        self.reader.destroy(allocator);
        allocator.destroy(self);
    }

    pub fn load(self: *Application, paths: *const Paths) !void {
        try self.bookmarker.load();
        try self.reader.load(paths);
    }

    pub fn handle_key(self: *Application, key: layout.input.Key) !bool {
        if (key == .control and key.control == 'u') {
            try self.switch_experience();
            return true;
        }
        return switch (self.experience) {
            .reader => self.reader.handle_key(key),
            .bookmarker => self.bookmarker.handle_key(key),
        };
    }

    pub fn poll_background(self: *Application) !bool {
        var changed = try self.bookmarker.poll_background();
        changed = try self.reader.poll_background() or changed;
        return changed;
    }

    fn switch_experience(self: *Application) !void {
        self.experience = switch (self.experience) {
            .reader => .bookmarker,
            .bookmarker => .reader,
        };
        // Both experiences share one canvas and both paint incrementally
        // against what they last drew, so each has to be told its surface is
        // gone when the other takes the canvas over.
        self.bookmarker.dom_view.invalidate_surface();
        self.reader.dom_view.invalidate_surface();
        if (self.experience == .bookmarker) {
            try self.bookmarker.load();
        }
    }
};

test "merged application switches experiences and renders both" {
    const terminal = @import("markix").terminal;
    const view = @import("view.zig");

    const application = try Application.create(
        std.testing.allocator,
        std.testing.io,
        &@import("data").paths.testing_paths,
    );
    defer application.destroy(std.testing.allocator);

    var reader_canvas = try terminal.TerminalCanvas.init(
        std.testing.allocator,
        120,
        40,
    );
    defer reader_canvas.deinit();
    try view.render(application, &reader_canvas);
    try std.testing.expect(application.experience == .reader);

    _ = try application.handle_key(.{ .control = 'u' });
    try std.testing.expect(application.experience == .bookmarker);
    var bookmarker_canvas = try terminal.TerminalCanvas.init(
        std.testing.allocator,
        120,
        40,
    );
    defer bookmarker_canvas.deinit();
    try view.render(application, &bookmarker_canvas);

    _ = try application.handle_key(.{ .control = 'u' });
    try std.testing.expect(application.experience == .reader);
    var reader_canvas_again = try terminal.TerminalCanvas.init(
        std.testing.allocator,
        120,
        40,
    );
    defer reader_canvas_again.deinit();
    try view.render(application, &reader_canvas_again);
}

test "switching experiences repaints whichever one takes the canvas" {
    const terminal = @import("markix").terminal;
    const view = @import("view.zig");

    const application = try Application.create(
        std.testing.allocator,
        std.testing.io,
        &@import("data").paths.testing_paths,
    );
    defer application.destroy(std.testing.allocator);
    var canvas = try terminal.TerminalCanvas.init(std.testing.allocator, 130, 60);
    defer canvas.deinit();

    try view.render(application, &canvas);
    canvas.commit_frame();

    try view.render(application, &canvas);
    try std.testing.expectEqual(@as(u16, 0), application.reader.dom_view.last_painted);
    canvas.commit_frame();

    _ = try application.handle_key(.{ .control = 'u' });
    try view.render(application, &canvas);
    try std.testing.expect(application.bookmarker.dom_view.last_painted > 0);
    canvas.commit_frame();

    _ = try application.handle_key(.{ .control = 'u' });
    try view.render(application, &canvas);
    try std.testing.expect(application.reader.dom_view.last_painted > 0);
}

test "ctrl-u switches, and paging moved off it" {
    const application = try Application.create(
        std.testing.allocator,
        std.testing.io,
        &@import("data").paths.testing_paths,
    );
    defer application.destroy(std.testing.allocator);

    _ = try application.handle_key(.{ .control = 'u' });
    try std.testing.expect(application.experience == .bookmarker);
    _ = try application.handle_key(.{ .control = 'u' });
    try std.testing.expect(application.experience == .reader);
}
