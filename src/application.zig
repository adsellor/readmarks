const std = @import("std");
const markix = @import("markix");
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

    pub fn handle_key(self: *Application, key: markix.Key) !bool {
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
        if (self.experience == .bookmarker) {
            try self.bookmarker.load();
        }
    }
};

test "merged application switches experiences and renders both" {
    const view = @import("view.zig");
    const Display = @import("ui/display.zig").Display;
    const application = try Application.create(
        std.testing.allocator,
        std.testing.io,
        &@import("data").paths.testing_paths,
    );
    defer application.destroy(std.testing.allocator);
    const display = try Display.create(std.testing.allocator, 120, 20, .none);
    defer display.destroy(std.testing.allocator);

    try view.render(application, display);
    try std.testing.expect(application.experience == .reader);
    try std.testing.expect(display.shows("READER"));
    _ = try application.handle_key(.{ .control = 'u' });
    try std.testing.expect(application.experience == .bookmarker);
    try view.render(application, display);
    try std.testing.expect(display.shows("BROWSE"));
    _ = try application.handle_key(.{ .control = 'u' });
    try std.testing.expect(application.experience == .reader);
    try view.render(application, display);
    try std.testing.expect(display.shows("READER"));
    try std.testing.expect(!display.shows("BROWSE"));
}

test "switching experiences repaints whichever one takes the display" {
    const view = @import("view.zig");
    const Display = @import("ui/display.zig").Display;
    const application = try Application.create(
        std.testing.allocator,
        std.testing.io,
        &@import("data").paths.testing_paths,
    );
    defer application.destroy(std.testing.allocator);
    const display = try Display.create(std.testing.allocator, 130, 30, .none);
    defer display.destroy(std.testing.allocator);

    try view.render(application, display);
    try view.render(application, display);
    try std.testing.expectEqual(@as(i32, 0), display.painted_area());
    _ = try application.handle_key(.{ .control = 'u' });
    try view.render(application, display);
    try std.testing.expect(display.painted_area() > 0);
    _ = try application.handle_key(.{ .control = 'u' });
    try view.render(application, display);
    try std.testing.expect(display.painted_area() > 0);
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
