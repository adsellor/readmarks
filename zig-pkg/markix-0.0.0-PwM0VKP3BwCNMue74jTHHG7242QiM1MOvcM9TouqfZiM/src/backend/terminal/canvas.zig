const std = @import("std");
const limits = @import("limits.zig");
const terminal = @import("terminal.zig");
const text_width = @import("text_width.zig");
const Color = @import("../../style/color.zig").Color;
const Pointer = @import("../../utils/input.zig").Pointer;
const Rect = @import("../../layout/rect.zig").Rect;
const TextSelectionStyle = @import("../../style/style.zig").TextSelectionStyle;
const SelectionEngine = @import("selection.zig").Engine;
const SelectionAction = @import("selection.zig").Action;
const SelectionCellStyle = @import("selection.zig").CellStyle;
const TextEntry = @import("text_entry.zig").TextEntry;
const Attributes = @import("../../style/text_style.zig").Attributes;
const image = @import("image.zig");

const Allocator = std.mem.Allocator;
const PixelColors = struct { upper: Color, lower: Color };
const text_index_none = std.math.maxInt(u16);
const SixelOutcome = union(enum) { success: u32, failure: anyerror };
const SixelResultQueue = std.Io.Queue(SixelOutcome);

pub const WebRect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    color: Color,
};

