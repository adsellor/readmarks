const std = @import("std");
const limits = @import("limits.zig");
const sixel = @import("sixel.zig");
const terminal = @import("terminal.zig");
const Rect = @import("../../layout/rect.zig").Rect;

pub const Protocol = enum { none, kitty, sixel };

const image_id: u32 = 1;
const coordinate_max: i32 = std.math.maxInt(u16);

pub const Placement = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    crop_top_rows: u16,
    full_height_rows: u16,
    path: [limits.image_path_bytes_max]u8 = undefined,
    path_length: u16,

    pub fn init(
        visible: Rect,
        crop_top_rows: u16,
        full_height_rows: u16,
        path: []const u8,
    ) !Placement {
        if (path.len == 0 or path.len > limits.image_path_bytes_max) {
            return error.InvalidImagePath;
        }
        if (visible.width <= 0 or visible.height <= 0) return error.InvalidImageSize;
        if (visible.x < 0 or visible.y < 0) return error.ImageOutOfBounds;
        if (visible.right() > coordinate_max or visible.bottom() > coordinate_max) {
            return error.ImageOutOfBounds;
        }
        if (@as(i32, crop_top_rows) + visible.height > full_height_rows) {
            return error.InvalidImageCrop;
        }
        var placement = Placement{
            .x = @intCast(visible.x),
            .y = @intCast(visible.y),
            .width = @intCast(visible.width),
            .height = @intCast(visible.height),
            .crop_top_rows = crop_top_rows,
            .full_height_rows = full_height_rows,
            .path_length = @intCast(path.len),
        };
        @memcpy(placement.path[0..path.len], path);
        std.debug.assert(placement.height <= placement.full_height_rows);
        std.debug.assert(placement.path_length > 0);
        return placement;
    }

    pub fn path_bytes(self: *const Placement) []const u8 {
        std.debug.assert(self.path_length <= self.path.len);
        return self.path[0..self.path_length];
    }

    pub fn rect(self: *const Placement) Rect {
        return Rect.init(self.x, self.y, self.width, self.height);
    }

    pub fn equals(self: *const Placement, other: *const Placement) bool {
        return self.x == other.x and
            self.y == other.y and
            self.width == other.width and
            self.height == other.height and
            self.crop_top_rows == other.crop_top_rows and
            self.full_height_rows == other.full_height_rows and
            self.same_image(other);
    }

    pub fn same_image(self: *const Placement, other: *const Placement) bool {
        return std.mem.eql(u8, self.path_bytes(), other.path_bytes());
    }

    fn sixel_options(self: *const Placement) sixel.Options {
        return .{
            .path = self.path_bytes(),
            .x = self.x,
            .y = self.y,
            .width_cells = self.width,
            .height_cells = self.height,
            .crop_top_rows = self.crop_top_rows,
            .full_height_rows = self.full_height_rows,
        };
    }
};

pub fn detect(capabilities: terminal.GraphicsCapabilities, override: ?[]const u8) Protocol {
    if (override) |value| {
        if (std.ascii.eqlIgnoreCase(value, "none")) return .none;
        if (std.ascii.eqlIgnoreCase(value, "kitty")) return .kitty;
        if (std.ascii.eqlIgnoreCase(value, "sixel")) return .sixel;
    }
    if (capabilities.sixel and sixel.supported) return .sixel;
    if (capabilities.kitty) return .kitty;
    return .none;
}

const Outcome = union(enum) { success: u32, failure: anyerror };
const Results = std.Io.Queue(Outcome);

