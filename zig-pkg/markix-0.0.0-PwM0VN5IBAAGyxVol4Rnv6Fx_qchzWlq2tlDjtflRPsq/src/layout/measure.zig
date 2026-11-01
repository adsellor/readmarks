const std = @import("std");
const layout = @import("resolve.zig");

pub fn columns(value: []const u8) i32 {
    var count: i32 = 0;
    for (value) |byte| {
        if (byte & 0xc0 != 0x80) count += 1;
    }
    return count;
}

pub fn monospace(
    runs: *layout.TextIterator,
    wrap: bool,
    available: i32,
    context: ?*anyopaque,
) layout.Size {
    _ = context;
    std.debug.assert(available >= 0);
    if (!wrap) return literal(runs);

    var rows: i32 = 1;
    var column: i32 = 0;
    var widest: i32 = 0;
    var pending: i32 = 0;
    std.debug.assert(rows == 1);

    while (runs.next()) |run| {
        var index: usize = 0;
        var word_start: usize = 0;
        while (index <= run.len) : (index += 1) {
            const at_end = index == run.len;
            if (!at_end and run[index] != ' ' and run[index] != '\n') continue;
            pending += columns(run[word_start..index]);
            if (at_end) {
                word_start = index;
                break;
            }
            place_word(pending, available, &rows, &column, &widest);
            pending = 0;
            if (run[index] == '\n') {
                widest = @max(widest, column);
                rows += 1;
                column = 0;
            }
            word_start = index + 1;
        }
    }
    if (pending > 0) place_word(pending, available, &rows, &column, &widest);
    widest = @max(widest, column);
    if (available == layout.unbounded) return .{ .width = widest, .height = rows };
    return .{ .width = @min(widest, available), .height = rows };
}

fn place_word(
    word: i32,
    available: i32,
    rows: *i32,
    column: *i32,
    widest: *i32,
) void {
    std.debug.assert(word >= 0);
    std.debug.assert(available >= 0);
    if (word == 0) {
        if (column.* > 0) column.* += 1;
        return;
    }
    if (available == layout.unbounded) {
        column.* += if (column.* == 0) word else word + 1;
        return;
    }
    var size = word;
    if (size > available and available > 0) {
        if (column.* > 0) {
            widest.* = @max(widest.*, column.*);
            rows.* += 1;
            column.* = 0;
        }
        while (size > available) {
            rows.* += 1;
            size -= available;
        }
        widest.* = available;
        column.* = size;
        return;
    }
    const needed = if (column.* == 0) size else column.* + 1 + size;
    if (available > 0 and needed > available) {
        widest.* = @max(widest.*, column.*);
        rows.* += 1;
        column.* = size;
    } else {
        column.* = needed;
    }
}

fn literal(runs: *layout.TextIterator) layout.Size {
    var rows: i32 = 1;
    var widest: i32 = 0;
    var column: i32 = 0;
    std.debug.assert(rows == 1);
    std.debug.assert(column == 0);
    while (runs.next()) |run| {
        var lines = std.mem.splitScalar(u8, run, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) {
                widest = @max(widest, column);
                column = 0;
                rows += 1;
            }
            first = false;
            column += columns(line);
        }
    }
    widest = @max(widest, column);
    return .{ .width = widest, .height = rows };
}

test "a multi-byte character counts one column" {
    try std.testing.expectEqual(@as(i32, 3), columns("\u{00e9}\u{00e8}e"));
    try std.testing.expectEqual(@as(i32, 5), columns("plain"));
}
