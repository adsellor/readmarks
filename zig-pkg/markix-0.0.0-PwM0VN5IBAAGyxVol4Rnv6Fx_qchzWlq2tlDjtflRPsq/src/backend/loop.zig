const std = @import("std");
const input = @import("../utils/input.zig");
const terminal = @import("terminal/terminal.zig");

const Pointer = input.Pointer;
const TerminalSize = terminal.TerminalSize;

pub const PointerAction = enum {
    ignored,
    redraw,
    copy,
};

pub const Size = struct {
    width: u16,
    height: u16,
};

pub const Backend = struct {
    context: *anyopaque,

    size_fn: *const fn (context: *anyopaque) Size,
    resizable_fn: *const fn (context: *anyopaque) bool,
    resize_fn: *const fn (context: *anyopaque, size: TerminalSize) anyerror!void,
    render_fn: *const fn (context: *anyopaque, io: std.Io) anyerror!bool,
    poll_background_fn: *const fn (context: *anyopaque, io: std.Io) anyerror!bool,
    handle_pointer_fn: *const fn (context: *anyopaque, pointer: Pointer) PointerAction,
    copy_selection_fn: *const fn (context: *anyopaque, io: std.Io) anyerror!void,
    enter_alternate_screen: *const fn (io: std.Io) anyerror!void,
    exit_alternate_screen: *const fn (io: std.Io) anyerror!void,

    pub fn width(self: Backend) u16 {
        return self.size_fn(self.context).width;
    }

    pub fn height(self: Backend) u16 {
        return self.size_fn(self.context).height;
    }

    pub fn resizable(self: Backend) bool {
        return self.resizable_fn(self.context);
    }

    pub fn resize(self: Backend, size: TerminalSize) !void {
        try self.resize_fn(self.context, size);
    }

    pub fn render(self: Backend, io: std.Io) !bool {
        return try self.render_fn(self.context, io);
    }

    pub fn poll_background(self: Backend, io: std.Io) !bool {
        return try self.poll_background_fn(self.context, io);
    }

    pub fn handle_pointer(self: Backend, pointer: Pointer) PointerAction {
        return self.handle_pointer_fn(self.context, pointer);
    }

    pub fn copy_selection(self: Backend, io: std.Io) !void {
        try self.copy_selection_fn(self.context, io);
    }
};
