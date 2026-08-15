const std = @import("std");

pub const layout_items_max: u8 = 16;
pub const layout_nodes_max: u16 = 64;

comptime {
    std.debug.assert(layout_items_max > 0);
    std.debug.assert(layout_nodes_max > layout_items_max);
}