pub const TerminalCanvas = struct {
    width: u16,
    height: u16,
    buffer: []Color,
    previous_buffer: []Color,
    output_buffer: []u8,
    sixel_bitmap_buffer: []u8,
    sixel_output_buffer: []u8,
    allocator: Allocator,
    resizable: bool = false,
    frame_period_ns: u64,
    web_rects: []WebRect,
    web_rect_count: u16 = 0,
    background_color: Color = Color.from_rgb(0, 0, 0),
    text_entries: std.ArrayList(TextEntry),
    previous_text_entries: std.ArrayList(TextEntry),
    text_position_indices: []u16,
    previous_text_position_indices: []u16,
    text_restore_cells: []bool,
    selection: SelectionEngine,
    image_protocol: image.Protocol = .none,
    image_placement: ?image.Placement = null,
    previous_image_placement: ?image.Placement = null,
    uploaded_image: ?image.Placement = null,
    sixel_task: std.Io.Group = .init,
    sixel_result_buffer: []SixelOutcome,
    sixel_results: SixelResultQueue,
    sixel_preparing: ?image.Placement = null,
    sixel_ready: ?image.Placement = null,
    sixel_bitmap_length: u32 = 0,
    sixel_io: ?std.Io = null,

    pub fn init(
        allocator: Allocator,
        width: u16,
        height: u16,
    ) !TerminalCanvas {
        try validate_dimensions(width, height);
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        var fresh = try Storage.init(allocator);
        errdefer fresh.deinit(allocator);

        // Every buffer is sized for the largest canvas the limits allow, not
        // for this one, so a resize never allocates. What differs between one
        // canvas and the next is how much of them is addressed.
        std.debug.assert(fresh.buffer.len == limits.canvas_pixels_max);
        // Both transparent, and equal: a partial frame starts from what is
        // already in the buffer, and every cell counts as changed until
        // something paints it, so the first frame draws the whole terminal.
        @memset(fresh.buffer, Color.from_rgba(0, 0, 0, 0));
        @memset(fresh.previous_buffer, Color.from_rgba(0, 0, 0, 0));
        @memset(fresh.text_position_indices, text_index_none);
        @memset(fresh.previous_text_position_indices, text_index_none);
        @memset(fresh.text_restore_cells, false);
        return .{
            .width = width,
            .height = height,
            .buffer = fresh.buffer,
            .previous_buffer = fresh.previous_buffer,
            .output_buffer = fresh.output_buffer,
            .sixel_bitmap_buffer = fresh.sixel_bitmap_buffer,
            .sixel_output_buffer = fresh.sixel_output_buffer,
            .allocator = allocator,
            .frame_period_ns = std.time.ns_per_s / 120,
            .web_rects = fresh.web_rects,
            .text_entries = fresh.text_entries,
            .previous_text_entries = fresh.previous_text_entries,
            .text_position_indices = fresh.text_position_indices,
            .previous_text_position_indices = fresh.previous_text_position_indices,
            .text_restore_cells = fresh.text_restore_cells,
            .selection = fresh.selection,
            .sixel_result_buffer = fresh.sixel_result_buffer,
            .sixel_results = .init(fresh.sixel_result_buffer),
        };
    }

    /// Everything the canvas owns, taken from the allocator once.
    ///
    /// Held together so the acquiring and the releasing of it are one thing
    /// each, rather than a dozen allocations guarded by a dozen `errdefer`s
    /// and a `deinit` that has to remember all of them in the same order.
    const Storage = struct {
        buffer: []Color,
        previous_buffer: []Color,
        output_buffer: []u8,
        sixel_bitmap_buffer: []u8,
        sixel_output_buffer: []u8,
        sixel_result_buffer: []SixelOutcome,
        text_entries: std.ArrayList(TextEntry),
        previous_text_entries: std.ArrayList(TextEntry),
        text_position_indices: []u16,
        previous_text_position_indices: []u16,
        text_restore_cells: []bool,
        web_rects: []WebRect,
        selection: SelectionEngine,

        fn init(allocator: Allocator) !Storage {
            const buffer = try allocator.alloc(Color, limits.canvas_pixels_max);
            errdefer allocator.free(buffer);
            const previous_buffer = try allocator.alloc(Color, limits.canvas_pixels_max);
            errdefer allocator.free(previous_buffer);
            const output_buffer = try allocator.alloc(u8, limits.output_bytes_max);
            errdefer allocator.free(output_buffer);
            const sixel_bitmap = try allocator.alloc(u8, limits.sixel_bitmap_bytes_max);
            errdefer allocator.free(sixel_bitmap);
            const sixel_output = try allocator.alloc(u8, limits.sixel_output_bytes_max);
            errdefer allocator.free(sixel_output);
            const sixel_result = try allocator.alloc(SixelOutcome, 1);
            errdefer allocator.free(sixel_result);
            var entries = try std.ArrayList(TextEntry).initCapacity(
                allocator,
                limits.text_entries_max,
            );
            errdefer entries.deinit(allocator);
            var previous_entries = try std.ArrayList(TextEntry).initCapacity(
                allocator,
                limits.text_entries_max,
            );
            errdefer previous_entries.deinit(allocator);
            const positions = try allocator.alloc(u16, limits.text_positions_max);
            errdefer allocator.free(positions);
            const previous_positions = try allocator.alloc(u16, limits.text_positions_max);
            errdefer allocator.free(previous_positions);
            const restore_cells = try allocator.alloc(bool, limits.text_positions_max);
            errdefer allocator.free(restore_cells);
            const rects = try allocator.alloc(WebRect, limits.web_rects_max);
            errdefer allocator.free(rects);
            var selection = try SelectionEngine.init(allocator);
            errdefer selection.deinit();
            std.debug.assert(buffer.len == previous_buffer.len);
            std.debug.assert(positions.len == previous_positions.len);
            return .{
                .buffer = buffer,
                .previous_buffer = previous_buffer,
                .output_buffer = output_buffer,
                .sixel_bitmap_buffer = sixel_bitmap,
                .sixel_output_buffer = sixel_output,
                .sixel_result_buffer = sixel_result,
                .text_entries = entries,
                .previous_text_entries = previous_entries,
                .text_position_indices = positions,
                .previous_text_position_indices = previous_positions,
                .text_restore_cells = restore_cells,
                .web_rects = rects,
                .selection = selection,
            };
        }

        fn deinit(self: *Storage, allocator: Allocator) void {
            std.debug.assert(self.buffer.len > 0);
            std.debug.assert(self.output_buffer.len > 0);
            allocator.free(self.buffer);
            allocator.free(self.previous_buffer);
            allocator.free(self.output_buffer);
            allocator.free(self.sixel_bitmap_buffer);
            allocator.free(self.sixel_output_buffer);
            allocator.free(self.sixel_result_buffer);
            self.text_entries.deinit(allocator);
            self.previous_text_entries.deinit(allocator);
            allocator.free(self.text_position_indices);
            allocator.free(self.previous_text_position_indices);
            allocator.free(self.text_restore_cells);
            allocator.free(self.web_rects);
            self.selection.deinit();
        }
    };

    fn validate_dimensions(width: u16, height: u16) !void {
        if (width == 0 or height == 0) return error.ZeroCanvasDimension;
        if (width > limits.canvas_width_max) return error.CanvasTooWide;
        if (height > limits.canvas_height_max) return error.CanvasTooTall;
    }

    pub fn init_auto_size(allocator: Allocator) !TerminalCanvas {
        const size = try terminal.get_terminal_size();
        const height = std.math.mul(u16, size.height, 2) catch
            return error.CanvasTooTall;
        var canvas = try TerminalCanvas.init(allocator, size.width, height);
        canvas.resizable = true;
        return canvas;
    }

    pub fn deinit(self: *TerminalCanvas) void {
        std.debug.assert(self.buffer.len > 0);
        if (self.sixel_io) |io| {
            self.sixel_task.cancel(io);
            self.sixel_results.close(io);
        }
        var owned = self.owned_storage();
        owned.deinit(self.allocator);
        // Emptied rather than left dangling: a canvas used after this is a
        // bug, and one that reads an empty slice is caught at the bound check
        // instead of reading freed memory that still looks like a frame.
        self.buffer = self.buffer[0..0];
        self.previous_buffer = self.previous_buffer[0..0];
        self.output_buffer = self.output_buffer[0..0];
        self.sixel_bitmap_buffer = self.sixel_bitmap_buffer[0..0];
        self.sixel_output_buffer = self.sixel_output_buffer[0..0];
        self.sixel_result_buffer = self.sixel_result_buffer[0..0];
        self.text_position_indices = self.text_position_indices[0..0];
        self.previous_text_position_indices =
            self.previous_text_position_indices[0..0];
        self.text_restore_cells = self.text_restore_cells[0..0];
        self.web_rects = self.web_rects[0..0];
        std.debug.assert(self.buffer.len == 0);
    }

    /// The canvas's buffers, gathered back into the shape they were taken in.
    fn owned_storage(self: *TerminalCanvas) Storage {
        std.debug.assert(self.buffer.len > 0);
        std.debug.assert(self.output_buffer.len > 0);
        return .{
            .buffer = self.buffer,
            .previous_buffer = self.previous_buffer,
            .output_buffer = self.output_buffer,
            .sixel_bitmap_buffer = self.sixel_bitmap_buffer,
            .sixel_output_buffer = self.sixel_output_buffer,
            .sixel_result_buffer = self.sixel_result_buffer,
            .text_entries = self.text_entries,
            .previous_text_entries = self.previous_text_entries,
            .text_position_indices = self.text_position_indices,
            .previous_text_position_indices = self.previous_text_position_indices,
            .text_restore_cells = self.text_restore_cells,
            .web_rects = self.web_rects,
            .selection = self.selection,
        };
    }

    pub fn set_refresh_limit(
        self: *TerminalCanvas,
        frame_rate_hz: u16,
    ) error{InvalidFrameRate}!void {
        if (frame_rate_hz < limits.frame_rate_hz_min) return error.InvalidFrameRate;
        if (frame_rate_hz > limits.frame_rate_hz_max) return error.InvalidFrameRate;
        self.frame_period_ns = @as(u64, std.time.ns_per_s) / frame_rate_hz;
    }

    pub fn set_image_protocol(self: *TerminalCanvas, protocol: image.Protocol) void {
        self.image_protocol = protocol;
    }

    pub fn add_image(self: *TerminalCanvas, placement: image.Placement) !void {
        if (self.image_placement != null) return error.TooManyImagePlacements;
        if (placement.x + placement.width > self.width) return error.ImageOutOfBounds;
        if (placement.y + placement.height > terminal_row_count(self.height)) {
            return error.ImageOutOfBounds;
        }
        self.image_placement = placement;
    }

    pub fn set_pixel(self: *TerminalCanvas, x: u16, y: u16, color: Color) void {
        if (x < self.width and y < self.height) {
            self.buffer[pixel_index(self.width, x, y)] = color;
        }
    }

    pub fn get_pixel(self: *const TerminalCanvas, x: u16, y: u16) ?Color {
        if (x < self.width and y < self.height) {
            return self.buffer[pixel_index(self.width, x, y)];
        }
        return null;
    }

    fn pixel_index(width: u16, x: u16, y: u16) usize {
        std.debug.assert(x < width);
        const index = @as(usize, y) * width + x;
        std.debug.assert(index < limits.canvas_pixels_max);
        return index;
    }

    pub fn filled_rect(
        self: *TerminalCanvas,
        x: u16,
        y: u16,
        width: u16,
        height: u16,
        color: Color,
    ) void {
        std.debug.assert(self.width > 0);
        std.debug.assert(self.buffer.len > 0);
        const end_x: u16 = @intCast(@min(@as(u32, x) + width, self.width));
        const end_y: u16 = @intCast(@min(@as(u32, y) + height, self.height));

        if (x >= end_x or y >= end_y) return;
        var pixel_y = y;
        while (pixel_y < end_y) : (pixel_y += 1) {
            const start = pixel_index(self.width, x, pixel_y);
            const length = end_x - x;
            @memset(self.buffer[start..][0..length], color);
        }
        if (self.web_rect_count < limits.web_rects_max) {
            self.web_rects[self.web_rect_count] = .{
                .x = x,
                .y = y / 2,
                .width = end_x - x,
                .height = @divFloor(end_y - y + 1, 2),
                .color = color,
            };
            self.web_rect_count += 1;
        }
    }

    pub fn add_text(
        self: *TerminalCanvas,
        x: u16,
        y: u16,
        text: []const u8,
        foreground: Color,
        background: ?Color,
    ) !void {
        try self.add_styled_text(x, y, text, foreground, background, .{});
    }

    pub fn add_styled_text(
        self: *TerminalCanvas,
        x: u16,
        y: u16,
        text: []const u8,
        foreground: Color,
        background: ?Color,
        attributes: Attributes,
    ) !void {
        std.debug.assert(self.width > 0);
        std.debug.assert(text.len <= std.math.maxInt(u16));
        if (text.len > limits.text_bytes_max) return error.TextTooLong;
        if (self.text_entries.items.len >= limits.text_entries_max) {
            return error.TooManyTextEntries;
        }
        if (x >= self.width or y >= terminal_row_count(self.height)) {
            return error.TextOutOfBounds;
        }
        if (text_width.columns(text) > self.width - x) return error.TextOutOfBounds;
        const position = text_position_index(x, y);
        if (self.text_position_indices[position] != text_index_none) {
            return error.DuplicateTextPosition;
        }

        std.debug.assert(self.text_entries.capacity == limits.text_entries_max);
        const entry_index: u16 = @intCast(self.text_entries.items.len);
        const entry = self.text_entries.addOneAssumeCapacity();
        entry.* = .{
            .x = x,
            .y = y,
            .text_length = @intCast(text.len),
            .foreground_color = foreground,
            .background_color = background,
            .attributes = attributes,
        };
        @memcpy(entry.text[0..text.len], text);
        self.text_position_indices[position] = entry_index;
    }

    /// Live text entry anchored at this cell, if any.
    ///
    /// `text_entries` keeps records whose cells were later cleared, so the
    /// position index -- not the entry list -- says what a frame actually
    /// shows.
    pub fn text_at(self: *const TerminalCanvas, x: u16, y: u16) ?*const TextEntry {
        if (x >= self.width or y >= terminal_row_count(self.height)) return null;
        const index = self.text_position_indices[text_position_index(x, y)];
        if (index == text_index_none) return null;
        return &self.text_entries.items[index];
    }

    pub fn add_selection_region(
        self: *TerminalCanvas,
        rect: Rect,
        style: TextSelectionStyle,
    ) !void {
        std.debug.assert(rect.x < self.width);
        std.debug.assert(rect.y < terminal_row_count(self.height));
        std.debug.assert(rect.right() <= self.width);
        std.debug.assert(rect.y + rect.height <= terminal_row_count(self.height));
        try self.selection.add_region(rect, style);
    }

    pub fn handle_pointer(self: *TerminalCanvas, pointer: Pointer) SelectionAction {
        return self.selection.handle(pointer);
    }

    pub fn copy_selection(self: *TerminalCanvas, io: std.Io) !void {
        var writer = std.Io.Writer.fixed(self.output_buffer);
        if (!try self.selection.write_clipboard(&writer)) return;
        try std.Io.File.stdout().writeStreamingAll(io, writer.buffered());
    }

    fn terminal_row_count(height: u16) u16 {
        return @divFloor(height + 1, 2);
    }

    fn text_position_index(x: u16, y: u16) usize {
        const index = @as(usize, y) * limits.canvas_width_max + x;
        std.debug.assert(index < limits.text_positions_max);
        return index;
    }

    fn pixel_pair(
        self: *const TerminalCanvas,
        x: u16,
        y: u16,
        previous: bool,
    ) PixelColors {
        std.debug.assert(x < self.width);
        std.debug.assert(y < self.height);
        const source = if (previous) self.previous_buffer else self.buffer;
        return .{
            .upper = source[pixel_index(self.width, x, y)],
            .lower = if (y + 1 < self.height)
                source[pixel_index(self.width, x, y + 1)]
            else
                Color.from_rgb(0, 0, 0),
        };
    }

    fn pixel_pair_changed(self: *const TerminalCanvas, x: u16, y: u16) bool {
        const cell = text_position_index(x, y / 2);
        if (self.text_restore_cells[cell]) return true;
        const current = self.pixel_pair(x, y, false);
        const previous = self.pixel_pair(x, y, true);
        return !current.upper.equals(previous.upper) or
            !current.lower.equals(previous.lower);
    }

    fn write_pixel_patches(
        self: *const TerminalCanvas,
        writer: *std.Io.Writer,
    ) !void {
        std.debug.assert(self.width > 0);
        std.debug.assert(self.buffer.len == self.previous_buffer.len);
        var pixel_y: u16 = 0;
        while (pixel_y < self.height) : (pixel_y += 2) {
            var active = false;
            var previous_colors: ?PixelColors = null;
            var pixel_x: u16 = 0;
            while (pixel_x < self.width) : (pixel_x += 1) {
                if (self.pixel_pair_changed(pixel_x, pixel_y)) {
                    if (!active) {
                        try write_cursor(writer, pixel_x, pixel_y / 2);
                        active = true;
                    }
                    const colors = self.pixel_pair(pixel_x, pixel_y, false);
                    try write_pixel(writer, colors, &previous_colors);
                } else {
                    active = false;
                    previous_colors = null;
                }
            }
        }
    }

    fn write_pixel(
        writer: *std.Io.Writer,
        colors: PixelColors,
        previous: *?PixelColors,
    ) !void {
        std.debug.assert(@sizeOf(PixelColors) > 0);
        std.debug.assert(colors.upper.a <= 255);
        const changed = if (previous.*) |old|
            !old.upper.equals(colors.upper) or !old.lower.equals(colors.lower)
        else
            true;
        if (changed) {
            try write_pixel_colors(writer, colors);
            previous.* = colors;
        }
        try writer.writeAll(pixel_character(colors));
    }

    fn write_pixel_colors(writer: *std.Io.Writer, colors: PixelColors) !void {
        if (colors.upper.kind == .terminal_background) {
            if (colors.lower.kind == .terminal_background) {
                try write_background(writer, colors.lower);
                return;
            }
            try write_foreground(writer, colors.lower);
            try write_background(writer, colors.upper);
            return;
        }
        try write_colors(writer, colors.upper, colors.lower);
    }

    fn pixel_character(colors: PixelColors) []const u8 {
        if (colors.upper.kind == .terminal_background) {
            if (colors.lower.kind == .terminal_background) return " ";
            return "▄";
        }
        return "▀";
    }

    fn write_colors(
        writer: *std.Io.Writer,
        foreground: Color,
        background: Color,
    ) !void {
        try write_foreground(writer, foreground);
        try write_background(writer, background);
    }

    fn write_foreground(writer: *std.Io.Writer, color: Color) !void {
        switch (color.kind) {
            .rgb => try writer.print(
                "\x1B[38;2;{d};{d};{d}m",
                .{ color.r, color.g, color.b },
            ),
            .ansi => try writer.print("\x1B[{d}m", .{ansi_code(color.r, false)}),
            .terminal_foreground => try writer.writeAll("\x1B[39m"),
            .terminal_background, .transparent => return error.InvalidForegroundColor,
        }
    }

    fn write_background(writer: *std.Io.Writer, color: Color) !void {
        switch (color.kind) {
            .rgb => try writer.print(
                "\x1B[48;2;{d};{d};{d}m",
                .{ color.r, color.g, color.b },
            ),
            .ansi => try writer.print("\x1B[{d}m", .{ansi_code(color.r, true)}),
            .terminal_background => try writer.writeAll("\x1B[49m"),
            .terminal_foreground, .transparent => return error.InvalidBackgroundColor,
        }
    }

    fn ansi_code(index: u8, background: bool) u8 {
        std.debug.assert(index < 16);
        const base: u8 = if (index < 8)
            if (background) 40 else 30
        else if (background)
            100
        else
            90;
        return base + index % 8;
    }

    fn write_cursor(writer: *std.Io.Writer, x: u16, y: u16) !void {
        try writer.print("\x1B[{d};{d}H", .{ y + 1, x + 1 });
    }

    fn write_text_patches(
        self: *const TerminalCanvas,
        writer: *std.Io.Writer,
        restores_active: bool,
    ) !void {
        std.debug.assert(self.width > 0);
        std.debug.assert(self.text_position_indices.len > 0);
        for (self.text_entries.items, 0..) |*entry, index| {
            const position = text_position_index(entry.x, entry.y);
            // `clear_rect` releases a cell by nulling its position index but
            // leaves the record behind. Emitting those would paint text the
            // frame no longer shows -- in a partial frame that is the previous
            // frame's content drawn over the new one.
            if (self.text_position_indices[position] != index) continue;
            const previous_index = self.previous_text_position_indices[position];
            if (previous_index == text_index_none or
                !entry.equals(&self.previous_text_entries.items[previous_index]) or
                (restores_active and self.text_entry_needs_restore(entry)) or
                self.selection.entry_changed(entry))
            {
                try self.write_text_entry(writer, entry);
            }
        }
    }

    fn text_entry_needs_restore(self: *const TerminalCanvas, entry: *const TextEntry) bool {
        var offset: u16 = 0;
        while (offset < entry.text_length) : (offset += 1) {
            const cell = text_position_index(entry.x + offset, entry.y);
            if (self.text_restore_cells[cell]) return true;
        }
        return false;
    }

    fn write_text_entry(
        self: *const TerminalCanvas,
        writer: *std.Io.Writer,
        entry: *const TextEntry,
    ) !void {
        std.debug.assert(self.width > 0);
        std.debug.assert(entry.text_length <= entry.text.len);
        try write_cursor(writer, entry.x, entry.y);
        try write_foreground(writer, entry.foreground_color);
        if (entry.background_color) |background| {
            try write_background(writer, background);
        }
        try write_attributes(writer, entry.attributes);
        if (!self.selection.active()) {
            try writer.writeAll(entry.bytes());
            try writer.writeAll("\x1B[0m");
            return;
        }
        var previous_style: ?SelectionCellStyle = null;
        var offset: u16 = 0;
        while (offset < entry.text_length) : (offset += 1) {
            const style = self.selection.cell_style(entry.x + offset, entry.y);
            if (!std.meta.eql(style, previous_style)) {
                try write_text_cell_style(writer, entry, style);
                previous_style = style;
            }
            try writer.writeAll(entry.text[offset..][0..1]);
        }
        try writer.writeAll("\x1B[0m");
    }

    fn write_text_cell_style(
        writer: *std.Io.Writer,
        entry: *const TextEntry,
        style: ?SelectionCellStyle,
    ) !void {
        std.debug.assert(entry.text_length <= entry.text.len);
        std.debug.assert(entry.text_length > 0);
        if (style) |selected| {
            try write_colors(writer, selected.foreground, selected.background);
            try writer.writeAll(if (selected.bold) "\x1B[1m" else "\x1B[22m");
            try writer.writeAll("\x1B[24m");
            return;
        }
        try write_foreground(writer, entry.foreground_color);
        if (entry.background_color) |background| {
            try write_background(writer, background);
        } else {
            try writer.writeAll("\x1B[49m");
        }
        try write_attributes(writer, entry.attributes);
    }

    fn write_attributes(writer: *std.Io.Writer, attributes: Attributes) !void {
        try writer.writeAll("\x1B[22m");
        if (attributes.bold) try writer.writeAll("\x1B[1m");
        if (attributes.dim) try writer.writeAll("\x1B[2m");
        try writer.writeAll(if (attributes.underline) "\x1B[4m" else "\x1B[24m");
    }

    pub fn frame_timeout_ms(self: *const TerminalCanvas) i32 {
        const nanoseconds_per_millisecond = std.time.ns_per_ms;
        const milliseconds = @divFloor(
            self.frame_period_ns + nanoseconds_per_millisecond - 1,
            nanoseconds_per_millisecond,
        );
        return @intCast(@max(milliseconds, 1));
    }

    pub fn resize(self: *TerminalCanvas, width: u16, height: u16) !void {
        std.debug.assert(self.buffer.len == limits.canvas_pixels_max);
        std.debug.assert(self.resizable or width == self.width);
        if (width == self.width and height == self.height) return;
        try validate_dimensions(width, height);
        self.width = width;
        self.height = height;
        // Both to the same value, and that value transparent. Equal, because a
        // partial frame starts from what is already in the buffer and a
        // difference here would be a difference nothing put there; transparent,
        // because every cell then counts as changed and the first frame after a
        // resize redraws the terminal rather than trusting what survived it.
        @memset(self.buffer, Color.from_rgba(0, 0, 0, 0));
        @memset(self.previous_buffer, Color.from_rgba(0, 0, 0, 0));
        self.text_entries.clearRetainingCapacity();
        self.previous_text_entries.clearRetainingCapacity();
        @memset(self.text_position_indices, text_index_none);
        @memset(self.previous_text_position_indices, text_index_none);
        @memset(self.text_restore_cells, false);
        self.web_rect_count = 0;
        self.selection.reset();
    }

    pub fn start_frame(self: *TerminalCanvas, background: Color) void {
        self.background_color = background;
        self.web_rect_count = 0;
        @memset(self.buffer, background);
        self.text_entries.clearRetainingCapacity();
        @memset(self.text_position_indices, text_index_none);
        @memset(self.text_restore_cells, false);
        self.selection.reset();
        self.image_placement = null;
    }

    /// Begins a frame from what the last one left on screen.
    ///
    /// The pixels are not copied across. `commit_frame` already made the two
    /// buffers equal, and nothing between then and here writes to this one, so
    /// it still holds exactly the frame being started from -- copying it onto
    /// itself was the single largest cost of a frame that changed two rows.
    ///
    /// The position maps are cleared only as far as the canvas actually
    /// reaches. They are sized for the largest terminal the limits allow, and
    /// a frame on an eighty-row window was clearing a quarter of a megabyte to
    /// say nothing about four hundred thousand cells that do not exist.
    pub fn start_partial_frame(self: *TerminalCanvas, background: Color) void {
        std.debug.assert(self.width > 0);
        std.debug.assert(self.buffer.len == self.previous_buffer.len);
        self.background_color = background;
        self.web_rect_count = 0;
        if (std.debug.runtime_safety) self.assert_frames_agree();
        self.carry_live_text();
        @memset(self.text_restore_cells[0..self.live_positions()], false);
        self.selection.reset();
        self.image_placement = null;
    }

    /// Position slots the canvas can address, as a prefix of the map.
    ///
    /// A slot is `row * canvas_width_max + column`, so every live slot lies
    /// below `rows * canvas_width_max` however narrow the terminal is.
    fn live_positions(self: *const TerminalCanvas) usize {
        const rows = @divFloor(@as(usize, self.height) + 1, 2);
        const total = rows * limits.canvas_width_max;
        std.debug.assert(total <= self.text_position_indices.len);
        std.debug.assert(total <= self.text_restore_cells.len);
        return total;
    }

    /// The invariant that lets a frame start without copying: what is in the
    /// buffer is what was last committed. Checked only where safety is on --
    /// it is a scan of the whole canvas, which is the cost being avoided.
    fn assert_frames_agree(self: *const TerminalCanvas) void {
        const pixel_count = @as(usize, self.width) * self.height;
        std.debug.assert(pixel_count <= self.buffer.len);
        var index: usize = 0;
        while (index < pixel_count) : (index += 1) {
            std.debug.assert(self.buffer[index].equals(self.previous_buffer[index]));
        }
    }

    /// Rebuilds this frame's text from the previous one, keeping only entries
    /// still anchored at a live cell.
    ///
    /// `clear_rect` releases a cell by nulling its position index but leaves
    /// the record in `text_entries`. Copying the list wholesale would carry
    /// those dead records into every later frame until the array overflows, so
    /// the position map -- the authority on what is actually shown -- decides
    /// what survives, and the entries are compacted as they are copied.
    fn carry_live_text(self: *TerminalCanvas) void {
        std.debug.assert(self.width > 0);
        std.debug.assert(self.text_entries.items.len <= limits.text_entries_max);
        self.text_entries.clearRetainingCapacity();
        @memset(self.text_position_indices[0..self.live_positions()], text_index_none);
        for (self.previous_text_entries.items, 0..) |entry, index| {
            const position = text_position_index(entry.x, entry.y);
            if (self.previous_text_position_indices[position] != index) continue;
            const moved: u16 = @intCast(self.text_entries.items.len);
            self.text_entries.appendAssumeCapacity(entry);
            self.text_position_indices[position] = moved;
        }
    }

    pub fn clear_rect(self: *TerminalCanvas, rect: Rect, background: Color) void {
        const start_y = @as(u32, rect.y) * 2;
        const end_y = @min(start_y + @as(u32, rect.height) * 2, @as(u32, self.height));
        const end_x = @min(@as(u32, rect.x) + rect.width, @as(u32, self.width));
        var y = start_y;
        while (y < end_y) : (y += 1) {
            var x: u32 = rect.x;
            while (x < end_x) : (x += 1) {
                const idx = y * self.width + x;
                self.buffer[idx] = background;
            }
        }
        self.clear_text_in_rect(rect);
    }

    fn clear_text_in_rect(self: *TerminalCanvas, rect: Rect) void {
        var y: u16 = rect.y;
        while (y < rect.y +| rect.height) : (y += 1) {
            var x: u16 = rect.x;
            while (x < rect.x +| rect.width) : (x += 1) {
                const pos = text_position_index(x, y);
                self.text_position_indices[pos] = text_index_none;
            }
        }
    }
    pub fn render(self: *TerminalCanvas, io: std.Io) !void {
        std.debug.assert(self.width > 0);
        std.debug.assert(self.output_buffer.len > 0);
        const pending_image = self.image_to_display();
        const upload_image = self.image_needs_upload(pending_image);
        self.damage_previous_sixel();
        var writer = std.Io.Writer.fixed(self.output_buffer);
        try writer.writeAll("\x1B[?25l");
        const prefix_length = writer.buffered().len;
        try self.write_frame_patches(&writer);
        if (writer.buffered().len == prefix_length) {
            try self.display_image(io, pending_image, upload_image);
            self.commit_frame();
            return;
        }
        // The canvas is sized to the terminal (`init_auto_size` doubles the
        // reported rows), so row `terminal_row_count + 1` clamps back to the
        // last visible row on a real terminal. Showing the cursor there paints
        // a white block at the bottom-right on every changing frame; keep it
        // hidden and only park it below the content. `exit_alternate_screen`
        // restores the cursor on the way out.
        try writer.print(
            "\x1B[{d};{d}H\x1B[?25l",
            .{ terminal_row_count(self.height) + 1, self.width + 1 },
        );
        try std.Io.File.stdout().writeStreamingAll(io, writer.buffered());
        try self.display_image(io, pending_image, upload_image);
        self.commit_frame();
    }

    fn image_to_display(self: *const TerminalCanvas) ?image.Placement {
        const current = self.image_placement orelse return null;
        const previous = self.previous_image_placement orelse return current;
        return if (current.equals(&previous)) null else current;
    }

    fn image_needs_upload(
        self: *const TerminalCanvas,
        placement: ?image.Placement,
    ) bool {
        const pending = placement orelse return false;
        const uploaded = self.uploaded_image orelse return true;
        return !pending.same_image(&uploaded);
    }

    fn display_image(
        self: *TerminalCanvas,
        io: std.Io,
        placement: ?image.Placement,
        upload: bool,
    ) !void {
        std.debug.assert(self.width > 0);
        std.debug.assert(self.image_protocol != .none);
        if (placement) |*pending| {
            if (pending.protocol == .sixel and !self.sixel_is_ready(pending)) {
                self.start_sixel_prepare(io, pending) catch {
                    self.disable_images();
                };
                return;
            }
            image.display(io, pending, upload, .{
                .bitmap = self.sixel_bitmap_buffer,
                .output = self.sixel_output_buffer,
            }, self.sixel_bitmap_length) catch {
                self.disable_images();
                return;
            };
            if (upload and pending.protocol == .kitty) {
                self.uploaded_image = pending.*;
            }
        }
    }

    pub fn poll_background(self: *TerminalCanvas, io: std.Io) !bool {
        std.debug.assert(self.width > 0);
        std.debug.assert(self.sixel_result_buffer.len == 1);
        const prepared = self.sixel_preparing orelse return false;
        var completed: [1]SixelOutcome = undefined;
        const count = self.sixel_results.get(io, &completed, 0) catch |err| {
            return switch (err) {
                error.Closed => false,
                error.Canceled => err,
            };
        };
        if (count == 0) return false;
        try self.sixel_task.await(io);
        self.sixel_preparing = null;
        switch (completed[0]) {
            .success => |length| {
                self.sixel_ready = prepared;
                self.sixel_bitmap_length = length;
            },
            .failure => self.disable_images(),
        }
        self.previous_image_placement = null;
        return true;
    }

    fn start_sixel_prepare(
        self: *TerminalCanvas,
        io: std.Io,
        placement: *const image.Placement,
    ) !void {
        if (self.sixel_preparing != null) return;
        std.debug.assert(placement.protocol == .sixel);
        self.sixel_preparing = placement.*;
        self.sixel_io = io;
        self.sixel_task.concurrent(io, sixel_prepare_task, .{ self, io }) catch |err| {
            self.sixel_preparing = null;
            return err;
        };
    }

    fn sixel_is_ready(
        self: *const TerminalCanvas,
        placement: *const image.Placement,
    ) bool {
        const ready = self.sixel_ready orelse return false;
        return ready.width == placement.width and
            ready.full_height_rows == placement.full_height_rows and
            std.mem.eql(u8, ready.path_bytes(), placement.path_bytes());
    }

    fn disable_images(self: *TerminalCanvas) void {
        self.image_protocol = .none;
        self.uploaded_image = null;
        self.sixel_ready = null;
        self.sixel_bitmap_length = 0;
    }

    fn damage_previous_sixel(self: *TerminalCanvas) void {
        std.debug.assert(self.width > 0);
        std.debug.assert(self.height > 0);
        const previous = self.previous_image_placement orelse return;
        if (previous.protocol != .sixel) return;
        if (self.image_placement) |*current| {
            if (current.equals(&previous)) return;
        }
        const start_y = @as(u32, previous.y) * 2;
        const end_y = @min(start_y + @as(u32, previous.height) * 2, self.height);
        const end_x = @min(@as(u32, previous.x) + previous.width, self.width);
        var y = start_y;
        while (y < end_y) : (y += 1) {
            var x: u32 = previous.x;
            while (x < end_x) : (x += 1) {
                const index = @as(usize, y) * self.width + x;
                self.previous_buffer[index] = Color.from_rgba(0, 0, 0, 0);
            }
        }
    }

    fn write_frame_patches(
        self: *TerminalCanvas,
        writer: *std.Io.Writer,
    ) !void {
        const restores_active = self.mark_text_restore_cells(true);
        errdefer _ = self.mark_text_restore_cells(false);
        try self.write_pixel_patches(writer);
        try self.write_text_patches(writer, restores_active);
        try self.write_image_patches(writer);
        _ = self.mark_text_restore_cells(false);
    }

    fn write_image_patches(
        self: *const TerminalCanvas,
        writer: *std.Io.Writer,
    ) !void {
        std.debug.assert(self.width > 0);
        std.debug.assert(self.output_buffer.len > 0);
        const current = self.image_placement;
        const previous = self.previous_image_placement;
        if (current) |*placement| {
            if (previous) |*old| {
                if (placement.equals(old)) return;
                if (placement.same_image(old)) return;
                try image.write_delete(writer, old);
            }
        } else if (previous) |*old| {
            try image.write_delete(writer, old);
        }
    }

    /// Promotes the working frame to the previous frame.
    ///
    /// `render` does this after emitting patches. Callers driving the canvas
    /// without a terminal must invoke it themselves: `start_partial_frame`
    /// restores from the previous frame, so skipping the commit drops
    /// everything the next frame does not repaint.
    pub fn commit_frame(self: *TerminalCanvas) void {
        std.debug.assert(self.width > 0);
        std.debug.assert(self.text_entries.items.len <= limits.text_entries_max);
        const pixel_count = @as(usize, self.width) * self.height;
        @memcpy(
            self.previous_buffer[0..pixel_count],
            self.buffer[0..pixel_count],
        );
        self.selection.commit(
            self.text_entries.items,
            self.previous_text_entries.items,
        );
        const old_previous_positions = self.previous_text_position_indices;
        self.previous_text_position_indices = self.text_position_indices;
        self.text_position_indices = old_previous_positions;
        for (self.previous_text_entries.items) |entry| {
            const position = text_position_index(entry.x, entry.y);
            self.text_position_indices[position] = text_index_none;
        }
        self.previous_text_entries.clearRetainingCapacity();
        self.previous_text_entries.appendSliceAssumeCapacity(
            self.text_entries.items,
        );
        self.text_entries.clearRetainingCapacity();
        self.previous_image_placement = self.image_placement;
        self.image_placement = null;
    }

    fn mark_text_restore_cells(self: *TerminalCanvas, value: bool) bool {
        std.debug.assert(self.text_restore_cells.len > 0);
        std.debug.assert(self.width > 0);
        var cells_changed = false;
        for (self.previous_text_entries.items) |previous| {
            const position = text_position_index(previous.x, previous.y);
            const current_index = self.text_position_indices[position];
            const restore_start = if (current_index == text_index_none)
                0
            else
                @min(
                    previous.text_length,
                    self.text_entries.items[current_index].text_length,
                );
            if (restore_start >= previous.text_length) continue;
            var offset = restore_start;
            while (offset < previous.text_length) : (offset += 1) {
                const cell = text_position_index(previous.x + offset, previous.y);
                self.text_restore_cells[cell] = value;
                cells_changed = true;
            }
        }
        return cells_changed;
    }

    pub fn enter_alternate_screen(io: std.Io) !void {
        try std.Io.File.stdout().writeStreamingAll(
            io,
            "\x1B[?1049h\x1B[?1000h\x1B[?1002h\x1B[?1006h",
        );
    }

    pub fn exit_alternate_screen(io: std.Io) !void {
        try std.Io.File.stdout().writeStreamingAll(
            io,
            "\x1B[?1006l\x1B[?1002l\x1B[?1000l\x1B[?1049l\x1B[?25h\x1B[0 q",
        );
    }
};

