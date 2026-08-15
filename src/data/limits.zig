const std = @import("std");

pub const bookmark_count_max: u16 = 512;
pub const bookmark_notes_bytes_max: u16 = 384;
pub const bookmark_description_bytes_max: u16 = 256;
pub const bookmark_preview_bytes_max: u16 = 1_024;
pub const bookmark_tags_bytes_max: u16 = 96;
pub const bookmark_title_bytes_max: u16 = 96;
pub const bookmark_url_bytes_max: u16 = 512;
pub const command_action_count_max: u16 = 8;
pub const command_result_count_max: u16 =
    bookmark_count_max + tag_count_max + command_action_count_max;
pub const path_bytes_max: u16 = 1_024;
pub const page_response_bytes_max: u32 = 256 * 1_024;
pub const search_bytes_max: u16 = 128;
pub const storage_bytes_max: u32 = 2 * 1_024 * 1_024;
pub const tag_count_max: u16 = 512;
pub const tag_name_bytes_max: u16 = 32;

comptime {
    std.debug.assert(bookmark_count_max > 0);
    std.debug.assert(bookmark_title_bytes_max > 0);
    std.debug.assert(bookmark_url_bytes_max > bookmark_title_bytes_max);
    std.debug.assert(command_action_count_max > 0);
    std.debug.assert(command_result_count_max > bookmark_count_max);
    std.debug.assert(bookmark_preview_bytes_max > bookmark_notes_bytes_max);
    std.debug.assert(page_response_bytes_max > bookmark_preview_bytes_max);
    std.debug.assert(storage_bytes_max > bookmark_url_bytes_max);
    std.debug.assert(tag_count_max <= bookmark_count_max);
}
