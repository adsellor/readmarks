const std = @import("std");
const builtin = @import("builtin");
const markix = @import("markix");
const display_mod = @import("ui/display.zig");
const Display = display_mod.Display;
const Application = @import("application.zig").Application;
const theme = @import("theme.zig");
const view = @import("view.zig");
const data = @import("data");
const import_command = @import("import_command.zig");
const build_options = @import("build_options");

const Context = struct {
    display: *Display,
    application: *Application,
};

pub fn main(init: std.process.Init) !void {
    const paths = try data.Paths.resolve(.{
        .home = init.environ_map.get("HOME") orelse ".",
        .config_home = init.environ_map.get("XDG_CONFIG_HOME"),
        .data_home = init.environ_map.get("XDG_DATA_HOME"),
        .cache_home = init.environ_map.get("XDG_CACHE_HOME"),
    });
    theme.configure(init.environ_map.get("READMARKS_THEME"));

    var threaded: std.Io.Threaded = undefined;
    const io: std.Io = if (builtin.os.tag == .linux) io: {
        // Fetch + parse of the largest allowed feed exceeds the 16 MiB default
        // stack in Debug mode; measured via the rss repro harness: a full
        // fetch + parse of a 32 KiB article with 255 document blocks needs
        // ~21 MiB (crash at 20.5 MiB), and 96-block documents need ~19 MiB.
        // 32 MiB keeps ~11 MiB of headroom for Document growth and TLS frames.
        // Pass through the process environ and argv0 so spawned processes
        // (browser open, ...) inherit the environment.
        threaded = std.Io.Threaded.init(init.gpa, .{
            .stack_size = 32 * 1024 * 1024,
            .argv0 = .init(init.minimal.args),
            .environ = init.minimal.environ,
        });
        break :io threaded.io();
    } else init.io;
    defer if (builtin.os.tag == .linux) threaded.deinit();

    // A command runs and exits; with no command the reader opens.
    const handled = command(init, io, &paths) catch |err| switch (err) {
        // Already said in words the user can act on; a stack trace on top of
        // that is noise.
        error.Reported => std.process.exit(1),
        else => return err,
    };
    if (handled) return;
    try run_reader(init, io, &paths);
}

/// Runs the named subcommand, reporting whether there was one.
fn command(init: std.process.Init, io: std.Io, paths: *const data.Paths) !bool {
    var arguments = try std.process.Args.Iterator.initAllocator(
        init.minimal.args,
        init.gpa,
    );
    defer arguments.deinit();
    _ = arguments.skip();
    const name = arguments.next() orelse return false;
    if (std.mem.eql(u8, name, "import")) {
        try import_command.run(init.gpa, io, paths, &arguments);
        return true;
    }
    if (std.mem.eql(u8, name, "version") or
        std.mem.eql(u8, name, "--version") or
        std.mem.eql(u8, name, "-V"))
    {
        try write_version(io);
        return true;
    }
    if (std.mem.eql(u8, name, "help") or
        std.mem.eql(u8, name, "--help") or
        std.mem.eql(u8, name, "-h"))
    {
        try write_usage(io, paths);
        return true;
    }
    try write_out(io, "readmarks: unknown command '");
    try write_out(io, name);
    try write_out(io, "'\n\n");
    try write_usage(io, paths);
    return error.Reported;
}

fn write_version(io: std.Io) !void {
    try write_out(io, "readmarks ");
    try write_out(io, build_options.version);
    try write_out(io, "\n");
}

fn write_usage(io: std.Io, paths: *const data.Paths) !void {
    try write_out(io,
        \\readmarks -- a terminal feed reader and bookmarker
        \\
        \\Usage:
        \\  readmarks                    open the reader
        \\  readmarks import <file>...   add feeds from another tool's list
        \\  readmarks help               show this
        \\  readmarks version            print the version
        \\
        \\Import understands OPML, newsboat urls files, plain URL lists and
        \\readmarks feed lists, guessed from the file unless --format says
        \\otherwise:
        \\
        \\  readmarks import --format=newsboat ~/.newsboat/urls
        \\  readmarks import subscriptions.opml
        \\
        \\Feeds live in
        \\
    );
    try write_out(io, "  ");
    try write_out(io, paths.config.bytes());
    try write_out(io, "/feeds\n");
}

fn write_out(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn run_reader(init: std.process.Init, io: std.Io, paths: *const data.Paths) !void {
    const size = try markix.terminal.get_terminal_size();
    const capabilities = markix.terminal.query_graphics_capabilities(io) catch
        markix.terminal.GraphicsCapabilities{};
    const protocol = markix.terminal.graphics.detect(
        capabilities,
        init.environ_map.get("MARKIX_IMAGE_PROTOCOL"),
    );
    const display = try Display.create(
        init.gpa,
        std.math.clamp(@as(i32, size.width), 1, display_mod.columns_max),
        std.math.clamp(@as(i32, size.height), 1, display_mod.rows_max),
        protocol,
    );
    defer display.destroy(init.gpa);
    std.debug.assert(display.width() > 0 and display.width() <= display_mod.columns_max);
    std.debug.assert(display.height() > 0 and display.height() <= display_mod.rows_max);

    const application = try Application.create(init.gpa, io, paths);
    defer application.destroy(init.gpa);
    try application.load(paths);
    var context = Context{ .display = display, .application = application };
    try markix.run_event_loop(io, display.backend(), .{}, Context, &context, event_callback);
}

fn event_callback(context: *Context, event: markix.Event) !markix.LoopAction {
    std.debug.assert(context.display.width() > 0);
    std.debug.assert(context.display.height() > 0);
    return switch (event) {
        .key => |key| if (try context.application.handle_key(key))
            .redraw
        else
            .stop,
        .resize => .redraw,
        .poll => if (try context.application.poll_background())
            .redraw
        else
            .wait,
        .frame => frame: {
            try view.render(context.application, context.display);
            break :frame .wait;
        },
    };
}