fn sixel_prepare_task(
    canvas: *TerminalCanvas,
    io: std.Io,
) std.Io.Cancelable!void {
    const placement = canvas.sixel_preparing orelse return;
    std.debug.assert(placement.width > 0);
    std.debug.assert(canvas.sixel_bitmap_buffer.len > 0);
    const outcome: SixelOutcome = if (image.prepare_sixel(
        io,
        &placement,
        canvas.sixel_bitmap_buffer,
    )) |length|
        .{ .success = length }
    else |err|
        .{ .failure = err };
    canvas.sixel_results.putOne(io, outcome) catch |err| switch (err) {
        error.Closed => return,
        error.Canceled => return error.Canceled,
    };
}

test "canvas rejects invalid dimensions and frame rates" {
    try std.testing.expectError(
        error.ZeroCanvasDimension,
        TerminalCanvas.init(std.testing.allocator, 0, 1),
    );
    try std.testing.expectError(
        error.CanvasTooWide,
        TerminalCanvas.init(std.testing.allocator, limits.canvas_width_max + 1, 1),
    );

    var canvas = try TerminalCanvas.init(std.testing.allocator, 4, 4);
    defer canvas.deinit();
    try std.testing.expectError(error.InvalidFrameRate, canvas.set_refresh_limit(0));
    try std.testing.expectError(
        error.CanvasTooTall,
        canvas.resize(4, limits.canvas_height_max + 1),
    );
    try std.testing.expectEqual(@as(u16, 4), canvas.width);
    try std.testing.expectEqual(@as(u16, 4), canvas.height);
}

