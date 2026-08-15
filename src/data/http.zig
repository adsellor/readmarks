const std = @import("std");

/// One-shot HTTP GET into a writer.
///
/// This is `std.http.Client.fetch` with one difference, and it exists for that
/// difference: std ends a failed body read with `response.bodyErr().?`, and a
/// read cancelled out from under the client never records a body error. So
/// cancelling a fetch -- which is exactly what quitting the application does to
/// every in-flight feed, page and image request -- panics inside std instead of
/// returning. Here the failure comes back as an error the caller can record.
pub const Result = struct {
    status: std.http.Status,
};

pub const Options = struct {
    url: []const u8,
    /// Where the response body is written. A fixed writer bounds the response.
    response_writer: *std.Io.Writer,
    /// Storage for redirected locations; must outlive the request.
    redirect_buffer: []u8,
    user_agent: []const u8,
    /// Redirects followed before the request gives up.
    redirect_limit: u16 = 3,
};

pub fn fetch(client: *std.http.Client, options: Options) !Result {
    std.debug.assert(options.redirect_buffer.len > 0);
    const uri = try std.Uri.parse(options.url);
    var request = try client.request(.GET, uri, .{
        .redirect_behavior = .init(options.redirect_limit),
        .headers = .{ .user_agent = .{ .override = options.user_agent } },
    });
    defer request.deinit();
    try request.sendBodiless();

    var response = try request.receiveHead(options.redirect_buffer);
    const window = try decompression_window(client, response.head.content_encoding);
    defer if (window.len > 0) client.allocator.free(window);
    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, window);
    _ = reader.streamRemaining(options.response_writer) catch |err| switch (err) {
        // The body's own error when it has one, and a plain failure when the
        // read was cancelled and there is nothing to report but that.
        error.ReadFailed => return response.bodyErr() orelse error.FetchFailed,
        else => |e| return e,
    };
    return .{ .status = response.head.status };
}

/// Scratch space the decoder needs, sized by the encoding the server chose.
/// Allocated rather than held per fetcher: a zstd window is megabytes, and a
/// response that needs one is the exception.
fn decompression_window(
    client: *std.http.Client,
    encoding: std.http.ContentEncoding,
) ![]u8 {
    return switch (encoding) {
        .identity => &.{},
        .zstd => try client.allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try client.allocator.alloc(
            u8,
            std.compress.flate.max_window_len,
        ),
        .compress => error.UnsupportedCompressionMethod,
    };
}
