pub const input = @import("terminal/input.zig");
pub const limits = @import("terminal/limits.zig");

pub const Event = @import("terminal/event.zig").Event;
pub const LoopAction = @import("terminal/event.zig").LoopAction;
pub const LoopOptions = @import("terminal/event.zig").LoopOptions;
pub const run_event_loop = @import("terminal/event.zig").run_event_loop;

pub const get_terminal_size = @import("terminal/terminal.zig").get_terminal_size;
pub const TerminalSize = @import("terminal/terminal.zig").TerminalSize;
pub const enter_alternate_screen =
    @import("terminal/terminal.zig").enter_alternate_screen;
pub const exit_alternate_screen =
    @import("terminal/terminal.zig").exit_alternate_screen;

pub const graphics = @import("terminal/graphics.zig");
pub const Graphics = graphics.Graphics;
pub const GraphicsCapabilities = @import("terminal/terminal.zig").GraphicsCapabilities;
pub const query_graphics_capabilities =
    @import("terminal/terminal.zig").query_graphics_capabilities;