test "canvas validates text boundaries and duplicate positions" {
    var canvas = try TerminalCanvas.init(std.testing.allocator, 4, 4);
    defer canvas.deinit();
    const white = Color.from_rgb(255, 255, 255);

    try std.testing.expectError(
        error.TextOutOfBounds,
        canvas.add_text(3, 0, "ab", white, null),
    );
    try canvas.add_text(0, 0, "ok", white, null);
    try std.testing.expectError(
        error.DuplicateTextPosition,
        canvas.add_text(0, 0, "no", white, null),
    );
    canvas.commit_frame();
    try canvas.add_text(0, 0, "next", white, null);
}

test "text released during a partial frame is not emitted" {
    // A partial frame carries the previous frame's text forward. Clearing a
    // cell releases it but leaves the record in text_entries; emitting those
    // paints the previous frame over the new one -- which looked like two
    // views drawn on top of each other.
    // Mirrors one view handing the screen to another: some cells are cleared
    // and repainted, others are cleared and left to the new content.
    var canvas = try TerminalCanvas.init(std.testing.allocator, 40, 8);
    defer canvas.deinit();
    const background = Color.from_rgb(17, 19, 22);
    const foreground = Color.from_rgb(200, 200, 200);
    canvas.filled_rect(0, 0, canvas.width, canvas.height, background);
    try canvas.add_text(0, 0, "READER", foreground, background);
    try canvas.add_text(0, 1, "FEEDS", foreground, background);
    canvas.commit_frame();

    canvas.start_partial_frame(background);
    canvas.clear_rect(Rect.init(0, 0, 40, 4), background);
    try canvas.add_text(0, 0, "BROWSE", foreground, background);
    var writer = std.Io.Writer.fixed(canvas.output_buffer);
    try canvas.write_frame_patches(&writer);
    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "BROWSE") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "READER") == null);
    // Removing text arms the cell-restore path, which used to re-emit the very
    // text that was removed.
    try std.testing.expect(std.mem.indexOf(u8, output, "FEEDS") == null);
}

