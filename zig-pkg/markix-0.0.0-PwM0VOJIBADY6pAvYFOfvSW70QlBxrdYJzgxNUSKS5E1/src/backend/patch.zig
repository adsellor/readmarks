const std = @import("std");
const canvas = @import("canvas.zig");
const rect_mod = @import("../layout/rect.zig");

const Frame = canvas.Frame;
const Draw = canvas.Draw;
const Rect = rect_mod.Rect;

pub const magic: u32 = 0x5450584d;
pub const version: u32 = 1;

pub const header_size: usize = 28;
pub const flag_full: u32 = 1;

pub const Op = enum(u8) {
    clear = 0,
    fill = 1,
    text = 2,
};

pub const damage_max: usize = 64;

pub const Stats = struct {
    damaged: u32 = 0,
    drawn: u32 = 0,
    total: u32 = 0,
    ops: u32 = 0,
    bytes: u32 = 0,
    full: bool = false,
};

pub const Patch = struct {
    bytes: []u8,
    len: usize = 0,
    stats: Stats = .{},

    pub fn init(storage: []u8) Patch {
        std.debug.assert(storage.len >= header_size);
        return .{ .bytes = storage };
    }

    pub fn slice(self: *const Patch) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub fn write(patch: *Patch, previous: *const Frame, next: *const Frame) void {
    std.debug.assert(patch.bytes.len >= header_size);
    std.debug.assert(next.len <= next.items.len);
    patch.len = 0;
    patch.stats = .{ .total = @intCast(next.len) };

    var damage: [damage_max]Rect = undefined;
    if (regions(&damage, previous, next)) |dirty| {
        if (dirty.len == 0) {
            finish(patch, next, 0, 0, 0);
            return;
        }
        if (partial(patch, next, dirty)) return;
    }
    full(patch, next);
}

pub fn regions(into: []Rect, previous: *const Frame, next: *const Frame) ?[]Rect {
    std.debug.assert(into.len > 0);
    std.debug.assert(next.len <= next.items.len);
    const count = collect(into, previous, next) orelse return null;
    std.debug.assert(count <= into.len);
    return into[0..count];
}

pub fn merge_region(into: []Rect, count: *usize, box: Rect) bool {
    std.debug.assert(into.len > 0);
    std.debug.assert(count.* <= into.len);
    return add(into, count, box);
}

fn collect(damage: []Rect, previous: *const Frame, next: *const Frame) ?usize {
    std.debug.assert(damage.len > 0);
    std.debug.assert(next.len <= next.items.len);
    if (!previous.drawn) return null;
    if (previous.len != next.len) return null;
    if (previous.truncated or next.truncated) return null;
    if (previous.background != next.background) return null;
    if (previous.width != next.width or previous.height != next.height) return null;

    var count: usize = 0;
    for (previous.slice(), next.slice()) |was, now| {
        if (was.node != now.node) return null;
        if (was.eql(now)) continue;
        if (!add(damage, &count, was.damage)) return null;
        if (!add(damage, &count, now.damage)) return null;
    }
    return count;
}

fn add(damage: []Rect, count: *usize, box: Rect) bool {
    std.debug.assert(count.* <= damage.len);
    std.debug.assert(damage.len > 0);
    if (box.width <= 0 or box.height <= 0) return true;
    var index: usize = 0;
    while (index < count.*) : (index += 1) {
        if (touches(damage[index], box)) {
            damage[index] = merge(damage[index], box);
            var at = index;
            coalesce(damage, count, &at);
            return true;
        }
    }
    if (count.* == damage.len) return false;
    damage[count.*] = box;
    count.* += 1;
    return true;
}

fn coalesce(damage: []Rect, count: *usize, at: *usize) void {
    std.debug.assert(count.* <= damage.len);
    var index: usize = 0;
    while (index < count.*) {
        if (index == at.* or !touches(damage[at.*], damage[index])) {
            index += 1;
            continue;
        }
        damage[at.*] = merge(damage[at.*], damage[index]);
        count.* -= 1;
        damage[index] = damage[count.*];
        if (at.* == count.*) at.* = index;
        index = 0;
    }
    std.debug.assert(at.* < count.*);
}

fn touches(a: Rect, b: Rect) bool {
    return a.x <= b.right() and b.x <= a.right() and
        a.y <= b.bottom() and b.y <= a.bottom();
}

fn merge(a: Rect, b: Rect) Rect {
    const x = @min(a.x, b.x);
    const y = @min(a.y, b.y);
    return .{
        .x = x,
        .y = y,
        .width = @max(a.right(), b.right()) - x,
        .height = @max(a.bottom(), b.bottom()) - y,
    };
}

fn partial(patch: *Patch, next: *const Frame, damage: []const Rect) bool {
    std.debug.assert(damage.len <= damage_max);
    std.debug.assert(patch.bytes.len >= header_size);
    var at: usize = header_size;
    var drawn: u32 = 0;
    for (damage) |region| {
        if (!put_rect(patch, &at, .clear, region, next.background)) return false;
        for (next.slice()) |draw| {
            if (!region.overlaps(draw.damage)) continue;
            if (!put_draw(patch, &at, draw)) return false;
            drawn += 1;
        }
    }

    patch.stats.damaged = @intCast(damage.len);
    finish(patch, next, at, drawn, drawn + @as(u32, @intCast(damage.len)));
    return true;
}

fn full(patch: *Patch, next: *const Frame) void {
    var at: usize = header_size;
    var drawn: u32 = 0;
    const whole = Rect{ .x = 0, .y = 0, .width = next.width, .height = next.height };
    _ = put_rect(patch, &at, .clear, whole, next.background);
    for (next.slice()) |draw| {
        if (!put_draw(patch, &at, draw)) break;
        drawn += 1;
    }
    patch.stats.full = true;
    patch.stats.damaged = 1;
    finish(patch, next, at, drawn, drawn + 1);
}

fn finish(patch: *Patch, next: *const Frame, end: usize, drawn: u32, ops: u32) void {
    const at = @max(end, header_size);
    std.debug.assert(at <= patch.bytes.len);
    std.debug.assert(ops >= drawn);
    put_u32(patch.bytes, 0, magic);
    put_u32(patch.bytes, 4, version);
    put_u32(patch.bytes, 8, if (patch.stats.full) flag_full else 0);
    put_u32(patch.bytes, 12, ops);
    put_u32(patch.bytes, 16, next.background);
    put_u32(patch.bytes, 20, @intCast(@max(0, next.width)));
    put_u32(patch.bytes, 24, @intCast(@max(0, next.height)));
    patch.len = at;
    patch.stats.drawn = drawn;
    patch.stats.ops = ops;
    patch.stats.bytes = @intCast(at);
}

const op_size: usize = 16;

fn put_draw(patch: *Patch, at: *usize, draw: Draw) bool {
    if (draw.kind == .fill) {
        return put_rect(patch, at, .fill, draw.rect, draw.color);
    }
    if (at.* + op_size + 2 + draw.text.len > patch.bytes.len) return false;
    if (!put_rect(patch, at, .text, draw.rect, draw.color)) return false;
    const length: u16 = @intCast(@min(draw.text.len, 0x7fff));
    put_u16(patch.bytes, at.*, length | (if (draw.bold) @as(u16, 0x8000) else 0));
    at.* += 2;
    @memcpy(patch.bytes[at.*..][0..length], draw.text[0..length]);
    at.* += length;
    return true;
}

fn put_rect(patch: *Patch, at: *usize, kind: Op, box: Rect, color: u32) bool {
    if (at.* + op_size > patch.bytes.len) return false;
    patch.bytes[at.*] = @backingInt(kind);
    patch.bytes[at.* + 1] = 0;
    patch.bytes[at.* + 2] = 0;
    patch.bytes[at.* + 3] = 0;
    put_i16(patch.bytes, at.* + 4, box.x);
    put_i16(patch.bytes, at.* + 6, box.y);
    put_i16(patch.bytes, at.* + 8, box.width);
    put_i16(patch.bytes, at.* + 10, box.height);
    put_u32(patch.bytes, at.* + 12, color);
    at.* += op_size;
    return true;
}

fn put_u32(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}

fn put_u16(bytes: []u8, at: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[at..][0..2], value, .little);
}

