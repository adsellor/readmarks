const std = @import("std");
const limits = @import("limits.zig");
const sixel = @import("sixel.zig");

pub const Protocol = enum { none, kitty, sixel };

pub const Placement = struct {
    protocol: Protocol,
    id: u32,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    crop_top_rows: u16,
    full_height_rows: u16,
    path: [limits.image_path_bytes_max]u8 = undefined,
    path_length: u16,

    pub fn init(
        protocol: Protocol,
        id: u32,
        x: u16,
        y: u16,
        width: u16,
        height: u16,
        crop_top_rows: u16,
        full_height_rows: u16,
        path: []const u8,
    ) !Placement {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        if (path.len == 0 or path.len > limits.image_path_bytes_max) {
            return error.InvalidImagePath;
        }
        if (width == 0 or height == 0) return error.InvalidImageSize;
        if (full_height_rows == 0) return error.InvalidImageSize;
        if (crop_top_rows + height > full_height_rows) return error.InvalidImageCrop;
        var placement = Placement{
            .protocol = protocol,
            .id = id,
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .crop_top_rows = crop_top_rows,
            .full_height_rows = full_height_rows,
            .path_length = @intCast(path.len),
        };
        @memcpy(placement.path[0..path.len], path);
        return placement;
    }

    pub fn path_bytes(self: *const Placement) []const u8 {
        return self.path[0..self.path_length];
    }

    pub fn equals(self: *const Placement, other: *const Placement) bool {
        return self.protocol == other.protocol and
            self.id == other.id and
            self.x == other.x and
            self.y == other.y and
            self.width == other.width and
            self.height == other.height and
            self.crop_top_rows == other.crop_top_rows and
            self.full_height_rows == other.full_height_rows and
            std.mem.eql(u8, self.path_bytes(), other.path_bytes());
    }

    pub fn same_image(self: *const Placement, other: *const Placement) bool {
        return self.protocol == other.protocol and
            self.id == other.id and
            std.mem.eql(u8, self.path_bytes(), other.path_bytes());
    }
};

pub fn detect(
    sixel_advertised: bool,
    kitty_advertised: bool,
    override: ?[]const u8,
) Protocol {
    if (override) |value| {
        if (std.ascii.eqlIgnoreCase(value, "none")) return .none;
        if (std.ascii.eqlIgnoreCase(value, "kitty")) return .kitty;
        if (std.ascii.eqlIgnoreCase(value, "sixel")) return .sixel;
    }
    if (sixel_advertised) return .sixel;
    if (kitty_advertised) return .kitty;
    return .none;
}

pub fn display(
    io: std.Io,
    placement: *const Placement,
    upload: bool,
    sixel_scratch: sixel.Scratch,
    sixel_bitmap_length: u32,
) !void {
    std.debug.assert(placement.width > 0 or placement.height == 0);
    std.debug.assert(placement.path_length <= placement.path.len);
    switch (placement.protocol) {
        .none => {},
        .kitty => {
            if (upload) try upload_kitty(io, placement);
            try place_kitty(io, placement);
        },
        .sixel => try sixel.display(
            io,
            .{
                .path = placement.path_bytes(),
                .x = placement.x,
                .y = placement.y,
                .width_cells = placement.width,
                .height_cells = placement.height,
                .crop_top_rows = placement.crop_top_rows,
                .full_height_rows = placement.full_height_rows,
            },
            sixel_scratch,
            sixel_bitmap_length,
        ),
    }
}

pub fn prepare_sixel(
    io: std.Io,
    placement: *const Placement,
    bitmap_buffer: []u8,
) !u32 {
    std.debug.assert(placement.width > 0);
    std.debug.assert(placement.height > 0);
    if (placement.protocol != .sixel) return error.InvalidImageProtocol;
    return sixel.prepare(
        io,
        .{
            .path = placement.path_bytes(),
            .x = placement.x,
            .y = placement.y,
            .width_cells = placement.width,
            .height_cells = placement.height,
            .crop_top_rows = placement.crop_top_rows,
            .full_height_rows = placement.full_height_rows,
        },
        bitmap_buffer,
    );
}

