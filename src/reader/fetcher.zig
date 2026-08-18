const std = @import("std");
const http = @import("data").http;
const limits = @import("limits.zig");
const parser = @import("parser.zig");

pub fn prepare_tls(client: *std.http.Client) !void {
    if (std.http.Client.disable_tls) return;
    if (client.now != null) return;
    std.debug.assert(client.connection_pool.used.first == null);
    std.debug.assert(client.connection_pool.free.first == null);

    // Initialize certificates before workers start because Zig's redirect path
    // requires the TLS clock to exist when an HTTP feed redirects to HTTPS.
    const now = std.Io.Clock.real.now(client.io);
    var bundle: std.crypto.Certificate.Bundle = .empty;
    errdefer bundle.deinit(client.allocator);
    try bundle.rescan(client.allocator, client.io, now);
    client.now = now;
    std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
    bundle.deinit(client.allocator);
    std.debug.assert(client.now != null);
}

pub const Fetcher = struct {
    response: [limits.feed_response_bytes_max]u8 = undefined,
    redirect_buffer: [8 * 1_024]u8 = undefined,

    pub fn fetch(
        self: *Fetcher,
        client: *std.http.Client,
        url: []const u8,
        feed_index: u16,
        staged: *parser.StagedPages,
    ) !parser.Update {
        if (std.mem.startsWith(u8, url, "file://")) {
            return self.fetch_file(client.io, url["file://".len..], feed_index, staged);
        }
        if (!std.mem.startsWith(u8, url, "http://") and
            !std.mem.startsWith(u8, url, "https://"))
        {
            return error.UnsupportedFeedScheme;
        }
        var writer = std.Io.Writer.fixed(&self.response);
        const result = try http.fetch(client, .{
            .url = url,
            .response_writer = &writer,
            .redirect_buffer = &self.redirect_buffer,
            .user_agent = "markix-rss/0.1",
        });
        if (result.status.class() != .success) return error.FeedRequestFailed;
        return parser.parse(writer.buffered(), feed_index, staged);
    }

    fn fetch_file(
        self: *Fetcher,
        io: std.Io,
        path: []const u8,
        feed_index: u16,
        staged: *parser.StagedPages,
    ) !parser.Update {
        const bytes = try @import("data").cwd().readFile(io, path, &self.response);
        if (bytes.len == self.response.len) return error.FeedResponseTooLarge;
        return parser.parse(bytes, feed_index, staged);
    }
};