pub const Graphics = struct {
    protocol: Protocol,
    requested: ?Placement = null,
    shown: ?Placement = null,
    uploaded: ?Placement = null,
    preparing: ?Placement = null,
    ready: ?Placement = null,
    bitmap_length: u32 = 0,
    scratch: sixel.Scratch,
    outcomes: []Outcome,
    results: Results,
    task: std.Io.Group = .init,
    task_io: ?std.Io = null,

    pub fn alloc(gpa: std.mem.Allocator, protocol: Protocol) !Graphics {
        const sixel_bitmap_bytes = if (protocol == .sixel) limits.sixel_bitmap_bytes_max else 0;
        const sixel_output_bytes = if (protocol == .sixel) limits.sixel_output_bytes_max else 0;
        const bitmap = try gpa.alloc(u8, sixel_bitmap_bytes);
        errdefer gpa.free(bitmap);
        const output = try gpa.alloc(u8, sixel_output_bytes);
        errdefer gpa.free(output);
        const outcomes = try gpa.alloc(Outcome, 1);
        std.debug.assert(bitmap.len == sixel_bitmap_bytes);
        std.debug.assert(outcomes.len == 1);
        return .{
            .protocol = protocol,
            .scratch = .{ .bitmap = bitmap, .output = output },
            .outcomes = outcomes,
            .results = .init(outcomes),
        };
    }

    pub fn free(self: *Graphics, gpa: std.mem.Allocator) void {
        if (self.task_io) |io| {
            self.task.cancel(io);
            self.results.close(io);
        }
        gpa.free(self.scratch.bitmap);
        gpa.free(self.scratch.output);
        gpa.free(self.outcomes);
        self.* = undefined;
    }

    pub fn request(self: *Graphics, placement: Placement) void {
        if (self.protocol == .none) return;
        if (self.requested != null) return;
        self.requested = placement;
    }

    pub fn cover(self: *Graphics, area: Rect) void {
        const placement = self.requested orelse return;
        if (placement.rect().overlaps(area)) self.requested = null;
    }

    pub fn stale(self: *const Graphics) ?Rect {
        if (self.protocol != .sixel) return null;
        const shown = self.shown orelse return null;
        if (self.requested) |*current| {
            if (current.equals(&shown)) return null;
        }
        return shown.rect();
    }

    pub fn flush(self: *Graphics, io: std.Io, written: ?[]const Rect) void {
        const current = self.requested;
        self.requested = null;
        switch (self.protocol) {
            .none => {},
            .kitty => self.show_kitty(io, current) catch {
                write_kitty_delete(io) catch {};
                self.disable();
            },
            .sixel => self.show_sixel(io, current, written) catch self.disable(),
        }
    }

    pub fn poll(self: *Graphics, io: std.Io) !bool {
        std.debug.assert(self.outcomes.len == 1);
        const prepared = self.preparing orelse return false;
        std.debug.assert(self.protocol == .sixel or self.protocol == .none);
        var completed: [1]Outcome = undefined;
        const count = self.results.get(io, &completed, 0) catch |err| {
            return switch (err) {
                error.Closed => false,
                error.Canceled => err,
            };
        };
        if (count == 0) return false;
        try self.task.await(io);
        self.preparing = null;
        switch (completed[0]) {
            .success => |length| {
                self.ready = prepared;
                self.bitmap_length = length;
            },
            .failure => self.disable(),
        }
        self.shown = null;
        return true;
    }

    fn show_kitty(self: *Graphics, io: std.Io, current: ?Placement) !void {
        std.debug.assert(self.protocol == .kitty);
        if (self.shown) |*shown| {
            const next = if (current) |*placement| placement else null;
            if (next != null and next.?.equals(shown)) return;
            if (next == null or !next.?.same_image(shown)) try write_kitty_delete(io);
        }
        self.shown = null;
        const next = current orelse return;
        const fresh = if (self.uploaded) |*uploaded| !uploaded.same_image(&next) else true;
        if (fresh) {
            self.uploaded = null;
            try upload_kitty(io, &next);
            self.uploaded = next;
        }
        try place_kitty(io, &next);
        self.shown = next;
        std.debug.assert(self.uploaded != null);
    }

    fn show_sixel(
        self: *Graphics,
        io: std.Io,
        current: ?Placement,
        written: ?[]const Rect,
    ) !void {
        std.debug.assert(self.protocol == .sixel);
        const next = current orelse {
            self.shown = null;
            return;
        };
        if (self.shown) |*shown| {
            if (next.equals(shown) and !overwritten(shown.rect(), written)) return;
        }
        self.shown = null;
        if (!self.is_ready(&next)) return self.start_prepare(io, &next);
        std.debug.assert(self.bitmap_length > 0);
        try sixel.display(io, next.sixel_options(), self.scratch, self.bitmap_length);
        self.shown = next;
    }

    fn is_ready(self: *const Graphics, placement: *const Placement) bool {
        if (self.preparing != null) return false;
        const ready = self.ready orelse return false;
        return ready.width == placement.width and
            ready.full_height_rows == placement.full_height_rows and
            ready.same_image(placement);
    }

    fn start_prepare(self: *Graphics, io: std.Io, placement: *const Placement) !void {
        if (self.preparing != null) return;
        std.debug.assert(self.scratch.bitmap.len > 0);
        self.ready = null;
        self.bitmap_length = 0;
        self.preparing = placement.*;
        self.task_io = io;
        self.task.concurrent(io, prepare_task, .{ self, io }) catch |err| {
            self.preparing = null;
            return err;
        };
    }

    fn disable(self: *Graphics) void {
        self.protocol = .none;
        self.shown = null;
        self.uploaded = null;
        self.ready = null;
        self.bitmap_length = 0;
    }
};