fn put_i16(bytes: []u8, at: usize, value: i32) void {
    const clamped = std.math.clamp(value, std.math.minInt(i16), std.math.maxInt(i16));
    std.mem.writeInt(i16, bytes[at..][0..2], @intCast(clamped), .little);
}

const testing = std.testing;

fn frame_of(storage: []Draw, draws: []const Draw) Frame {
    var frame = Frame.init(storage);
    for (draws) |draw| {
        frame.items[frame.len] = draw;
        frame.len += 1;
    }
    frame.width = 100;
    frame.height = 50;
    frame.drawn = true;
    return frame;
}

fn cell(node: u32, x: i32, color: u32) Draw {
    const box = Rect{ .x = x, .y = 10, .width = 9, .height = 9 };
    return .{
        .kind = .fill,
        .rect = box,
        .damage = box,
        .color = color,
        .node = node,
    };
}

test "the first frame is drawn whole" {
    var previous_storage: [8]Draw = undefined;
    var next_storage: [8]Draw = undefined;
    var previous = Frame.init(&previous_storage);
    var next = frame_of(&next_storage, &.{ cell(1, 0, 0xff0000), cell(2, 9, 0x00ff00) });

    var bytes: [1024]u8 = undefined;
    var patch = Patch.init(&bytes);
    write(&patch, &previous, &next);

    try testing.expect(patch.stats.full);
    try testing.expectEqual(@as(u32, 2), patch.stats.drawn);
    try testing.expectEqual(@as(u32, 3), patch.stats.ops);
    try testing.expectEqual(magic, std.mem.readInt(u32, bytes[0..4], .little));
    try testing.expectEqual(flag_full, std.mem.readInt(u32, bytes[8..12], .little));
}

