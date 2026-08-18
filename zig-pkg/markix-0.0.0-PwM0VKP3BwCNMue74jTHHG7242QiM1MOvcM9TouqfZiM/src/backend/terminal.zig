pub const limits = @import("terminal/limits.zig");
pub const input = @import("terminal/input.zig");

pub const Event = @import("terminal/event.zig").Event;
pub const LoopAction = @import("terminal/event.zig").LoopAction;
pub const LoopOptions = @import("terminal/event.zig").LoopOptions;
pub const Surface = @import("../widgets/surface.zig").Surface;
pub const text_width = @import("terminal/text_width.zig");
pub const TerminalCanvas = @import("terminal/canvas.zig").TerminalCanvas;
pub const TextAttributes = @import("../style/text_style.zig").Attributes;
pub const TextStyle = @import("../style/text_style.zig").TextStyle;
pub const ImageProtocol = @import("terminal/image.zig").Protocol;
pub const GraphicsCapabilities = @import("terminal/terminal.zig").GraphicsCapabilities;
pub const detect_image_protocol = @import("terminal/image.zig").detect;
pub const query_graphics_capabilities =
    @import("terminal/terminal.zig").query_graphics_capabilities;
pub const run_event_loop = @import("terminal/event.zig").run_event_loop;

pub const widgets = @import("../widgets.zig");