fn upload_kitty(io: std.Io, placement: *const Placement) !void {
    std.debug.assert(placement.path_length > 0);
    std.debug.assert(placement.id > 0);
    var file = try std.Io.Dir.openFileAbsolute(io, placement.path_bytes(), .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size == 0 or stat.size > limits.image_file_bytes_max) {
        return error.InvalidImageFileSize;
    }
    var source: [limits.image_chunk_bytes]u8 = undefined;
    var offset: u64 = 0;
    while (offset < stat.size) {
        const count = try file.readStreaming(io, &.{&source});
        if (count == 0) return error.UnexpectedEndOfImage;
        const final = offset + count == stat.size;
        try write_chunk(io, placement.id, source[0..count], offset == 0, !final);
        offset += count;
    }
}

pub fn write_delete(writer: *std.Io.Writer, placement: *const Placement) !void {
    if (placement.protocol != .kitty) return;
    try writer.print(
        "\x1B_Ga=d,d=i,q=2,i={d},p=1\x1B\\",
        .{placement.id},
    );
}

fn write_chunk(
    io: std.Io,
    image_id: u32,
    source: []const u8,
    first: bool,
    more: bool,
) !void {
    std.debug.assert(source.len > 0);
    std.debug.assert(image_id > 0);
    var output: [limits.image_chunk_output_bytes_max]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var encoded: [limits.image_chunk_encoded_bytes]u8 = undefined;
    const payload = std.base64.standard.Encoder.encode(&encoded, source);
    if (first) {
        try writer.print(
            "\x1B_Ga=t,f=100,t=d,q=2,i={d},m={d};",
            .{ image_id, @intFromBool(more) },
        );
    } else {
        try writer.print("\x1B_Gq=2,m={d};", .{@intFromBool(more)});
    }
    try writer.writeAll(payload);
    try writer.writeAll("\x1B\\");
    try std.Io.File.stdout().writeStreamingAll(io, writer.buffered());
}

fn place_kitty(io: std.Io, placement: *const Placement) !void {
    std.debug.assert(placement.protocol == .kitty);
    std.debug.assert(placement.id > 0);
    const dimensions = try png_dimensions(io, placement.path_bytes());
    const crop_y = scaled_row(
        dimensions.height,
        placement.crop_top_rows,
        placement.full_height_rows,
    );
    const crop_end = scaled_row(
        dimensions.height,
        placement.crop_top_rows + placement.height,
        placement.full_height_rows,
    );
    const crop_height = @max(crop_end - crop_y, 1);
    var output: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try writer.print("\x1B[{d};{d}H", .{ placement.y + 1, placement.x + 1 });
    try writer.print(
        "\x1B_Ga=p,q=2,i={d},p=1,x=0,y={d},w={d},h={d},c={d},r={d},z=1,C=1;\x1B\\",
        .{
            placement.id,
            crop_y,
            dimensions.width,
            crop_height,
            placement.width,
            placement.height,
        },
    );
    try std.Io.File.stdout().writeStreamingAll(io, writer.buffered());
}

const Dimensions = struct { width: u32, height: u32 };

fn png_dimensions(io: std.Io, path: []const u8) !Dimensions {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var header: [24]u8 = undefined;
    const count = try file.readPositionalAll(io, &header, 0);
    if (count != header.len) return error.InvalidPngHeader;
    if (!std.mem.eql(u8, header[0..8], "\x89PNG\r\n\x1a\n")) {
        return error.InvalidPngHeader;
    }
    const width = std.mem.readInt(u32, header[16..20], .big);
    const height = std.mem.readInt(u32, header[20..24], .big);
    if (width == 0 or height == 0) return error.InvalidPngDimensions;
    return .{ .width = width, .height = height };
}

fn scaled_row(image_height: u32, row: u16, full_height: u16) u32 {
    std.debug.assert(full_height > 0);
    return @intCast(
        @divFloor(@as(u64, image_height) * row, full_height),
    );
}

test "graphics detection uses negotiated capabilities" {
    try std.testing.expectEqual(Protocol.kitty, detect(false, true, null));
    try std.testing.expectEqual(Protocol.sixel, detect(true, true, null));
    try std.testing.expectEqual(Protocol.none, detect(false, false, null));
    try std.testing.expectEqual(Protocol.sixel, detect(false, false, "sixel"));
}
