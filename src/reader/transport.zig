const std = @import("std");
const builtin = @import("builtin");
const limits = @import("limits.zig");
const parser = @import("parser.zig");

pub const Backend = enum { native, web };

/// The feed fetch backend this build uses. Web builds route requests
/// through browser `fetch()` (async, non-UI-blocking); native builds use
/// `std.http.Client`. The application dispatches on this value at
/// comptime, so the unused backend is stripped from the binary.
pub const backend: Backend = if (builtin.target.cpu.arch.isWasm()) .web else .native;

extern "env" fn js_fetch_request(url: [*]const u8, url_len: usize, request_id: u32) void;

pub const Request = struct {
    feed_index: u16 = 0,
    active: bool = false,
};

/// Per-worker scratch for the web backend. `start` kicks off an
/// asynchronous browser fetch and returns immediately; `deliver` is
/// called from the JS glue when the response bytes are available and
/// parses them into an owned `parser.Update`.
pub const Transport = struct {
    requests: [limits.feed_fetch_concurrency]Request = @splat(.{}),
    buffers: [limits.feed_fetch_concurrency][limits.feed_response_bytes_max]u8 = undefined,

    pub fn start(self: *Transport, worker_index: u16, feed_index: u16, url: []const u8) void {
        const request = &self.requests[worker_index];
        request.feed_index = feed_index;
        request.active = true;
        js_fetch_request(url.ptr, url.len, worker_index);
    }

    pub fn deliver(
        self: *Transport,
        worker_index: u16,
        status: i32,
        data: []const u8,
    ) !parser.Update {
        const request = &self.requests[worker_index];
        request.active = false;
        if (status < 200 or status >= 400) return error.FeedRequestFailed;
        const buffer = &self.buffers[worker_index];
        const length = @min(data.len, buffer.len);
        @memcpy(buffer[0..length], data[0..length]);
        return parser.parse(buffer[0..length], request.feed_index);
    }
};