fn prepare_task(graphics: *Graphics, io: std.Io) std.Io.Cancelable!void {
    const placement = graphics.preparing orelse return;
    std.debug.assert(placement.width > 0);
    std.debug.assert(graphics.scratch.bitmap.len >= limits.sixel_bitmap_bytes_max);
    const outcome: Outcome = if (sixel.prepare(
        io,
        placement.sixel_options(),
        graphics.scratch.bitmap,
    )) |length|
        .{ .success = length }
    else |err|
        .{ .failure = err };
    graphics.results.putOne(io, outcome) catch |err| switch (err) {
        error.Closed => return,
        error.Canceled => return error.Canceled,
    };
}

fn overwritten(area: Rect, written: ?[]const Rect) bool {
    const regions = written orelse return true;
    for (regions) |region| {
        if (region.overlaps(area)) return true;
    }
    return false;
}

fn upload_kitty(io: std.Io, placement: *const Placement) !void {
    std.debug.assert(placement.path_length > 0);
    var file = try std.Io.Dir.openFileAbsolute(io, placement.path_bytes(), .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size == 0 or stat.size > limits.image_file_bytes_max) {
        return error.InvalidImageFileSize;
    }
    var source: [limits.image_chunk_bytes]u8 = undefined;
    var offset: u64 = 0;
    while (offset < stat.size) {
        const count = try file.readStreaming(io, &.{&source});
        if (count == 0) return error.UnexpectedEndOfImage;
        const final = offset + count >= stat.size;
        try write_kitty_chunk(io, source[0..count], offset == 0, !final);
        offset += count;
    }
    std.debug.assert(offset >= stat.size);
}

fn write_kitty_chunk(io: std.Io, source: []const u8, first: bool, more: bool) !void {
    std.debug.assert(source.len > 0);
    std.debug.assert(source.len <= limits.image_chunk_bytes);
    var output: [limits.image_chunk_output_bytes_max]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var encoded: [limits.image_chunk_encoded_bytes]u8 = undefined;
    const payload = std.base64.standard.Encoder.encode(&encoded, source);
    if (first) {
        try writer.print(
            "\x1B_Ga=t,f=100,t=d,q=2,i={d},m={d};",
            .{ image_id, @intFromBool(more) },
        );
    } else {
        try writer.print("\x1B_Gq=2,m={d};", .{@intFromBool(more)});
    }
    try writer.writeAll(payload);
    try writer.writeAll("\x1B\\");
    try std.Io.File.stdout().writeStreamingAll(io, writer.buffered());
}

fn write_kitty_delete(io: std.Io) !void {
    var output: [64]u8 = undefined;
    const command = try std.fmt.bufPrint(&output, "\x1B_Ga=d,d=i,q=2,i={d},p=1\x1B\\", .{image_id});
    try std.Io.File.stdout().writeStreamingAll(io, command);
}

fn place_kitty(io: std.Io, placement: *const Placement) !void {
    std.debug.assert(placement.width > 0);
    std.debug.assert(placement.full_height_rows > 0);
    const dimensions = try png_dimensions(io, placement.path_bytes());
    var output: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try write_kitty_place(&writer, placement, dimensions);
    try std.Io.File.stdout().writeStreamingAll(io, writer.buffered());
}

fn write_kitty_place(
    writer: *std.Io.Writer,
    placement: *const Placement,
    dimensions: Dimensions,
) !void {
    std.debug.assert(dimensions.width > 0);
    std.debug.assert(dimensions.height > 0);
    const full = placement.full_height_rows;
    const crop_top = placement.crop_top_rows;
    const crop_y = scaled_row(dimensions.height, crop_top, full);
    const crop_end = scaled_row(dimensions.height, crop_top + placement.height, full);
    try writer.print("\x1B[{d};{d}H", .{ placement.y + 1, placement.x + 1 });
    try writer.print(
        "\x1B_Ga=p,q=2,i={d},p=1,x=0,y={d},w={d},h={d},c={d},r={d},z=1,C=1;\x1B\\",
        .{
            image_id,
            crop_y,
            dimensions.width,
            @max(crop_end - crop_y, 1),
            placement.width,
            placement.height,
        },
    );
}

const Dimensions = struct { width: u32, height: u32 };

fn png_dimensions(io: std.Io, path: []const u8) !Dimensions {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var header: [24]u8 = undefined;
    const count = try file.readPositionalAll(io, &header, 0);
    if (count != header.len) return error.InvalidPngHeader;
    return parse_png_dimensions(&header);
}

