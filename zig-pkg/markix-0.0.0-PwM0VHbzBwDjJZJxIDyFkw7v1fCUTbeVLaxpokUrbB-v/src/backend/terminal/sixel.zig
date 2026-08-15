const std = @import("std");
const builtin = @import("builtin");
const limits = @import("limits.zig");

const cell_pixel_width: u16 = 8;
const cell_pixel_height: u16 = 16;
const palette_size: u8 = 16;

pub const Options = struct {
    path: []const u8,
    x: u16,
    y: u16,
    width_cells: u16,
    height_cells: u16,
    crop_top_rows: u16,
    full_height_rows: u16,
};

pub const Scratch = struct {
    bitmap: []u8,
    output: []u8,
};

const Bitmap = struct {
    bytes: []const u8,
    offset: u32,
    width: u16,
    height: u16,
    row_stride: u32,
    top_down: bool,

    fn color(self: Bitmap, x: u16, y: u16) u8 {
        const source_y = if (self.top_down) y else self.height - 1 - y;
        const index = self.offset + @as(u32, source_y) * self.row_stride +
            @as(u32, x) * 3;
        const blue = self.bytes[index];
        const green = self.bytes[index + 1];
        const red = self.bytes[index + 2];
        return ((red >> 7) << 3) | ((green >> 7) << 2) | (blue >> 6);
    }
};

pub fn prepare(
    io: std.Io,
    options: Options,
    bitmap_buffer: []u8,
) !u32 {
    std.debug.assert(options.path.len > 0);
    std.debug.assert(bitmap_buffer.len > 0);
    std.debug.assert(bitmap_buffer.len >= limits.sixel_bitmap_bytes_max);
    const width = std.math.mul(u16, options.width_cells, cell_pixel_width) catch
        return error.SixelImageTooWide;
    const height = std.math.mul(u16, options.full_height_rows, cell_pixel_height) catch
        return error.SixelImageTooTall;
    var path_buffer: [limits.image_path_bytes_max + 16]u8 = undefined;
    const bitmap_path = try std.fmt.bufPrint(&path_buffer, "{s}.sixel.bmp", .{options.path});
    try ensure_bitmap(io, options.path, bitmap_path, width, height);
    const bytes = try read_bitmap(io, bitmap_path, bitmap_buffer);
    _ = try parse_bitmap(bytes, width, height);
    return @intCast(bytes.len);
}

pub fn display(
    io: std.Io,
    options: Options,
    scratch: Scratch,
    bitmap_length: u32,
) !void {
    std.debug.assert(scratch.bitmap.len >= limits.sixel_bitmap_bytes_max);
    std.debug.assert(scratch.output.len >= limits.sixel_output_bytes_max);
    if (bitmap_length < 54 or bitmap_length > scratch.bitmap.len) {
        return error.InvalidSixelBitmapSize;
    }
    const width = std.math.mul(u16, options.width_cells, cell_pixel_width) catch
        return error.SixelImageTooWide;
    const height = std.math.mul(u16, options.full_height_rows, cell_pixel_height) catch
        return error.SixelImageTooTall;
    const bytes = scratch.bitmap[0..bitmap_length];
    const bitmap = try parse_bitmap(bytes, width, height);
    var writer = std.Io.Writer.fixed(scratch.output);
    try encode(&writer, bitmap, options);
    try std.Io.File.stdout().writeStreamingAll(io, writer.buffered());
}

fn ensure_bitmap(
    io: std.Io,
    source_path: []const u8,
    bitmap_path: []const u8,
    width: u16,
    height: u16,
) !void {
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);
    if (bitmap_matches(io, bitmap_path, width, height)) return;
    var width_buffer: [16]u8 = undefined;
    var height_buffer: [16]u8 = undefined;
    const width_text = try std.fmt.bufPrint(&width_buffer, "{d}", .{width});
    const height_text = try std.fmt.bufPrint(&height_buffer, "{d}", .{height});
    const arguments: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{
            "/usr/bin/sips", "-z",        height_text, width_text,
            "-s",            "format",    "bmp",       source_path,
            "--out",         bitmap_path,
        },
        else => return error.SixelConversionUnsupported,
    };
    var child = try std.process.spawn(io, .{
        .argv = arguments,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const termination = try child.wait(io);
    if (!termination.success()) return error.SixelConversionFailed;
    if (!bitmap_matches(io, bitmap_path, width, height)) {
        return error.InvalidSixelBitmap;
    }
}

fn bitmap_matches(io: std.Io, path: []const u8, width: u16, height: u16) bool {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    defer file.close(io);
    var header: [54]u8 = undefined;
    const count = file.readPositionalAll(io, &header, 0) catch return false;
    if (count != header.len) return false;
    if (!std.mem.eql(u8, header[0..2], "BM")) return false;
    const bitmap_width = std.mem.readInt(i32, header[18..22], .little);
    const bitmap_height = std.mem.readInt(i32, header[22..26], .little);
    if (bitmap_width != width or @abs(bitmap_height) != height) return false;
    if (std.mem.readInt(u16, header[28..30], .little) != 24) return false;
    return std.mem.readInt(u32, header[30..34], .little) == 0;
}

fn read_bitmap(
    io: std.Io,
    path: []const u8,
    buffer: []u8,
) ![]const u8 {
    std.debug.assert(path.len > 0);
    std.debug.assert(buffer.len > 0);
    std.debug.assert(buffer.len >= limits.sixel_bitmap_bytes_max);
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size < 54 or stat.size > limits.sixel_bitmap_bytes_max) {
        return error.InvalidSixelBitmapSize;
    }
    const bytes = buffer[0..@intCast(stat.size)];
    const count = try file.readPositionalAll(io, bytes, 0);
    if (count != bytes.len) return error.IncompleteSixelBitmap;
    return bytes;
}

