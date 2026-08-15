const std = @import("std");
const builtin = @import("builtin");
const markix = @import("markix");
const terminal = markix.terminal;
const web = markix.web;

const web_io = @import("web_io.zig");
const Application = @import("application.zig").Application;
const view = @import("view.zig");

// The web build routes all HTTP through browser `fetch()`, so TLS must be
// compiled out of `std.http.Client` (the native image-loader client is
// still instantiated but its requests fail gracefully through the shim).
// Logging is overridden to avoid pulling std.Io.Threaded (which references
// posix internals unavailable on freestanding).
pub const std_options = std.Options{
    .http_disable_tls = true,
    .logFn = wasmLogFn,
};

// Prevents std.Io.Dir.cwd() from referencing std.posix.AT.FDCWD on freestanding.
pub fn std_options_cwd() std.Io.Dir {
    return .{ .handle = {} };
}

fn wasmLogFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = .{ level, scope, format, args };
}

const Key = markix.Key;

const canvas_width: u16 = 120;
const canvas_rows: u16 = 40;

/// The browser has no home directory and no environment: files are the ones
/// the JS glue seeded into wasm memory, so every root is the same root.
const web_paths = @import("data").Paths.under_home("") catch unreachable;

var allocator: std.mem.Allocator = undefined;
var canvas: terminal.TerminalCanvas = undefined;
var application: *Application = undefined;
var io: std.Io = undefined;
pub var frame_buffer: [web.commands.frame_bytes_max]u8 = undefined;
var input_queue: web.input.Queue(64) = .{};
var initialized = false;

pub export fn rm_frame_ptr() u32 {
    return @intCast(@intFromPtr(&frame_buffer));
}

pub export fn rm_init() void {
    allocator = if (builtin.target.cpu.arch.isWasm())
        std.heap.wasm_allocator
    else
        std.heap.page_allocator;
    io = web_io.io();
    canvas = terminal.TerminalCanvas.init(allocator, canvas_width, canvas_rows * 2) catch return;
    application = Application.create(allocator, io, &web_paths) catch return;
    application.load(&web_paths) catch {};
    initialized = true;
}

pub export fn rm_input(tag: u32, a: u32, b: u32, c: u32) void {
    if (!initialized) return;
    input_queue.push(.{ .tag = tag, .a = a, .b = b, .c = c });
}

// Event-driven rendering: build layout tree once, serialize to frame buffer,
// only re-serialize when state changes.
var frame_serialized = false;
var state_changed = true;

pub export fn rm_update() u32 {
    if (!initialized) return 1; // error: not initialized

    // Process input
    var keys: [64]Key = undefined;
    const count = input_queue.drain(&keys);
    if (count > 0) {
        for (keys[0..count]) |key| {
            const handled = application.handle_key(key) catch false;
            if (handled) {
                state_changed = true;
                var buf: [64]u8 = undefined;
                switch (key) {
                    .character => |c| {
                        const msg = std.fmt.bufPrint(&buf, "handled character: {c}", .{c}) catch "handled character";
                        web_io.log(msg);
                    },
                    .up => web_io.log("handled up"),
                    .down => web_io.log("handled down"),
                    .left => web_io.log("handled left"),
                    .right => web_io.log("handled right"),
                    .enter => web_io.log("handled enter"),
                    else => web_io.log("handled other key"),
                }
            }
        }
    }

    // Poll for background updates (feed fetches, etc.)
    if (application.poll_background() catch false) {
        state_changed = true;
    }

    // Only re-render if state changed
    if (!state_changed and frame_serialized) {
        return 0; // No update needed
    }

    // The DOM renderer establishes the frame itself (start_partial_frame),
    // carrying the previous frame forward so untouched nodes need no repaint.
    view.render(application, &canvas) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "view.render failed: {s}", .{@errorName(err)}) catch "view.render failed: unknown";
        web_io.log(msg);
        return 2; // error: render failed
    };

    const length = web.serialize.serialize_frame(&canvas, &frame_buffer) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "serialize_frame failed: {s}", .{@errorName(err)}) catch "serialize_frame failed: unknown";
        web_io.log(msg);
        return 3; // error: serialize failed
    };

    // Promote this frame to the baseline the next partial frame restores from.
    // Without it every frame would rebuild from an empty previous frame and
    // clean nodes would render blank.
    canvas.commit_frame();
    frame_serialized = true;
    state_changed = false;
    return @intCast(length);
}

// JS glue seeds in-memory files (e.g. the newsboat urls list) before the
// app loads. Path and bytes live in wasm memory.
pub export fn rm_seed_file(path_ptr: u32, path_len: u32, data_ptr: u32, data_len: u32) void {
    const path = bytes_from_ptr(path_ptr, path_len);
    const data = bytes_from_ptr(data_ptr, data_len);
    web_io.seed(path, data) catch {};
}

// JS glue delivers a completed browser fetch. request_id is the worker
// index the transport registered with js_fetch_request.
pub export fn rm_fetch_response(request_id: u32, status: i32, data_ptr: u32, data_len: u32) void {
    if (!initialized) return;
    const data = bytes_from_ptr(data_ptr, data_len);
    application.reader.web_deliver(@intCast(request_id), status, data);
}

fn bytes_from_ptr(ptr: u32, len: u32) []const u8 {
    if (len == 0) return &.{};
    return @as([*]const u8, @ptrFromInt(ptr))[0..len];
}
