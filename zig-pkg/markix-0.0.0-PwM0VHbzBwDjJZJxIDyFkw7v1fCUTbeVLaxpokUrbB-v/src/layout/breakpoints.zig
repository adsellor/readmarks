const std = @import("std");

// Breakpoints, as layout inputs rather than stylesheet rules.
//
// A resolved layout cannot reflow: the positions are already decided. Fitting
// a narrower viewport therefore means laying the tree out again at fewer
// columns, not restyling the one layout. A breakpoint pairs a viewport limit
// with the column count to use below it, so the engine owns both halves and
// the stylesheet only reports which one is showing.

pub const breakpoints_max: u8 = 4;

pub const Breakpoint = struct {
    /// Class the rendered surface carries, and the name used in tests.
    name: []const u8,
    /// Columns this layout occupies.
    columns: u16,
    /// Viewport width, in pixels, at or below which this layout is shown.
    /// The widest breakpoint uses `limit_none` and applies above all others.
    limit_px: u16 = limit_none,

    pub const limit_none: u16 = std.math.maxInt(u16);

    pub fn is_widest(self: Breakpoint) bool {
        return self.limit_px == limit_none;
    }
};

pub const Set = struct {
    items: [breakpoints_max]Breakpoint = undefined,
    count: u8 = 0,

    pub fn slice(self: *const Set) []const Breakpoint {
        std.debug.assert(self.count <= breakpoints_max);
        return self.items[0..self.count];
    }

    /// Builds a set, widest first. Limits must decrease, and exactly one
    /// breakpoint may be the widest, or two layouts could claim a viewport.
    pub fn init(items: []const Breakpoint) !Set {
        if (items.len == 0) return error.NoBreakpoints;
        if (items.len > breakpoints_max) return error.TooManyBreakpoints;
        var set = Set{ .count = @intCast(items.len) };
        var previous: u16 = Breakpoint.limit_none;
        for (items, 0..) |item, index| {
            if (item.columns == 0) return error.ZeroColumns;
            // Checked before the ordering rule so a second unbounded layout is
            // reported as what it is rather than as a limit out of order.
            if (index > 0 and item.is_widest()) return error.MultipleWidest;
            if (index > 0 and item.limit_px >= previous) return error.LimitsNotDescending;
            set.items[index] = item;
            previous = item.limit_px;
        }
        std.debug.assert(set.count == items.len);
        std.debug.assert(set.items[0].is_widest());
        return set;
    }

    /// The layout a viewport of `width_px` resolves to, matching what the
    /// generated media queries do.
    pub fn select(self: *const Set, width_px: u16) Breakpoint {
        std.debug.assert(self.count > 0);
        var chosen = self.items[0];
        for (self.slice()) |item| {
            if (item.is_widest()) continue;
            if (width_px <= item.limit_px) chosen = item;
        }
        return chosen;
    }

    /// Writes the rules that show exactly one layout at a time.
    pub fn write_css(self: *const Set, writer: *std.Io.Writer) !void {
        std.debug.assert(self.count <= breakpoints_max);
        std.debug.assert(self.count > 0);
        for (self.slice()) |item| {
            if (item.is_widest()) continue;
            try writer.print(".mx-{s} {{ display: none; }}\n", .{item.name});
        }
        for (self.slice()) |item| {
            if (item.is_widest()) continue;
            try writer.print("@media (max-width: {d}px) {{\n", .{item.limit_px});
            for (self.slice()) |other| {
                if (std.mem.eql(u8, other.name, item.name)) continue;
                try writer.print("  .mx-{s} {{ display: none; }}\n", .{other.name});
            }
            try writer.print("  .mx-{s} {{ display: block; }}\n", .{item.name});
            try writer.writeAll("}\n");
        }
    }
};

test "a set is widest first with descending limits" {
    const set = try Set.init(&.{
        .{ .name = "wide", .columns = 96 },
        .{ .name = "medium", .columns = 72, .limit_px = 1100 },
        .{ .name = "narrow", .columns = 46, .limit_px = 700 },
    });
    try std.testing.expectEqual(@as(u8, 3), set.count);
    try std.testing.expect(set.items[0].is_widest());
}

test "limits that do not descend are rejected" {
    try std.testing.expectError(error.LimitsNotDescending, Set.init(&.{
        .{ .name = "wide", .columns = 96 },
        .{ .name = "narrow", .columns = 46, .limit_px = 700 },
        .{ .name = "medium", .columns = 72, .limit_px = 1100 },
    }));
}

test "two widest layouts are rejected" {
    try std.testing.expectError(error.MultipleWidest, Set.init(&.{
        .{ .name = "wide", .columns = 96 },
        .{ .name = "other", .columns = 72 },
    }));
}

test "an empty or oversized set is rejected" {
    try std.testing.expectError(error.NoBreakpoints, Set.init(&.{}));
    try std.testing.expectError(error.ZeroColumns, Set.init(&.{
        .{ .name = "wide", .columns = 0 },
    }));
}

test "selection matches what the media queries do" {
    const set = try Set.init(&.{
        .{ .name = "wide", .columns = 96 },
        .{ .name = "medium", .columns = 72, .limit_px = 1100 },
        .{ .name = "narrow", .columns = 46, .limit_px = 700 },
    });
    try std.testing.expectEqual(@as(u16, 96), set.select(1600).columns);
    try std.testing.expectEqual(@as(u16, 72), set.select(1100).columns);
    try std.testing.expectEqual(@as(u16, 72), set.select(900).columns);
    try std.testing.expectEqual(@as(u16, 46), set.select(700).columns);
    try std.testing.expectEqual(@as(u16, 46), set.select(375).columns);
}

test "the rules show exactly one layout at every width" {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const set = try Set.init(&.{
        .{ .name = "wide", .columns = 96 },
        .{ .name = "narrow", .columns = 46, .limit_px = 700 },
    });
    try set.write_css(&writer);
    const css = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, css, ".mx-narrow { display: none; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "@media (max-width: 700px)") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "  .mx-wide { display: none; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "  .mx-narrow { display: block; }") != null);
}
