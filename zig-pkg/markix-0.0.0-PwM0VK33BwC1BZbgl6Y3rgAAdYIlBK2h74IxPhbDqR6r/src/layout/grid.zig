const std = @import("std");
const flex = @import("flex.zig");
const Rect = @import("rect.zig").Rect;

pub fn layout(
    container: Rect,
    column_gap: u16,
    row_gap: u16,
    columns: []const flex.Track,
    rows: []const flex.Track,
    output: []Rect,
) !void {
    const cell_count = std.math.mul(usize, columns.len, rows.len) catch
        return error.TooManyCells;
    if (output.len < cell_count) return error.OutputTooSmall;
    std.debug.assert(cell_count == columns.len * rows.len);
    std.debug.assert(output.len >= cell_count);
    var column_rects: [16]Rect = undefined;
    var row_rects: [16]Rect = undefined;
    try flex.layout(container, .row, column_gap, columns, &column_rects);
    try flex.layout(container, .column, row_gap, rows, &row_rects);

    var row_index: usize = 0;
    while (row_index < rows.len) : (row_index += 1) {
        var column_index: usize = 0;
        while (column_index < columns.len) : (column_index += 1) {
            const index = row_index * columns.len + column_index;
            output[index] = Rect.init(
                column_rects[column_index].x,
                row_rects[row_index].y,
                column_rects[column_index].width,
                row_rects[row_index].height,
            );
        }
    }
}

test "grid produces row-major cells" {
    var output: [4]Rect = undefined;
    try layout(
        Rect.init(0, 0, 20, 10),
        2,
        1,
        &.{ .{ .fraction = 1 }, .{ .fraction = 1 } },
        &.{ .{ .cells = 2 }, .{ .fraction = 1 } },
        &output,
    );
    try std.testing.expectEqual(Rect.init(0, 0, 9, 2), output[0]);
    try std.testing.expectEqual(Rect.init(11, 0, 9, 2), output[1]);
    try std.testing.expectEqual(Rect.init(0, 3, 9, 7), output[2]);
    try std.testing.expectEqual(Rect.init(11, 3, 9, 7), output[3]);
}
