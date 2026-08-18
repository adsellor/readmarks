const std = @import("std");

pub const article_count_max: u16 = 2_048;
pub const article_content_bytes_max: u16 = 32 * 1_024;
pub const article_image_url_bytes_max: u16 = 512;
/// One reader page. It matches the content ceiling because the article's own
/// field is page one: every page is the same size wherever it is kept.
pub const article_page_bytes_max: u16 = article_content_bytes_max;
/// Blocks a page is cut at. The document parser stops at 255 blocks, so a
/// page that stays under this renders to its last word rather than to the
/// parser's ceiling.
pub const article_page_blocks_max: u16 = 192;
/// Pages past the first, pooled across every article. A page an article
/// cannot claim is a page it does not show, so a full pool costs an old
/// article its tail and never costs a fetch.
pub const article_page_slots_max: u16 = 256;
/// Pages one article may hold, its first included.
pub const article_pages_max: u16 = feed_update_page_slots_max + 1;
pub const article_summary_bytes_max: u16 = 1_536;
pub const article_title_bytes_max: u16 = 192;
pub const article_url_bytes_max: u16 = 512;
pub const category_count_max: u16 = 64;
pub const category_name_bytes_max: u16 = 48;
pub const cache_bytes_max: u32 = 96 * 1_024 * 1_024;
pub const cache_fresh_seconds: u32 = 30 * 60;
pub const feed_articles_per_update_max: u16 = 32;
pub const feed_count_max: u16 = 256;
pub const feed_fetch_concurrency: u16 = 4;
pub const feed_response_bytes_max: u32 = 512 * 1_024;
pub const feed_title_bytes_max: u16 = 128;
/// Pages one feed update may stage before its articles are merged. A whole
/// response cannot hold more text than this, so nothing a feed sends is ever
/// dropped for want of a staging slot.
pub const feed_update_page_slots_max: u16 = 16;
pub const image_response_bytes_max: u32 = 4 * 1_024 * 1_024;
pub const image_cache_slots_max: u8 = 64;
pub const article_page_response_bytes_max: u32 = 1 * 1_024 * 1_024;
pub const path_bytes_max: u16 = 1_024;
pub const published_bytes_max: u16 = 48;
pub const read_count_max: u16 = 8_192;
pub const search_bytes_max: u16 = 128;
pub const state_bytes_max: u32 = 128 * 1_024;
pub const command_action_count_max: u16 = 16;
pub const command_result_count_max: u16 =
    article_count_max + feed_count_max + category_count_max + command_action_count_max;

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
    std.debug.assert(command_action_count_max > 0);
    std.debug.assert(command_result_count_max > article_count_max);
    // Staging holds a whole response, so pagination never loses a byte a feed
    // actually sent -- only the pool an article competes in can.
    std.debug.assert(
        @as(u32, feed_update_page_slots_max) * article_page_bytes_max >=
            feed_response_bytes_max,
    );
    std.debug.assert(article_page_slots_max > feed_update_page_slots_max);
    std.debug.assert(article_pages_max > 1);
    std.debug.assert(article_page_blocks_max > 0);
    // The cache writes every article and every pooled page into one buffer, so
    // a full library has to fit in it or a save fails on the day it matters.
    const article_encoded_bytes_max: u32 = article_content_bytes_max +
        article_summary_bytes_max + article_title_bytes_max + article_url_bytes_max +
        article_image_url_bytes_max + published_bytes_max + 64;
    std.debug.assert(
        cache_bytes_max >
            @as(u32, article_count_max) * article_encoded_bytes_max +
                @as(u32, article_page_slots_max) * (article_page_bytes_max + 8),
    );
}
