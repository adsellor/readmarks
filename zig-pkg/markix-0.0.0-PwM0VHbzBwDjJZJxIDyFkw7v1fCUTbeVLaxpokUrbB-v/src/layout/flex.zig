const std = @import("std");
const limits = @import("../utils/limits.zig");
const Rect = @import("rect.zig").Rect;

pub const Direction = enum { row, column };

pub const Track = union(enum) {
    cells: u16,
    fraction: u16,
};

pub fn layout(
    container: Rect,
    direction: Direction,
    gap: u16,
    tracks: []const Track,
    output: []Rect,
) !void {
    if (tracks.len == 0) return error.NoTracks;
    if (tracks.len > limits.layout_items_max) return error.TooManyTracks;
    std.debug.assert(tracks.len > 0);
    std.debug.assert(output.len >= tracks.len);
    if (output.len < tracks.len) return error.OutputTooSmall;
    const available = axis_size(container, direction);
    const gap_total = @as(u32, gap) * @as(u32, @intCast(tracks.len - 1));
    const content_size = @as(u32, available) -| gap_total;

    var fixed_total: u32 = 0;
    var weight_total: u32 = 0;
    for (tracks) |track| switch (track) {
        .cells => |size| fixed_total += size,
        .fraction => |weight| {
            if (weight == 0) return error.ZeroFraction;
            weight_total += weight;
        },
    };
    const flexible_size = content_size -| fixed_total;
    var cursor = axis_start(container, direction);
    var fraction_used: u32 = 0;
    for (tracks, 0..) |track, index| {
        const requested = track_size(track, flexible_size, weight_total, &fraction_used);
        const end = axis_start(container, direction) +| available;
        const size = @min(requested, end -| cursor);
        output[index] = axis_rect(container, direction, cursor, size);
        cursor +|= size +| gap;
    }
}

fn track_size(
    track: Track,
    flexible_size: u32,
    weight_total: u32,
    fraction_used: *u32,
) u16 {
    std.debug.assert(fraction_used.* <= flexible_size);
    std.debug.assert(weight_total > 0 or track == .cells);
    return switch (track) {
        .cells => |size| size,
        .fraction => |weight| result: {
            const end = flexible_size * (fraction_used.* + weight) / weight_total;
            const start = flexible_size * fraction_used.* / weight_total;
            fraction_used.* += weight;
            break :result @intCast(end - start);
        },
    };
}

fn axis_size(rect: Rect, direction: Direction) u16 {
    return if (direction == .row) rect.width else rect.height;
}

fn axis_start(rect: Rect, direction: Direction) u16 {
    return if (direction == .row) rect.x else rect.y;
}

fn axis_rect(
    container: Rect,
    direction: Direction,
    start: u16,
    size: u16,
) Rect {
    if (direction == .row) {
        return Rect.init(start, container.y, size, container.height);
    }
    return Rect.init(container.x, start, container.width, size);
}

test "flex distributes remainder without losing cells" {
    var output: [3]Rect = undefined;
    try layout(
        Rect.init(0, 0, 20, 4),
        .row,
        1,
        &.{ .{ .cells = 4 }, .{ .fraction = 1 }, .{ .fraction = 2 } },
        &output,
    );
    try std.testing.expectEqual(@as(u16, 4), output[0].width);
    try std.testing.expectEqual(@as(u16, 4), output[1].width);
    try std.testing.expectEqual(@as(u16, 10), output[2].width);
    try std.testing.expectEqual(@as(u16, 20), output[2].right());
}

test "flex bounds impossible fixed tracks" {
    var output: [2]Rect = undefined;
    try layout(
        Rect.init(0, 0, 3, 1),
        .row,
        1,
        &.{ .{ .cells = 4 }, .{ .fraction = 1 } },
        &output,
    );
    try std.testing.expectEqual(@as(u16, 3), output[0].width);
    try std.testing.expectEqual(@as(u16, 0), output[1].width);
}
