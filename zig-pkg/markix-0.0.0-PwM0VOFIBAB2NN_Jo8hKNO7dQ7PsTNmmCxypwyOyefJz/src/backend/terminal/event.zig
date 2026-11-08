const std = @import("std");
const input = @import("input.zig");
const PointerButton = input.PointerButton;
const Key = input.Key;
const limits = @import("limits.zig");
const terminal = @import("terminal.zig");
const EventLoopBackend = @import("../loop.zig").Backend;

const posix = std.posix;

pub const Event = union(enum) {
    key: input.Key,
    resize: terminal.TerminalSize,
    poll: void,
    frame: void,
};

pub const LoopAction = enum { wait, redraw, stop };

pub const LoopOptions = struct {
    continuous_frames: bool = false,
    resize_poll_ms: u16 = 50,
    frames_max: u16 = 120,
};

pub fn read_input() !input.Batch {
    var bytes: [limits.input_keys_max]u8 = undefined;
    const count = try posix.read(posix.STDIN_FILENO, &bytes);
    if (count > 0) return input.parse(bytes[0..count]);
    if (count == 0) return error.EndOfInput;
    unreachable;
}

pub fn run_event_loop(
    io: std.Io,
    backend: EventLoopBackend,
    options: LoopOptions,
    comptime Context: type,
    context: *Context,
    comptime callback: fn (*Context, Event) anyerror!LoopAction,
) !void {
    std.debug.assert(backend.width() > 0);
    std.debug.assert(backend.height() > 0);
    if (options.resize_poll_ms == 0) return error.InvalidResizePollPeriod;
    const original_terminal = try terminal.enable_raw_mode();
    defer terminal.disable_raw_mode(original_terminal) catch |err| {
        std.log.err("failed to restore terminal mode: {s}", .{@errorName(err)});
    };

    try backend.enter_alternate_screen(io);
    defer backend.exit_alternate_screen(io) catch |err| {
        std.log.err("failed to exit alternate screen: {s}", .{@errorName(err)});
    };

    if (try callback(context, .{ .frame = {} }) == .stop) return;
    _ = try backend.render(io);
    var running = true;
    var drew = true;
    var next_frame: i96 = 0;
    var wheel_coalescer = WheelCoalescer{};
    while (running) {
        const previous_width = backend.width();
        const previous_height = backend.height();
        if (backend.resizable()) {
            const resize_action = try resize_if_needed(backend, context, callback);
            if (resize_action == .stop) break;
        }
        const resized = previous_width != backend.width() or previous_height != backend.height();
        if (resized) {
            running = try redraw(backend, io, context, callback, &drew);
            continue;
        }
        var action: LoopAction = .wait;
        if (try input_ready(wait_ms(io, options, drew, next_frame))) {
            action = try dispatch_batch(backend, io, context, callback, &wheel_coalescer);
        } else {
            const changed = try backend.poll_background(io);
            action = try callback(context, .{ .poll = {} });
            if (changed) action = merge_actions(action, .redraw);
        }
        if (action == .stop) break;
        drew = false;
        if (action == .redraw or options.continuous_frames) {
            running = try redraw(backend, io, context, callback, &drew);
            if (drew and options.frames_max > 0) {
                next_frame = frame_deadline(io, options, next_frame);
            }
        }
    }
}

fn wait_ms(io: std.Io, options: LoopOptions, drew: bool, next_frame: i96) i32 {
    std.debug.assert(options.resize_poll_ms > 0);
    if (!drew) return options.resize_poll_ms;
    if (options.frames_max == 0) return 0;
    const remaining = next_frame - std.Io.Timestamp.now(io, .awake).nanoseconds;
    if (remaining <= 0) return 0;
    const ms = @divFloor(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms);
    return @intCast(@min(@as(i96, options.resize_poll_ms), ms));
}

fn frame_deadline(io: std.Io, options: LoopOptions, previous: i96) i96 {
    std.debug.assert(options.frames_max > 0);
    const period = @divTrunc(@as(i96, std.time.ns_per_s), options.frames_max);
    std.debug.assert(period > 0);
    const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
    if (previous + period < now) return now + period;
    return previous + period;
}

fn dispatch_batch(
    backend: EventLoopBackend,
    io: std.Io,
    context: anytype,
    comptime callback: anytype,
    wheel_coalescer: *WheelCoalescer,
) !LoopAction {
    const batch = try read_input();
    const now_ns = std.Io.Timestamp.now(io, .awake).nanoseconds;
    std.debug.assert(now_ns >= 0);
    std.debug.assert(backend.width() > 0);
    var action: LoopAction = .wait;
    for (batch.items()) |key| {
        if (!wheel_coalescer.shouldDispatch(key, now_ns)) continue;
        const next_action = try dispatch_input(backend, io, context, callback, key);
        action = merge_actions(action, next_action);
        if (action == .stop) return action;
    }
    return if (action == .wait) .redraw else action;
}

fn dispatch_input(
    backend: EventLoopBackend,
    io: std.Io,
    context: anytype,
    comptime callback: anytype,
    key: input.Key,
) !LoopAction {
    return switch (key) {
        .pointer => |pointer| dispatch_pointer(
            backend,
            io,
            context,
            callback,
            key,
            pointer,
        ),
        else => callback(context, .{ .key = key }),
    };
}

