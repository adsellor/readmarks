const std = @import("std");

pub const canvas_width_max: u16 = 512;
pub const canvas_height_max: u16 = 512;
pub const canvas_pixels_max: u32 =
    @as(u32, canvas_width_max) * canvas_height_max;
pub const terminal_rows_max: u16 = @divFloor(canvas_height_max + 1, 2);
pub const text_positions_max: u32 =
    @as(u32, canvas_width_max) * terminal_rows_max;
pub const frame_rate_hz_max: u16 = 1_000;
pub const frame_rate_hz_min: u16 = 1;
pub const input_keys_max: u8 = 64;
pub const image_path_bytes_max: u16 = 1_024;
pub const image_path_encoded_bytes_max: u16 =
    @divFloor(image_path_bytes_max + 2, 3) * 4;
pub const image_file_bytes_max: u32 = 4 * 1_024 * 1_024;
pub const image_chunk_bytes: u16 = 3_072;
pub const image_chunk_encoded_bytes: u16 =
    @divFloor(image_chunk_bytes + 2, 3) * 4;
pub const image_chunk_output_bytes_max: u16 = image_chunk_encoded_bytes + 256;
pub const sixel_bitmap_bytes_max: u32 = 2 * 1_024 * 1_024;
pub const sixel_output_bytes_max: u32 = 2 * 1_024 * 1_024;
pub const web_rects_max: u16 = 512;
pub const text_bytes_max: u16 = 512;
pub const text_entries_max: u16 = 1_024;
pub const selection_regions_max: u8 = 16;
pub const selection_bytes_max: u32 =
    text_positions_max + terminal_rows_max - 1;
pub const selection_encoded_bytes_max: u32 =
    @divFloor(selection_bytes_max + 2, 3) * 4;
pub const output_bytes_max: u32 =
    canvas_pixels_max / 2 * 64 +
    @as(u32, text_entries_max) * 640 +
    64;

comptime {
    std.debug.assert(canvas_width_max > 0);
    std.debug.assert(canvas_height_max > 0);
    std.debug.assert(canvas_pixels_max > canvas_width_max);
    std.debug.assert(frame_rate_hz_min > 0);
    std.debug.assert(frame_rate_hz_min <= frame_rate_hz_max);
    std.debug.assert(input_keys_max > 0);
    std.debug.assert(image_path_encoded_bytes_max > image_path_bytes_max);
    std.debug.assert(image_chunk_encoded_bytes == 4_096);
    std.debug.assert(image_chunk_output_bytes_max > image_chunk_encoded_bytes);
    std.debug.assert(image_file_bytes_max > image_chunk_output_bytes_max);
    std.debug.assert(sixel_bitmap_bytes_max < image_file_bytes_max);
    std.debug.assert(sixel_output_bytes_max < image_file_bytes_max);
    std.debug.assert(text_bytes_max <= canvas_width_max);
    std.debug.assert(text_entries_max < std.math.maxInt(u16));
    std.debug.assert(text_positions_max >= text_entries_max);
    std.debug.assert(web_rects_max > 0);
    std.debug.assert(selection_regions_max > 0);
    std.debug.assert(selection_bytes_max >= text_bytes_max);
    std.debug.assert(selection_encoded_bytes_max > selection_bytes_max);
    std.debug.assert(output_bytes_max > canvas_pixels_max);
}