fn parse_bitmap(bytes: []const u8, expected_width: u16, expected_height: u16) !Bitmap {
    std.debug.assert(expected_width > 0);
    std.debug.assert(expected_height > 0);
    if (bytes.len < 54 or !std.mem.eql(u8, bytes[0..2], "BM")) {
        return error.InvalidSixelBitmap;
    }
    const width_signed = std.mem.readInt(i32, bytes[18..22], .little);
    const height_signed = std.mem.readInt(i32, bytes[22..26], .little);
    if (width_signed <= 0 or height_signed == 0) return error.InvalidSixelBitmap;
    const width: u16 = @intCast(width_signed);
    const height: u16 = @intCast(@abs(height_signed));
    if (width != expected_width or height != expected_height) {
        return error.InvalidSixelBitmapDimensions;
    }
    if (std.mem.readInt(u16, bytes[28..30], .little) != 24) {
        return error.UnsupportedSixelBitmap;
    }
    if (std.mem.readInt(u32, bytes[30..34], .little) != 0) {
        return error.UnsupportedSixelBitmap;
    }
    const row_stride = std.mem.alignForward(u32, @as(u32, width) * 3, 4);
    const offset = std.mem.readInt(u32, bytes[10..14], .little);
    const required = @as(u64, offset) + @as(u64, row_stride) * height;
    if (required > bytes.len) return error.IncompleteSixelBitmap;
    return .{
        .bytes = bytes,
        .offset = offset,
        .width = width,
        .height = height,
        .row_stride = row_stride,
        .top_down = height_signed < 0,
    };
}

fn encode(writer: *std.Io.Writer, bitmap: Bitmap, options: Options) !void {
    std.debug.assert(bitmap.width > 0);
    std.debug.assert(bitmap.height > 0);
    const crop_start = scaled_row(
        bitmap.height,
        options.crop_top_rows,
        options.full_height_rows,
    );
    const crop_end = scaled_row(
        bitmap.height,
        options.crop_top_rows + options.height_cells,
        options.full_height_rows,
    );
    try writer.print("\x1B7\x1B[{d};{d}H\x1BP0;1;0q", .{
        options.y + 1,
        options.x + 1,
    });
    try writer.print("\"1;1;{d};{d}", .{ bitmap.width, crop_end - crop_start });
    try write_palette(writer);
    var band_start = crop_start;
    while (band_start < crop_end) : (band_start += 6) {
        try write_band(writer, bitmap, band_start, crop_end);
        if (band_start + 6 < crop_end) try writer.writeByte('-');
    }
    try writer.writeAll("\x1B\\\x1B8");
}

fn write_palette(writer: *std.Io.Writer) !void {
    var color: u8 = 0;
    while (color < palette_size) : (color += 1) {
        const red: u8 = if (color & 8 == 0) 0 else 100;
        const green: u8 = if (color & 4 == 0) 0 else 100;
        const blue: u8 = @intCast(@divFloor(@as(u16, color & 3) * 100, 3));
        try writer.print("#{d};2;{d};{d};{d}", .{ color, red, green, blue });
    }
}

fn write_band(
    writer: *std.Io.Writer,
    bitmap: Bitmap,
    band_start: u16,
    crop_end: u16,
) !void {
    std.debug.assert(bitmap.width > 0);
    std.debug.assert(band_start < bitmap.height or bitmap.height == 0);
    var color: u8 = 0;
    while (color < palette_size) : (color += 1) {
        try writer.print("#{d}", .{color});
        var run_value: u8 = 0;
        var run_length: u16 = 0;
        var x: u16 = 0;
        while (x < bitmap.width) : (x += 1) {
            const value = sixel_value(bitmap, x, band_start, crop_end, color);
            if (run_length > 0 and value != run_value) {
                try write_run(writer, run_value, run_length);
                run_length = 0;
            }
            run_value = value;
            run_length += 1;
        }
        try write_run(writer, run_value, run_length);
        if (color + 1 < palette_size) try writer.writeByte('$');
    }
}

fn sixel_value(
    bitmap: Bitmap,
    x: u16,
    band_start: u16,
    crop_end: u16,
    color: u8,
) u8 {
    std.debug.assert(x < bitmap.width or bitmap.width == 0);
    std.debug.assert(color < palette_size);
    var bits: u8 = 0;
    var offset: u8 = 0;
    while (offset < 6) : (offset += 1) {
        const y = band_start + offset;
        if (y < crop_end and bitmap.color(x, y) == color) {
            bits |= @as(u8, 1) << @intCast(offset);
        }
    }
    return bits + 63;
}

fn write_run(writer: *std.Io.Writer, value: u8, length: u16) !void {
    if (length >= 4) {
        try writer.print("!{d}{c}", .{ length, value });
        return;
    }
    var index: u16 = 0;
    while (index < length) : (index += 1) try writer.writeByte(value);
}

fn scaled_row(image_height: u16, row: u16, full_height: u16) u16 {
    std.debug.assert(full_height > 0);
    return @intCast(
        @divFloor(@as(u32, image_height) * row, full_height),
    );
}

test "Sixel bitmap parser accepts top-down 24-bit data" {
    var bytes: [70]u8 = @splat(0);
    @memcpy(bytes[0..2], "BM");
    std.mem.writeInt(u32, bytes[10..14], 54, .little);
    std.mem.writeInt(i32, bytes[18..22], 2, .little);
    std.mem.writeInt(i32, bytes[22..26], -2, .little);
    std.mem.writeInt(u16, bytes[28..30], 24, .little);
    const bitmap = try parse_bitmap(&bytes, 2, 2);
    try std.testing.expect(bitmap.top_down);
    try std.testing.expectEqual(@as(u32, 8), bitmap.row_stride);
}
