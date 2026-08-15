const std = @import("std");
const limits = @import("limits.zig");
const Color = @import("../../style/color.zig").Color;
const Pointer = @import("../../utils/input.zig").Pointer;
const Rect = @import("../../layout/rect.zig").Rect;
const TextSelectionStyle = @import("../../style/style.zig").TextSelectionStyle;
const TextEntry = @import("text_entry.zig").TextEntry;

const Allocator = std.mem.Allocator;
const cell_empty = std.math.maxInt(u16);

pub const Action = enum {
    ignored,
    redraw,
    copy,
};

const Point = struct {
    x: u16,
    y: u16,
};

const Region = struct {
    rect: Rect,
    style: TextSelectionStyle,
};

const Selection = struct {
    region: Region,
    anchor: Point,
    cursor: Point,
    dragging: bool,
    moved: bool,
};

pub const CellStyle = struct {
    foreground: Color,
    background: Color,
    bold: bool,
};

pub const Engine = struct {
    allocator: Allocator,
    regions: [limits.selection_regions_max]Region = undefined,
    regions_count: u8 = 0,
    pending_regions: [limits.selection_regions_max]Region = undefined,
    pending_regions_count: u8 = 0,
    selection: ?Selection = null,
    rendered_selection: ?Selection = null,
    text_cells: []u16,
    text_buffer: []u8,
    encoded_buffer: []u8,

    pub fn init(allocator: Allocator) !Engine {
        std.debug.assert(limits.selection_regions_max > 0);
        std.debug.assert(limits.selection_regions_max <= std.math.maxInt(u8));
        const text_cells = try allocator.alloc(u16, limits.text_positions_max);
        errdefer allocator.free(text_cells);
        const text_buffer = try allocator.alloc(u8, limits.selection_bytes_max);
        errdefer allocator.free(text_buffer);
        const encoded_buffer = try allocator.alloc(
            u8,
            limits.selection_encoded_bytes_max,
        );
        errdefer allocator.free(encoded_buffer);
        @memset(text_cells, cell_empty);
        return .{
            .allocator = allocator,
            .text_cells = text_cells,
            .text_buffer = text_buffer,
            .encoded_buffer = encoded_buffer,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.allocator.free(self.text_cells);
        self.allocator.free(self.text_buffer);
        self.allocator.free(self.encoded_buffer);
        self.text_cells = self.text_cells[0..0];
        self.text_buffer = self.text_buffer[0..0];
        self.encoded_buffer = self.encoded_buffer[0..0];
    }

    pub fn add_region(
        self: *Engine,
        rect: Rect,
        style: TextSelectionStyle,
    ) !void {
        std.debug.assert(self.regions_count <= limits.selection_regions_max);
        std.debug.assert(rect.width > 0 or rect.height == 0);
        if (rect.width == 0 or rect.height == 0) return;
        if (self.pending_regions_count >= limits.selection_regions_max) {
            return error.TooManySelectionRegions;
        }
        self.pending_regions[self.pending_regions_count] = .{
            .rect = rect,
            .style = style,
        };
        self.pending_regions_count += 1;
    }

    pub fn handle(self: *Engine, pointer: Pointer) Action {
        return switch (pointer.action) {
            .press => self.handle_press(pointer),
            .drag => self.handle_drag(pointer),
            .release => self.handle_release(pointer),
        };
    }

    fn handle_press(self: *Engine, pointer: Pointer) Action {
        std.debug.assert(self.regions_count <= limits.selection_regions_max);
        std.debug.assert(pointer.action == .press);
        if (pointer.button != .primary) return .ignored;
        const region = self.region_at(pointer.x, pointer.y) orelse {
            if (self.selection == null) return .ignored;
            self.selection = null;
            return .redraw;
        };
        const point = Point{ .x = pointer.x, .y = pointer.y };
        self.selection = .{
            .region = region,
            .anchor = point,
            .cursor = point,
            .dragging = true,
            .moved = false,
        };
        return .redraw;
    }

    fn handle_drag(self: *Engine, pointer: Pointer) Action {
        if (pointer.button != .primary) return .ignored;
        if (self.selection) |*selected| {
            if (!selected.dragging) return .ignored;
            const point = clamp_point(selected.region.rect, pointer.x, pointer.y);
            if (std.meta.eql(point, selected.cursor)) return .ignored;
            selected.cursor = point;
            selected.moved = true;
            return .redraw;
        }
        return .ignored;
    }

    fn handle_release(self: *Engine, pointer: Pointer) Action {
        if (self.selection) |*selected| {
            if (!selected.dragging) return .ignored;
            selected.cursor = clamp_point(selected.region.rect, pointer.x, pointer.y);
            selected.dragging = false;
            if (!selected.moved) {
                self.selection = null;
                return .redraw;
            }
            return .copy;
        }
        return .ignored;
    }

    pub fn is_selected(self: *const Engine, x: u16, y: u16) bool {
        return self.cell_style(x, y) != null;
    }

    pub fn active(self: *const Engine) bool {
        return self.selection != null;
    }

    pub fn region_count(self: *const Engine) u8 {
        return self.regions_count;
    }

    pub fn region_rect(self: *const Engine, index: u8) Rect {
        return self.regions[index].rect;
    }

    pub fn region_style(self: *const Engine, index: u8) TextSelectionStyle {
        return self.regions[index].style;
    }

    pub fn cell_style(self: *const Engine, x: u16, y: u16) ?CellStyle {
        std.debug.assert(self.regions_count <= limits.selection_regions_max);
        std.debug.assert(self.pending_regions_count <= limits.selection_regions_max);
        const selected = self.selection orelse return null;
        if (!selection_contains(selected, x, y)) return null;
        const style = selected.region.style;
        if (selected.dragging and point_equals(selected.cursor, x, y)) {
            return .{
                .foreground = style.cursor_foreground,
                .background = style.cursor_background,
                .bold = true,
            };
        }
        if (selected.dragging and point_equals(selected.anchor, x, y)) {
            return .{
                .foreground = style.foreground,
                .background = style.anchor_background,
                .bold = true,
            };
        }
        return .{
            .foreground = style.foreground,
            .background = if (selected.dragging)
                style.active_background
            else
                style.background,
            .bold = false,
        };
    }

    pub fn entry_changed(self: *const Engine, entry: *const TextEntry) bool {
        if (std.meta.eql(self.selection, self.rendered_selection)) return false;
        var offset: u16 = 0;
        while (offset < entry.text_length) : (offset += 1) {
            const x = entry.x + offset;
            if (selection_contains(self.selection, x, entry.y)) return true;
            if (selection_contains(self.rendered_selection, x, entry.y)) return true;
        }
        return false;
    }

    pub fn commit(
        self: *Engine,
        entries: []const TextEntry,
        previous_entries: []const TextEntry,
    ) void {
        std.debug.assert(self.regions_count <= limits.selection_regions_max);
        std.debug.assert(self.pending_regions_count <= limits.selection_regions_max);
        update_text_cells(self.text_cells, previous_entries, cell_empty);
        update_text_cells(self.text_cells, entries, null);
        self.regions_count = self.pending_regions_count;
        @memcpy(
            self.regions[0..self.regions_count],
            self.pending_regions[0..self.pending_regions_count],
        );
        self.pending_regions_count = 0;
        self.rendered_selection = self.selection;
    }

    pub fn reset(self: *Engine) void {
        self.regions_count = 0;
        self.pending_regions_count = 0;
        self.selection = null;
        self.rendered_selection = null;
        @memset(self.text_cells, cell_empty);
    }

    pub fn write_clipboard(self: *Engine, writer: *std.Io.Writer) !bool {
        const text = self.selected_text();
        if (text.len == 0) return false;
        const encoded = std.base64.standard.Encoder.encode(
            self.encoded_buffer,
            text,
        );
        try writer.writeAll("\x1B]52;c;");
        try writer.writeAll(encoded);
        try writer.writeAll("\x07");
        return true;
    }

    fn selected_text(self: *Engine) []const u8 {
        std.debug.assert(self.pending_regions_count <= limits.selection_regions_max);
        std.debug.assert(self.regions_count <= limits.selection_regions_max);
        const selected = self.selection orelse return self.text_buffer[0..0];
        const ordered = ordered_points(selected);
        var length: usize = 0;
        var y = ordered.start.y;
        while (y <= ordered.end.y) : (y += 1) {
            const range = row_range(selected.region.rect, ordered, y);
            var row_has_text = false;
            var x = range.start;
            while (x <= range.end) : (x += 1) {
                const cell = self.text_cells[text_position_index(x, y)];
                if (cell == cell_empty) continue;
                if (!row_has_text and length > 0) {
                    self.text_buffer[length] = '\n';
                    length += 1;
                }
                self.text_buffer[length] = @intCast(cell);
                length += 1;
                row_has_text = true;
            }
        }
        std.debug.assert(length <= limits.selection_bytes_max);
        return self.text_buffer[0..length];
    }

    fn region_at(self: *const Engine, x: u16, y: u16) ?Region {
        var index = self.regions_count;
        while (index > 0) {
            index -= 1;
            const region = self.regions[index];
            if (contains(region.rect, x, y)) return region;
        }
        return null;
    }
};

const OrderedPoints = struct {
    start: Point,
    end: Point,
};

fn ordered_points(selection: Selection) OrderedPoints {
    if (selection.anchor.y < selection.cursor.y) {
        return .{ .start = selection.anchor, .end = selection.cursor };
    }
    if (selection.anchor.y > selection.cursor.y) {
        return .{ .start = selection.cursor, .end = selection.anchor };
    }
    if (selection.anchor.x <= selection.cursor.x) {
        return .{ .start = selection.anchor, .end = selection.cursor };
    }
    return .{ .start = selection.cursor, .end = selection.anchor };
}

fn clamp_point(rect: Rect, x: u16, y: u16) Point {
    std.debug.assert(rect.width > 0);
    std.debug.assert(rect.height > 0);
    return .{
        .x = std.math.clamp(x, rect.x, rect.right() - 1),
        .y = std.math.clamp(y, rect.y, rect.y + rect.height - 1),
    };
}

fn contains(rect: Rect, x: u16, y: u16) bool {
    if (x < rect.x or y < rect.y) return false;
    return x < rect.right() and y < rect.y + rect.height;
}

fn point_equals(point: Point, x: u16, y: u16) bool {
    return point.x == x and point.y == y;
}

fn selection_contains(selection: ?Selection, x: u16, y: u16) bool {
    const selected = selection orelse return false;
    if (!contains(selected.region.rect, x, y)) return false;
    const ordered = ordered_points(selected);
    if (y < ordered.start.y or y > ordered.end.y) return false;
    if (ordered.start.y == ordered.end.y) {
        return x >= ordered.start.x and x <= ordered.end.x;
    }
    if (y == ordered.start.y) return x >= ordered.start.x;
    if (y == ordered.end.y) return x <= ordered.end.x;
    return true;
}

const RowRange = struct {
    start: u16,
    end: u16,
};

fn row_range(region: Rect, ordered: OrderedPoints, y: u16) RowRange {
    std.debug.assert(y >= ordered.start.y);
    std.debug.assert(y <= ordered.end.y);
    if (ordered.start.y == ordered.end.y) {
        return .{ .start = ordered.start.x, .end = ordered.end.x };
    }
    if (y == ordered.start.y) {
        return .{ .start = ordered.start.x, .end = region.right() - 1 };
    }
    if (y == ordered.end.y) {
        return .{ .start = region.x, .end = ordered.end.x };
    }
    return .{ .start = region.x, .end = region.right() - 1 };
}

fn update_text_cells(
    cells: []u16,
    entries: []const TextEntry,
    replacement: ?u16,
) void {
    for (entries) |entry| {
        var offset: u16 = 0;
        while (offset < entry.text_length) : (offset += 1) {
            const index = text_position_index(entry.x + offset, entry.y);
            cells[index] = replacement orelse entry.text[offset];
        }
    }
}

fn text_position_index(x: u16, y: u16) usize {
    const index = @as(usize, y) * limits.canvas_width_max + x;
    std.debug.assert(index < limits.text_positions_max);
    return index;
}

test "selection clamps drag to its starting region" {
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    try engine.add_region(Rect.init(10, 2, 5, 3), test_selection_style);
    engine.commit(&.{}, &.{});

    try std.testing.expectEqual(.redraw, engine.handle(.{
        .x = 11,
        .y = 2,
        .action = .press,
        .button = .primary,
    }));
    try std.testing.expectEqual(.redraw, engine.handle(.{
        .x = 100,
        .y = 100,
        .action = .drag,
        .button = .primary,
    }));
    try std.testing.expect(engine.is_selected(11, 2));
    try std.testing.expect(engine.is_selected(14, 4));
    try std.testing.expect(!engine.is_selected(9, 3));
    try std.testing.expect(!engine.is_selected(15, 3));
    try std.testing.expect(
        engine.cell_style(11, 2).?.background.equals(
            test_selection_style.anchor_background,
        ),
    );
    try std.testing.expect(
        engine.cell_style(14, 4).?.background.equals(
            test_selection_style.cursor_background,
        ),
    );
    _ = engine.handle(.{
        .x = 100,
        .y = 100,
        .action = .release,
        .button = .none,
    });
    try std.testing.expect(
        engine.cell_style(11, 2).?.background.equals(
            test_selection_style.background,
        ),
    );
}

test "selection copies registered text cells without background cells" {
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const white = Color.from_rgb(255, 255, 255);
    var entries = [_]TextEntry{
        .{
            .x = 11,
            .y = 2,
            .text_length = 2,
            .text = undefined,
            .foreground_color = white,
            .background_color = null,
        },
        .{
            .x = 13,
            .y = 3,
            .text_length = 2,
            .text = undefined,
            .foreground_color = white,
            .background_color = null,
        },
    };
    @memcpy(entries[0].text[0..2], "ab");
    @memcpy(entries[1].text[0..2], "cd");
    try engine.add_region(Rect.init(10, 2, 5, 3), test_selection_style);
    engine.commit(&entries, &.{});
    _ = engine.handle(.{
        .x = 11,
        .y = 2,
        .action = .press,
        .button = .primary,
    });
    _ = engine.handle(.{
        .x = 14,
        .y = 3,
        .action = .drag,
        .button = .primary,
    });
    _ = engine.handle(.{
        .x = 14,
        .y = 3,
        .action = .release,
        .button = .none,
    });
    try std.testing.expectEqualStrings("ab\ncd", engine.selected_text());
    var output: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try std.testing.expect(try engine.write_clipboard(&writer));
    try std.testing.expectEqualStrings(
        "\x1B]52;c;YWIKY2Q=\x07",
        writer.buffered(),
    );
}

test "later selection regions own overlapping overlay cells" {
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    var overlay_style = test_selection_style;
    overlay_style.cursor_background = Color.from_rgb(240, 80, 120);
    try engine.add_region(Rect.init(0, 0, 10, 4), test_selection_style);
    try engine.add_region(Rect.init(2, 1, 6, 2), overlay_style);
    engine.commit(&.{}, &.{});
    _ = engine.handle(.{
        .x = 3,
        .y = 1,
        .action = .press,
        .button = .primary,
    });
    const style = engine.cell_style(3, 1) orelse
        return error.MissingSelectionStyle;
    try std.testing.expect(style.background.equals(overlay_style.cursor_background));
}

test "a click does not become a clipboard selection" {
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    try engine.add_region(Rect.init(0, 0, 8, 2), test_selection_style);
    engine.commit(&.{}, &.{});
    _ = engine.handle(.{
        .x = 2,
        .y = 1,
        .action = .press,
        .button = .primary,
    });
    try std.testing.expectEqual(.redraw, engine.handle(.{
        .x = 2,
        .y = 1,
        .action = .release,
        .button = .none,
    }));
    try std.testing.expect(!engine.is_selected(2, 1));
}

const test_selection_style = TextSelectionStyle{
    .foreground = Color.from_rgb(255, 255, 255),
    .background = Color.from_rgb(20, 30, 40),
    .active_background = Color.from_rgb(30, 40, 50),
    .anchor_background = Color.from_rgb(40, 50, 60),
    .cursor_foreground = Color.from_rgb(0, 0, 0),
    .cursor_background = Color.from_rgb(200, 200, 100),
};
