const std = @import("std");
const image = @import("../backend/terminal/image.zig");
const Surface = @import("surface.zig").Surface;
const Rect = @import("../layout/rect.zig").Rect;

pub const Image = struct {
    path: []const u8,
    id: u32 = 1,
    crop_top_rows: u16 = 0,
    full_height_rows: u16,

    pub fn supported(surface: Surface) bool {
        return surface.canvas.image_protocol != .none;
    }

    pub fn draw(self: Image, surface: Surface, rect: Rect) !bool {
        std.debug.assert(rect.width > 0 or rect.height == 0);
        std.debug.assert(self.path.len > 0 or rect.width == 0);
        if (!supported(surface)) return false;
        const placement = try image.Placement.init(
            surface.canvas.image_protocol,
            self.id,
            rect.x,
            rect.y,
            rect.width,
            rect.height,
            self.crop_top_rows,
            self.full_height_rows,
            self.path,
        );
        try surface.canvas.add_image(placement);
        return true;
    }
};