fn parse_png_dimensions(header: *const [24]u8) !Dimensions {
    if (!std.mem.eql(u8, header[0..8], "\x89PNG\r\n\x1a\n")) return error.InvalidPngHeader;
    const width = std.mem.readInt(u32, header[16..20], .big);
    const height = std.mem.readInt(u32, header[20..24], .big);
    if (width == 0 or height == 0) return error.InvalidPngDimensions;
    return .{ .width = width, .height = height };
}

fn scaled_row(image_height: u32, row: u32, full_height: u16) u32 {
    std.debug.assert(full_height > 0);
    std.debug.assert(row <= full_height);
    return @intCast(@divFloor(@as(u64, image_height) * row, full_height));
}

const testing = std.testing;

test "detection prefers sixel only where it can be converted" {
    try testing.expectEqual(Protocol.kitty, detect(.{ .kitty = true }, null));
    try testing.expectEqual(Protocol.none, detect(.{}, null));
    try testing.expectEqual(Protocol.sixel, detect(.{}, "sixel"));
    try testing.expectEqual(Protocol.none, detect(.{ .kitty = true }, "NONE"));
    const both = detect(.{ .kitty = true, .sixel = true }, null);
    try testing.expectEqual(if (sixel.supported) Protocol.sixel else Protocol.kitty, both);
}

test "a placement keeps its crop inside the full image" {
    const placement = try Placement.init(Rect.init(2, 0, 10, 4), 6, 10, "/tmp/a.png");
    try testing.expectEqual(@as(u16, 6), placement.crop_top_rows);
    try testing.expectEqualStrings("/tmp/a.png", placement.path_bytes());
    try testing.expectError(
        error.InvalidImageCrop,
        Placement.init(Rect.init(0, 0, 10, 5), 6, 10, "/tmp/a.png"),
    );
    try testing.expectError(
        error.ImageOutOfBounds,
        Placement.init(Rect.init(-1, 0, 10, 4), 0, 10, "/tmp/a.png"),
    );
    try testing.expectError(
        error.InvalidImagePath,
        Placement.init(Rect.init(0, 0, 1, 1), 0, 1, ""),
    );
}

test "moving an image keeps it the same image" {
    const first = try Placement.init(Rect.init(0, 0, 10, 4), 0, 10, "/tmp/a.png");
    const moved = try Placement.init(Rect.init(0, 0, 10, 4), 2, 10, "/tmp/a.png");
    const other = try Placement.init(Rect.init(0, 0, 10, 4), 0, 10, "/tmp/b.png");
    try testing.expect(!first.equals(&moved));
    try testing.expect(first.same_image(&moved));
    try testing.expect(!first.same_image(&other));
}

test "a kitty placement crops the source rows it shows" {
    const placement = try Placement.init(Rect.init(3, 1, 20, 5), 5, 10, "/tmp/a.png");
    var output: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try write_kitty_place(&writer, &placement, .{ .width = 640, .height = 400 });
    try testing.expectEqualStrings(
        "\x1B[2;4H\x1B_Ga=p,q=2,i=1,p=1,x=0,y=200,w=640,h=200,c=20,r=5,z=1,C=1;\x1B\\",
        writer.buffered(),
    );
}

test "png headers give the pixel size" {
    var header: [24]u8 = @splat(0);
    @memcpy(header[0..8], "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, header[16..20], 640, .big);
    std.mem.writeInt(u32, header[20..24], 400, .big);
    const dimensions = try parse_png_dimensions(&header);
    try testing.expectEqual(@as(u32, 640), dimensions.width);
    header[0] = 0;
    try testing.expectError(error.InvalidPngHeader, parse_png_dimensions(&header));
}

test "covering a requested image withdraws it" {
    var graphics = try Graphics.alloc(testing.allocator, .kitty);
    defer graphics.free(testing.allocator);
    graphics.request(try Placement.init(Rect.init(0, 0, 10, 4), 0, 4, "/tmp/a.png"));
    graphics.request(try Placement.init(Rect.init(0, 5, 10, 4), 0, 4, "/tmp/b.png"));
    try testing.expectEqualStrings("/tmp/a.png", graphics.requested.?.path_bytes());
    graphics.cover(Rect.init(20, 0, 5, 5));
    try testing.expect(graphics.requested != null);
    graphics.cover(Rect.init(5, 2, 5, 5));
    try testing.expect(graphics.requested == null);
    try testing.expect(graphics.stale() == null);
}
