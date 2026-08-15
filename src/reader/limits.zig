const std = @import("std");

pub const article_count_max: u16 = 2_048;
pub const article_content_bytes_max: u16 = 32 * 1_024;
pub const article_image_url_bytes_max: u16 = 512;
pub const article_summary_bytes_max: u16 = 1_536;
pub const article_title_bytes_max: u16 = 192;
pub const article_url_bytes_max: u16 = 512;
pub const category_count_max: u16 = 64;
pub const category_name_bytes_max: u16 = 48;
pub const cache_bytes_max: u32 = 80 * 1_024 * 1_024;
pub const cache_fresh_seconds: u32 = 30 * 60;
pub const feed_articles_per_update_max: u16 = 32;
pub const feed_count_max: u16 = 256;
pub const feed_fetch_concurrency: u16 = 4;
pub const feed_response_bytes_max: u32 = 512 * 1_024;
pub const feed_title_bytes_max: u16 = 128;
pub const image_response_bytes_max: u32 = 4 * 1_024 * 1_024;
pub const image_cache_slots_max: u8 = 64;
pub const article_page_response_bytes_max: u32 = 1 * 1_024 * 1_024;
pub const path_bytes_max: u16 = 1_024;
pub const published_bytes_max: u16 = 48;
pub const read_count_max: u16 = 8_192;
pub const search_bytes_max: u16 = 128;
pub const state_bytes_max: u32 = 128 * 1_024;

comptime {
    std.debug.assert(article_count_max > feed_articles_per_update_max);
    std.debug.assert(article_content_bytes_max > article_summary_bytes_max);
    std.debug.assert(article_image_url_bytes_max == article_url_bytes_max);
    std.debug.assert(article_summary_bytes_max > article_title_bytes_max);
    std.debug.assert(article_url_bytes_max > article_title_bytes_max);
    std.debug.assert(category_count_max < feed_count_max);
    std.debug.assert(cache_bytes_max > feed_response_bytes_max);
    std.debug.assert(cache_fresh_seconds > 0);
    std.debug.assert(feed_count_max > 0);
    std.debug.assert(feed_fetch_concurrency > 1);
    std.debug.assert(feed_fetch_concurrency < feed_count_max);
    std.debug.assert(feed_response_bytes_max > article_summary_bytes_max);
    std.debug.assert(image_response_bytes_max > feed_response_bytes_max);
    std.debug.assert(article_page_response_bytes_max > feed_response_bytes_max);
    std.debug.assert(image_cache_slots_max > feed_fetch_concurrency);
    std.debug.assert(read_count_max > article_count_max);
}