fn dispatch_pointer(
    backend: EventLoopBackend,
    io: std.Io,
    context: anytype,
    comptime callback: anytype,
    key: input.Key,
    pointer: input.Pointer,
) !LoopAction {
    std.debug.assert(pointer.x <= std.math.maxInt(u16));
    std.debug.assert(pointer.y <= std.math.maxInt(u16));
    var action: LoopAction = switch (backend.handle_pointer(pointer)) {
        .ignored => .wait,
        .redraw => .redraw,
        .copy => copy: {
            try backend.copy_selection(io);
            break :copy .redraw;
        },
    };
    if (pointer.action == .press) {
        const app_action = try callback(context, .{ .key = key });
        action = merge_actions(action, app_action);
    }
    return action;
}

fn merge_actions(current: LoopAction, next: LoopAction) LoopAction {
    if (current == .stop or next == .stop) return .stop;
    if (current == .redraw or next == .redraw) return .redraw;
    return .wait;
}

fn resize_if_needed(
    backend: EventLoopBackend,
    context: anytype,
    comptime callback: anytype,
) !LoopAction {
    const size = try terminal.get_terminal_size();
    if (size.width != backend.width() or size.height != backend.height()) {
        try backend.resize(size);
        return callback(context, .{ .resize = size });
    }
    return .wait;
}

fn redraw(
    backend: EventLoopBackend,
    io: std.Io,
    context: anytype,
    comptime callback: anytype,
    changed: *bool,
) !bool {
    if (try callback(context, .{ .frame = {} }) == .stop) return false;
    changed.* = try backend.render(io);
    return true;
}

fn input_ready(timeout_ms: i32) !bool {
    std.debug.assert(timeout_ms >= 0);
    std.debug.assert(posix.STDIN_FILENO >= 0);
    var descriptors = [_]posix.pollfd{.{
        .fd = posix.STDIN_FILENO,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    const ready_count = try posix.poll(&descriptors, timeout_ms);
    if (ready_count == 0) return false;
    const events = descriptors[0].revents;
    if (events & posix.POLL.NVAL != 0) return error.InvalidInputDescriptor;
    if (events & posix.POLL.ERR != 0) return error.InputError;
    if (events & posix.POLL.HUP != 0) return error.EndOfInput;
    return events & posix.POLL.IN != 0;
}

const WheelCoalescer = struct {
    burst_window_ns: u64 = 30 * std.time.ns_per_ms,

    last_wheel: ?struct { button: PointerButton, ns: u64 } = null,

    fn shouldDispatch(self: *WheelCoalescer, key: Key, now_ns: i96) bool {
        std.debug.assert(now_ns >= 0);
        const now: u64 = @intCast(now_ns);
        const wheel: ?PointerButton = switch (key) {
            .pointer => |pointer| if (pointer.action == .press and
                (pointer.button == .wheel_up or pointer.button == .wheel_down))
                pointer.button
            else
                null,
            else => null,
        };
        if (wheel) |button| {
            std.debug.assert(button == .wheel_up or button == .wheel_down);
            const same_burst = if (self.last_wheel) |last|
                last.button == button and now - last.ns < self.burst_window_ns
            else
                false;
            if (!same_burst) self.last_wheel = .{ .button = button, .ns = now };
            return !same_burst;
        }
        self.last_wheel = null;
        return true;
    }
};

test "wheel presses in one burst coalesce but reverse direction dispatches" {
    var coalescer = WheelCoalescer{};
    const down = Key{ .pointer = .{ .x = 1, .y = 1, .action = .press, .button = .wheel_down } };
    const up = Key{ .pointer = .{ .x = 1, .y = 1, .action = .press, .button = .wheel_up } };
    try std.testing.expect(coalescer.shouldDispatch(down, 0));
    try std.testing.expect(!coalescer.shouldDispatch(down, 1));
    try std.testing.expect(!coalescer.shouldDispatch(down, 2));
    try std.testing.expect(coalescer.shouldDispatch(up, 3));
    try std.testing.expect(!coalescer.shouldDispatch(up, 4));
    try std.testing.expect(coalescer.shouldDispatch(down, 5));
}

test "wheel presses outside the burst window dispatch separately" {
    var coalescer = WheelCoalescer{};
    const down = Key{ .pointer = .{ .x = 1, .y = 1, .action = .press, .button = .wheel_down } };
    try std.testing.expect(coalescer.shouldDispatch(down, 0));
    try std.testing.expect(coalescer.shouldDispatch(down, 31 * std.time.ns_per_ms));
    try std.testing.expect(!coalescer.shouldDispatch(down, 31 * std.time.ns_per_ms + 1));
}

test "a non-wheel key resets the wheel burst" {
    var coalescer = WheelCoalescer{};
    const down = Key{ .pointer = .{ .x = 1, .y = 1, .action = .press, .button = .wheel_down } };
    _ = coalescer.shouldDispatch(down, 0);
    try std.testing.expect(coalescer.shouldDispatch(Key{ .character = 'a' }, 1));
    try std.testing.expect(coalescer.shouldDispatch(down, 2));
}
