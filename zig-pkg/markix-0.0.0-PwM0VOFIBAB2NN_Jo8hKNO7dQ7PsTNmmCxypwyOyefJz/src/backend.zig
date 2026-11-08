pub const Renderer = @import("backend/renderer.zig").Renderer;

pub const html = @import("backend/html.zig");
pub const cells = @import("backend/cells.zig");
pub const canvas = @import("backend/canvas.zig");
pub const patch = @import("backend/patch.zig");

pub const terminal = @import("backend/terminal.zig");
pub const Loop = @import("backend/loop.zig").Backend;

test {
    _ = @import("backend/renderer.zig");
    _ = html;
    _ = cells;
    _ = canvas;
    _ = patch;
    _ = @import("backend/terminal/input.zig");
    _ = @import("backend/terminal/terminal.zig");
    _ = @import("backend/terminal/graphics.zig");
    _ = @import("backend/terminal/sixel.zig");
}
