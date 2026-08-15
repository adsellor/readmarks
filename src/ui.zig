//! Components shared by both experiences. A pane, a header, a status bar, the
//! command centre and the help sheet are one implementation each, configured
//! by whoever mounts them.

pub const tokens = @import("ui/tokens.zig");
pub const pane = @import("ui/pane.zig");
pub const command_center = @import("ui/command_center.zig");
pub const status = @import("ui/status.zig");
pub const help = @import("ui/help.zig");
pub const header = @import("ui/header.zig");
pub const document = @import("ui/document.zig");

pub const Role = pane.Role;

test {
    _ = tokens;
    _ = pane;
    _ = command_center;
    _ = status;
    _ = help;
    _ = header;
    _ = document;
}