test "a frame that did not change carries no operations" {
    var previous_storage: [8]Draw = undefined;
    var next_storage: [8]Draw = undefined;
    var previous = frame_of(&previous_storage, &.{ cell(1, 0, 0xff0000), cell(2, 9, 0x00ff00) });
    var next = frame_of(&next_storage, &.{ cell(1, 0, 0xff0000), cell(2, 9, 0x00ff00) });

    var bytes: [1024]u8 = undefined;
    var patch = Patch.init(&bytes);
    write(&patch, &previous, &next);

    try testing.expect(!patch.stats.full);
    try testing.expectEqual(@as(u32, 0), patch.stats.drawn);
    try testing.expectEqual(header_size, patch.len);
}

test "one box that moved damages one region, not the canvas" {
    var previous_storage: [8]Draw = undefined;
    var next_storage: [8]Draw = undefined;
    var previous = frame_of(&previous_storage, &.{
        cell(1, 0, 0xff0000),
        cell(2, 9, 0x00ff00),
        cell(3, 80, 0x0000ff),
    });
    var next = frame_of(&next_storage, &.{
        cell(1, 0, 0xff0000),
        cell(2, 9, 0x00ff00),
        cell(3, 80, 0x00ffff),
    });

    var bytes: [1024]u8 = undefined;
    var patch = Patch.init(&bytes);
    write(&patch, &previous, &next);

    try testing.expect(!patch.stats.full);
    try testing.expectEqual(@as(u32, 1), patch.stats.damaged);
    try testing.expectEqual(@as(u32, 1), patch.stats.drawn);
    try testing.expectEqual(@as(u32, 3), patch.stats.total);
}

