const std = @import("std");
const limits = @import("../terminal/limits.zig");

// Binary frame format shared between the Zig web backend and the
// JavaScript renderer. All values are little-endian.
//
// The WASM entry writes one frame into a buffer shared with JS. JS
// reads the header with a DataView and lays out the background color,
// filled rects, text entries, selection regions and images as real DOM
// elements in order.
//
//   Frame:
//     header               60 bytes
//     rects                count * 12 bytes (x, y, width, height, rgba)
//     text entries         count * (20 + text_length) bytes
//     selection regions    count * 16 bytes
//     images               count * (20 + path_length) bytes

pub const magic: u32 = 0x4D524B57; // "WMRK" as little-endian bytes
pub const version: u32 = 2;

pub const header_size: u32 = 60;

pub const Header = struct {
    magic: u32,
    version: u32,
    width: u32,
    height: u32,
    rows: u32,
    background: u32,
    rect_offset: u32,
    rect_count: u32,
    text_offset: u32,
    text_count: u32,
    selection_offset: u32,
    selection_count: u32,
    image_offset: u32,
    image_count: u32,
    frame_length: u32,
};

// a filled rect is 12 bytes, in terminal rows/columns:
//   u16 x
//   u16 y
//   u16 width
//   u16 height
//   u32 color            (rgba)

pub const rect_size: u32 = 12;

// attribute bits for a text entry
pub const attrs_bold: u8 = 1;
pub const attrs_dim: u8 = 2;
pub const attrs_underline: u8 = 4;

pub const text_entry_header_size: u32 = 20;
// a text entry is 20 bytes of header followed by text_length utf8 bytes:
//   u16 x                (columns)
//   u16 y                (rows)
//   u16 length           (utf8 bytes)
//   u16 padding
//   u32 foreground       (rgba)
//   u32 background       (rgba, 0 = none)
//   u8  attributes       (attrs_* bits)
//   u8  padding
//   u16 padding
//   u8  text[length]

pub const selection_size: u32 = 24;
// a selection region is 24 bytes:
//   u16 x                (columns)
//   u16 y                (rows)
//   u16 width            (columns)
//   u16 height           (rows)
//   u32 background       (rgba, active or plain)
//   u32 foreground       (rgba, text color over the selection)
//   u32 padding
//   u32 padding

pub const image_header_size: u32 = 20;
// an image placement is 20 bytes followed by path_length utf8 bytes:
//   u16 x                (columns)
//   u16 y                (rows)
//   u16 width            (columns)
//   u16 height           (rows)
//   u16 crop_top_rows
//   u16 full_height_rows
//   u16 path_length
//   u16 padding
//   u32 id
//   u8  path[path_length]

pub const frame_bytes_max: usize = @sizeOf(Header) +
    limits.web_rects_max * rect_size +
    limits.text_entries_max * (text_entry_header_size + limits.text_bytes_max) +
    limits.selection_regions_max * selection_size +
    (image_header_size + limits.image_path_bytes_max) + 64;

/// Where each section of a frame begins, and how long the whole is.
pub const Offsets = struct {
    rect_offset: u32,
    text_offset: u32,
    selection_offset: u32,
    image_offset: u32,
    total: u32,
};

pub fn layout(
    rect_count: usize,
    text_count: usize,
    selection_count: usize,
    image_count: usize,
) Offsets {
    std.debug.assert(rect_count <= limits.web_rects_max);
    std.debug.assert(text_count <= limits.text_entries_max);
    const rect_offset = @as(u32, header_size);
    const text_offset = rect_offset +
        @as(u32, @intCast(rect_count * rect_size));
    const selection_offset = text_offset +
        @as(u32, @intCast(text_count * (text_entry_header_size + limits.text_bytes_max)));
    const image_offset = selection_offset +
        @as(u32, @intCast(selection_count * selection_size));
    const total = image_offset +
        @as(u32, @intCast(image_count * (image_header_size + limits.image_path_bytes_max)));
    return .{
        .rect_offset = rect_offset,
        .text_offset = text_offset,
        .selection_offset = selection_offset,
        .image_offset = image_offset,
        .total = total,
    };
}