test "text cleared and not replaced stops being emitted" {
    var canvas = try TerminalCanvas.init(std.testing.allocator, 20, 4);
    defer canvas.deinit();
    const background = Color.from_rgb(17, 19, 22);
    const foreground = Color.from_rgb(200, 200, 200);
    canvas.filled_rect(0, 0, canvas.width, canvas.height, background);
    try canvas.add_text(4, 1, "GONE", foreground, background);
    canvas.commit_frame();

    canvas.start_partial_frame(background);
    canvas.clear_rect(Rect.init(0, 1, 20, 1), background);
    var writer = std.Io.Writer.fixed(canvas.output_buffer);
    try canvas.write_frame_patches(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "GONE") == null);
}

test "removed text restores its unchanged canvas cells" {
    var canvas = try TerminalCanvas.init(std.testing.allocator, 8, 4);
    defer canvas.deinit();
    const background = Color.from_rgb(17, 19, 22);
    const foreground = Color.from_rgb(200, 200, 200);
    canvas.filled_rect(0, 0, canvas.width, canvas.height, background);
    try canvas.add_text(2, 1, "----", foreground, background);
    canvas.commit_frame();

    canvas.filled_rect(0, 0, canvas.width, canvas.height, background);
    var writer = std.Io.Writer.fixed(canvas.output_buffer);
    try canvas.write_frame_patches(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "▀") != null);
    canvas.commit_frame();

    canvas.filled_rect(0, 0, canvas.width, canvas.height, background);
    var unchanged_writer = std.Io.Writer.fixed(canvas.output_buffer);
    try canvas.write_frame_patches(&unchanged_writer);
    try std.testing.expectEqual(@as(usize, 0), unchanged_writer.buffered().len);
}