test "neighbours that both moved are one region" {
    var previous_storage: [8]Draw = undefined;
    var next_storage: [8]Draw = undefined;
    var previous = frame_of(&previous_storage, &.{
        cell(1, 0, 0xff0000),
        cell(2, 9, 0x00ff00),
        cell(3, 18, 0x0000ff),
    });
    var next = frame_of(&next_storage, &.{
        cell(1, 0, 0x111111),
        cell(2, 9, 0x222222),
        cell(3, 18, 0x333333),
    });

    var bytes: [1024]u8 = undefined;
    var patch = Patch.init(&bytes);
    write(&patch, &previous, &next);

    try testing.expectEqual(@as(u32, 1), patch.stats.damaged);
    try testing.expectEqual(@as(u32, 3), patch.stats.drawn);
    try testing.expectEqual(@as(u32, 4), patch.stats.ops);
}

test "a tree that changed shape is redrawn rather than mispaired" {
    var previous_storage: [8]Draw = undefined;
    var next_storage: [8]Draw = undefined;
    var previous = frame_of(&previous_storage, &.{ cell(1, 0, 0xff0000), cell(2, 9, 0x00ff00) });
    var next = frame_of(&next_storage, &.{
        cell(1, 0, 0xff0000),
        cell(9, 9, 0x00ff00),
        cell(2, 18, 0x0000ff),
    });

    var bytes: [1024]u8 = undefined;
    var patch = Patch.init(&bytes);
    write(&patch, &previous, &next);
    try testing.expect(patch.stats.full);
}

test "text carries its bytes and its weight" {
    var previous_storage: [4]Draw = undefined;
    var next_storage: [4]Draw = undefined;
    var previous = Frame.init(&previous_storage);
    var next = frame_of(&next_storage, &.{.{
        .kind = .text,
        .rect = .{ .x = 9, .y = 0, .width = 45, .height = 9 },
        .damage = .{ .x = 9, .y = 0, .width = 45, .height = 9 },
        .color = 0xeb6f92,
        .text = "hello",
        .bold = true,
        .node = 1,
    }});

    var bytes: [1024]u8 = undefined;
    var patch = Patch.init(&bytes);
    write(&patch, &previous, &next);

    const at = header_size + op_size;
    try testing.expectEqual(@backingInt(Op.text), bytes[at]);
    const colour = std.mem.readInt(u32, bytes[at + 12 ..][0..4], .little);
    try testing.expectEqual(@as(u32, 0xeb6f92), colour);
    const length = std.mem.readInt(u16, bytes[at + 16 ..][0..2], .little);
    try testing.expectEqual(@as(u16, 0x8000 | 5), length);
    try testing.expectEqualStrings("hello", bytes[at + 18 ..][0..5]);
}

test "a patch that will not fit becomes a full redraw rather than half a frame" {
    var previous_storage: [8]Draw = undefined;
    var next_storage: [8]Draw = undefined;
    var previous = frame_of(&previous_storage, &.{ cell(1, 0, 0xff0000), cell(2, 40, 0x00ff00) });
    var next = frame_of(&next_storage, &.{ cell(1, 0, 0x111111), cell(2, 40, 0x222222) });

    var bytes: [header_size + op_size * 2]u8 = undefined;
    var patch = Patch.init(&bytes);
    write(&patch, &previous, &next);
    try testing.expect(patch.stats.full);
    try testing.expect(patch.len <= bytes.len);
}