pub const Writer = struct {
    bytes: []u8,
    index: usize = 0,

    pub fn write_u8(self: *Writer, value: u8) !void {
        if (self.index >= self.bytes.len) return error.BufferTooSmall;
        self.bytes[self.index] = value;
        self.index += 1;
    }

    pub fn write_u16(self: *Writer, value: u16) !void {
        if (self.bytes.len - self.index < 2) return error.BufferTooSmall;
        std.mem.writeInt(u16, self.bytes[self.index..][0..2], value, .little);
        self.index += 2;
    }

    pub fn write_u32(self: *Writer, value: u32) !void {
        if (self.bytes.len - self.index < 4) return error.BufferTooSmall;
        std.mem.writeInt(u32, self.bytes[self.index..][0..4], value, .little);
        self.index += 4;
    }

    pub fn write_rgba(self: *Writer, red: u8, green: u8, blue: u8, alpha: u8) !void {
        try self.write_u32((@as(u32, alpha) << 24) |
            (@as(u32, blue) << 16) |
            (@as(u32, green) << 8) |
            @as(u32, red));
    }

    pub fn write_bytes(self: *Writer, value: []const u8) !void {
        if (self.bytes.len - self.index < value.len) return error.BufferTooSmall;
        @memcpy(self.bytes[self.index..][0..value.len], value);
        self.index += value.len;
    }
};

pub const Reader = struct {
    bytes: []const u8,
    index: usize = 0,

    pub fn read_u8(self: *Reader) !u8 {
        if (self.index >= self.bytes.len) return error.Truncated;
        const value = self.bytes[self.index];
        self.index += 1;
        return value;
    }

    pub fn read_u16(self: *Reader) !u16 {
        if (self.bytes.len - self.index < 2) return error.Truncated;
        const value = std.mem.readInt(u16, self.bytes[self.index..][0..2], .little);
        self.index += 2;
        return value;
    }

    pub fn read_u32(self: *Reader) !u32 {
        if (self.bytes.len - self.index < 4) return error.Truncated;
        const value = std.mem.readInt(u32, self.bytes[self.index..][0..4], .little);
        self.index += 4;
        return value;
    }

    pub fn read_bytes(self: *Reader, length: usize) ![]const u8 {
        if (self.bytes.len - self.index < length) return error.Truncated;
        const value = self.bytes[self.index .. self.index + length];
        self.index += length;
        return value;
    }
};

test "writer and reader round trip a header" {
    var buffer: [256]u8 = undefined;
    var writer = Writer{ .bytes = &buffer };
    try writer.write_u32(magic);
    try writer.write_u32(version);
    try writer.write_u32(100);
    try writer.write_u32(200);
    var reader = Reader{ .bytes = buffer[0..writer.index] };
    try std.testing.expectEqual(magic, try reader.read_u32());
    try std.testing.expectEqual(version, try reader.read_u32());
    try std.testing.expectEqual(@as(u32, 100), try reader.read_u32());
    try std.testing.expectEqual(@as(u32, 200), try reader.read_u32());
}

test "layout grows past the rect section" {
    const positions = layout(4, 8, 2, 1);
    try std.testing.expectEqual(@as(u32, header_size), positions.rect_offset);
    try std.testing.expectEqual(
        @as(u32, @intCast(header_size + 4 * rect_size)),
        positions.text_offset,
    );
    try std.testing.expect(positions.selection_offset > positions.text_offset);
    try std.testing.expect(positions.image_offset > positions.selection_offset);
    try std.testing.expect(positions.total > positions.image_offset);
}

test "writer fails on a too small buffer" {
    var buffer: [4]u8 = undefined;
    var writer = Writer{ .bytes = &buffer };
    try writer.write_u32(1);
    try std.testing.expectError(error.BufferTooSmall, writer.write_u8(2));
}