test "fixed output storage covers maximum changing frame" {
    var canvas = try TerminalCanvas.init(
        std.testing.allocator,
        limits.canvas_width_max,
        limits.canvas_height_max,
    );
    defer canvas.deinit();
    const red = Color.from_rgb(255, 0, 0);
    const blue = Color.from_rgb(0, 0, 255);

    var y: u16 = 0;
    while (y < canvas.height) : (y += 1) {
        var x: u16 = 0;
        while (x < canvas.width) : (x += 1) {
            canvas.set_pixel(x, y, if ((x + y) % 2 == 0) red else blue);
        }
    }
    var entry_index: u16 = 0;
    while (entry_index < limits.text_entries_max) : (entry_index += 1) {
        const text_x = entry_index / 256;
        const text_y = entry_index % 256;
        try canvas.add_text(text_x, text_y, "x", red, blue);
    }

    var writer = std.Io.Writer.fixed(canvas.output_buffer);
    try canvas.write_pixel_patches(&writer);
    try canvas.write_text_patches(&writer, false);
    try std.testing.expect(writer.buffered().len <= limits.output_bytes_max);
    try std.testing.expectError(
        error.TooManyTextEntries,
        canvas.add_text(0, 0, "x", red, blue),
    );
}

test "selection patches text bytes without repainting background pixels" {
    var canvas = try TerminalCanvas.init(std.testing.allocator, 8, 4);
    defer canvas.deinit();
    const background = Color.from_rgb(17, 19, 22);
    const foreground = Color.from_rgb(200, 200, 200);
    canvas.filled_rect(0, 0, canvas.width, canvas.height, background);
    const selection_style = TextSelectionStyle{
        .foreground = foreground,
        .background = Color.from_rgb(20, 30, 40),
        .active_background = Color.from_rgb(30, 40, 50),
        .anchor_background = Color.from_rgb(40, 50, 60),
        .cursor_foreground = background,
        .cursor_background = Color.from_rgb(200, 180, 90),
    };
    try canvas.add_selection_region(Rect.init(0, 0, 4, 2), selection_style);
    try canvas.add_text(0, 0, "abc", foreground, background);
    canvas.commit_frame();

    _ = canvas.handle_pointer(.{
        .x = 1,
        .y = 0,
        .action = .press,
        .button = .primary,
    });
    _ = canvas.handle_pointer(.{
        .x = 7,
        .y = 0,
        .action = .drag,
        .button = .primary,
    });
    canvas.filled_rect(0, 0, canvas.width, canvas.height, background);
    try canvas.add_selection_region(Rect.init(0, 0, 4, 2), selection_style);
    try canvas.add_text(0, 0, "abc", foreground, background);

    var writer = std.Io.Writer.fixed(canvas.output_buffer);
    try canvas.write_frame_patches(&writer);
    try std.testing.expect(std.mem.indexOf(
        u8,
        writer.buffered(),
        "\x1B[48;2;40;50;60m",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1B[7m") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "▀") == null);
}

test "terminal colors emit default and ANSI control sequences" {
    var output: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try TerminalCanvas.write_colors(
        &writer,
        Color.terminal_foreground(),
        Color.terminal_background(),
    );
    try std.testing.expectEqualStrings("\x1B[39m\x1B[49m", writer.buffered());

    writer = std.Io.Writer.fixed(&output);
    var previous: ?PixelColors = null;
    const inherited = PixelColors{
        .upper = Color.terminal_background(),
        .lower = Color.terminal_background(),
    };
    try TerminalCanvas.write_pixel(&writer, inherited, &previous);
    try std.testing.expectEqualStrings("\x1B[49m ", writer.buffered());

    writer = std.Io.Writer.fixed(&output);
    previous = null;
    const lower_cyan = PixelColors{
        .upper = Color.terminal_background(),
        .lower = Color.ansi(6),
    };
    try TerminalCanvas.write_pixel(&writer, lower_cyan, &previous);
    try std.testing.expectEqualStrings("\x1B[36m\x1B[49m▄", writer.buffered());
}

test "typography changes produce text-only patches" {
    var canvas = try TerminalCanvas.init(std.testing.allocator, 12, 4);
    defer canvas.deinit();
    const foreground = Color.from_rgb(230, 230, 230);
    const background = Color.from_rgb(20, 22, 24);
    canvas.filled_rect(0, 0, canvas.width, canvas.height, background);
    try canvas.add_styled_text(1, 1, "PATCH", foreground, background, .{});
    canvas.commit_frame();

    canvas.filled_rect(0, 0, canvas.width, canvas.height, background);
    try canvas.add_styled_text(
        1,
        1,
        "PATCH",
        foreground,
        background,
        .{ .bold = true, .underline = true },
    );
    var writer = std.Io.Writer.fixed(canvas.output_buffer);
    try canvas.write_frame_patches(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1B[1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1B[4m") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "▀") == null);
}