const Surface = struct {
    const width: i32 = 96;
    const height: i32 = 48;

    pixels: [@intCast(width * height)]u32 = undefined,
    clip: Rect = .{ .x = 0, .y = 0, .width = width, .height = height },

    fn clear(self: *Surface, color: u32) void {
        @memset(&self.pixels, color);
    }

    fn fill(self: *Surface, box: Rect, color: u32) void {
        var y = @max(@max(0, self.clip.y), box.y);
        while (y < @min(@min(height, self.clip.bottom()), box.bottom())) : (y += 1) {
            var x = @max(@max(0, self.clip.x), box.x);
            while (x < @min(@min(width, self.clip.right()), box.right())) : (x += 1) {
                self.pixels[@intCast(y * width + x)] = color;
            }
        }
    }

    fn paint_all(self: *Surface, frame: *const Frame) void {
        self.clip = .{ .x = 0, .y = 0, .width = width, .height = height };
        self.clear(frame.background);
        for (frame.slice()) |draw| {
            if (draw.kind == .fill) self.fill(draw.rect, draw.color);
        }
    }

    fn apply(self: *Surface, bytes: []const u8) !void {
        try testing.expectEqual(magic, std.mem.readInt(u32, bytes[0..4], .little));
        const count = std.mem.readInt(u32, bytes[12..16], .little);
        const background = std.mem.readInt(u32, bytes[16..20], .little);
        var at: usize = header_size;
        var done: u32 = 0;
        while (done < count and at + op_size <= bytes.len) : (done += 1) {
            const kind = bytes[at];
            const box = Rect{
                .x = std.mem.readInt(i16, bytes[at + 4 ..][0..2], .little),
                .y = std.mem.readInt(i16, bytes[at + 6 ..][0..2], .little),
                .width = std.mem.readInt(i16, bytes[at + 8 ..][0..2], .little),
                .height = std.mem.readInt(i16, bytes[at + 10 ..][0..2], .little),
            };
            const color = std.mem.readInt(u32, bytes[at + 12 ..][0..4], .little);
            at += op_size;
            if (kind == @backingInt(Op.clear)) {
                self.clip = .{ .x = 0, .y = 0, .width = width, .height = height };
                self.fill(box, background);
                self.clip = box;
                continue;
            }
            if (kind == @backingInt(Op.text)) {
                const length = std.mem.readInt(u16, bytes[at..][0..2], .little) & 0x7fff;
                at += 2 + length;
                continue;
            }
            self.fill(box, if (kind == @backingInt(Op.clear)) background else color);
        }
        try testing.expectEqual(count, done);
    }
};

fn scatter(storage: []Draw, seed: u64, boxes: usize) Frame {
    var frame = Frame.init(storage);
    var random = std.Random.DefaultPrng.init(seed);
    const source = random.random();
    var made: usize = 0;
    while (made < boxes) : (made += 1) {
        const box = Rect{
            .x = source.intRangeAtMost(i32, -4, Surface.width),
            .y = source.intRangeAtMost(i32, -4, Surface.height),
            .width = source.intRangeAtMost(i32, 1, 20),
            .height = source.intRangeAtMost(i32, 1, 12),
        };
        frame.items[frame.len] = .{
            .kind = .fill,
            .rect = box,
            .damage = box,
            .color = source.int(u24),
            .node = @intCast(made),
        };
        frame.len += 1;
    }
    frame.background = 0x101010;
    frame.width = Surface.width;
    frame.height = Surface.height;
    return frame;
}

test "a patched canvas is pixel for pixel a repainted one" {
    var previous_storage: [24]Draw = undefined;
    var next_storage: [24]Draw = undefined;
    var patched = Surface{};
    var repainted = Surface{};
    var bytes: [16 * 1024]u8 = undefined;

    var seed: u64 = 0;
    while (seed < 64) : (seed += 1) {
        var previous = scatter(&previous_storage, seed, 24);
        var next = scatter(&next_storage, seed, 24);
        var random = std.Random.DefaultPrng.init(seed +% 9001);
        const source = random.random();
        var moved: usize = 0;
        while (moved < 8) : (moved += 1) {
            const at = source.intRangeLessThan(usize, 0, next.len);
            next.items[at].rect.x += source.intRangeAtMost(i32, -6, 6);
            next.items[at].rect.y += source.intRangeAtMost(i32, -6, 6);
            next.items[at].damage = next.items[at].rect;
            next.items[at].color = source.int(u24);
        }

        patched.paint_all(&previous);
        var out = Patch.init(&bytes);
        write(&out, &previous, &next);
        try patched.apply(out.slice());

        repainted.paint_all(&next);
        try testing.expectEqualSlices(u32, &repainted.pixels, &patched.pixels);
    }
}

test "a run of frames patched one after another never drifts" {
    var storage: [2][32]Draw = undefined;
    var surface = Surface{};
    var reference = Surface{};
    var bytes: [16 * 1024]u8 = undefined;

    var frames: [2]Frame = undefined;
    var parity: usize = 0;
    var frame: u32 = 0;
    while (frame < 120) : (frame += 1) {
        var next = Frame.init(&storage[parity]);
        var at: i32 = 0;
        while (at < 32) : (at += 1) {
            const step = @as(i32, @intCast(frame)) + at * 3;
            const box = Rect{
                .x = at * 3,
                .y = 20 + @divTrunc(@mod(step * 7, 31) - 15, 2),
                .width = 3,
                .height = 3,
            };
            next.items[next.len] = .{
                .kind = .fill,
                .rect = box,
                .damage = box,
                .color = @intCast(@mod(@as(i64, step) * 2654435761, 0xffffff)),
                .node = @intCast(at),
            };
            next.len += 1;
        }
        next.background = 0x101010;
        next.width = Surface.width;
        next.height = Surface.height;
        frames[parity] = next;

        var out = Patch.init(&bytes);
        write(&out, &frames[1 - parity], &frames[parity]);
        try surface.apply(out.slice());
        reference.paint_all(&frames[parity]);
        try testing.expectEqualSlices(u32, &reference.pixels, &surface.pixels);
        parity = 1 - parity;
    }
}

test "a frame that ran short of storage is not diffed against" {
    var previous_storage: [2]Draw = undefined;
    var next_storage: [2]Draw = undefined;
    var previous = frame_of(&previous_storage, &.{ cell(1, 0, 0xff0000), cell(2, 9, 0x00ff00) });
    var next = frame_of(&next_storage, &.{ cell(1, 0, 0xff0000), cell(2, 9, 0x00ff00) });
    previous.truncated = true;
    next.truncated = true;

    var damage: [damage_max]Rect = undefined;
    try testing.expect(regions(&damage, &previous, &next) == null);
}

test "damage a caller brings itself joins what the diff found" {
    var previous_storage: [4]Draw = undefined;
    var next_storage: [4]Draw = undefined;
    var previous = frame_of(&previous_storage, &.{cell(1, 0, 0xff0000)});
    var next = frame_of(&next_storage, &.{cell(1, 0, 0x00ff00)});

    var damage: [damage_max]Rect = undefined;
    const found = regions(&damage, &previous, &next).?;
    try testing.expectEqual(@as(usize, 1), found.len);

    var count = found.len;
    try testing.expect(merge_region(&damage, &count, square(60, 30)));
    try testing.expectEqual(@as(usize, 2), count);

    try testing.expect(merge_region(&damage, &count, square(2, 10)));
    try testing.expectEqual(@as(usize, 2), count);
}

fn square(x: i32, y: i32) Rect {
    return .{ .x = x, .y = y, .width = 9, .height = 9 };
}

test "a damage list with no room left says so" {
    var damage: [2]Rect = undefined;
    var count: usize = 0;
    try testing.expect(merge_region(&damage, &count, square(0, 0)));
    try testing.expect(merge_region(&damage, &count, square(40, 0)));
    try testing.expect(!merge_region(&damage, &count, square(80, 0)));
    try testing.expectEqual(@as(usize, 2), count);
}
