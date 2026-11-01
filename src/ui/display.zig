const std = @import("std");
const markix = @import("markix");
const theme = @import("../theme.zig");
const ui_document = @import("document.zig");

const cells = markix.backend.cells;
const graphics = markix.terminal.graphics;
const Tree = markix.Tree;
const Node = markix.Node;
const Style = markix.Style;

pub const columns_max: i32 = 512;
pub const rows_max: i32 = 256;
pub const base_nodes_max: usize = 2_048;
pub const overlay_nodes_max: usize = 512;
pub const page_nodes_max: usize = ui_document.nodes_max;
const draws_max: usize = base_nodes_max + overlay_nodes_max + page_nodes_max;

pub const Frame = struct {
    base_nodes: [base_nodes_max]Node = undefined,
    base_styles: [base_nodes_max]Style = undefined,
    page_nodes: [page_nodes_max]Node = undefined,
    page_styles: [page_nodes_max]Style = undefined,
    overlay_nodes: [overlay_nodes_max]Node = undefined,
    overlay_styles: [overlay_nodes_max]Style = undefined,
    base: Tree = .{ .nodes = &.{} },
    page: Tree = .{ .nodes = &.{} },
    overlay: Tree = .{ .nodes = &.{} },
    page_options: ?cells.Options = null,
    overlay_options: ?cells.Options = null,

    pub fn begin(self: *Frame) void {
        self.base = Tree.init(&self.base_nodes);
        self.page = Tree.init(&self.page_nodes);
        self.overlay = Tree.init(&self.overlay_nodes);
        self.page_options = null;
        self.overlay_options = null;
    }

    pub fn layers(self: *Frame, out: *[3]cells.Layer) []const cells.Layer {
        std.debug.assert(self.base.len > 0);
        std.debug.assert(self.base.nodes.len == base_nodes_max);
        out[0] = .{ .tree = &self.base, .styles = &self.base_styles, .options = .{
            .base = theme.base(),
        } };
        var count: usize = 1;
        if (self.page_options) |options| {
            out[count] = .{ .tree = &self.page, .styles = &self.page_styles, .options = options };
            count += 1;
        }
        if (self.overlay_options) |options| {
            out[count] = .{
                .tree = &self.overlay,
                .styles = &self.overlay_styles,
                .options = options,
            };
            count += 1;
        }
        return out[0..count];
    }
};

pub const Display = struct {
    screen: cells.Screen,
    damage: cells.Damage,
    pictures: ?graphics.Graphics = null,
    frame: Frame = .{},

    pub fn create(
        gpa: std.mem.Allocator,
        columns: i32,
        rows: i32,
        protocol: graphics.Protocol,
    ) !*Display {
        std.debug.assert(columns > 0 and columns <= columns_max);
        std.debug.assert(rows > 0 and rows <= rows_max);
        const display = try gpa.create(Display);
        errdefer gpa.destroy(display);
        display.* = .{ .screen = undefined, .damage = undefined };
        display.screen = try cells.Screen.alloc(gpa, columns_max, rows_max, false);
        errdefer display.screen.free(gpa);
        display.screen.resize(columns, rows);
        display.damage = try cells.Damage.alloc(gpa, draws_max);
        errdefer display.damage.free(gpa);
        if (protocol != .none) {
            display.pictures = try graphics.Graphics.alloc(gpa, protocol);
            display.screen.graphics = &display.pictures.?;
        }
        display.frame.begin();
        return display;
    }

    pub fn destroy(self: *Display, gpa: std.mem.Allocator) void {
        if (self.pictures) |*pictures| pictures.free(gpa);
        self.damage.free(gpa);
        self.screen.free(gpa);
        gpa.destroy(self);
    }

    pub fn width(self: *const Display) i32 {
        return self.screen.width;
    }

    pub fn height(self: *const Display) i32 {
        return self.screen.height;
    }

    pub fn resize(self: *Display, columns: i32, rows: i32) void {
        const wide: i32 = @max(columns, 1);
        const capacity: i32 = @intCast(self.screen.cells.len / @as(usize, @intCast(wide)));
        self.screen.resize(wide, @max(@min(rows, capacity), 1));
    }

    pub fn present(self: *Display) void {
        var buffer: [3]cells.Layer = undefined;
        cells.repaint_layers(&self.screen, &self.damage, self.frame.layers(&buffer));
    }

    pub fn painted_area(self: *const Display) i32 {
        const full = self.screen.width * self.screen.height;
        const regions = self.screen.dirty orelse return full;
        var total: i32 = 0;
        for (regions) |region| total += region.width * region.height;
        return total;
    }

    pub fn backend(self: *Display) markix.LoopBackend {
        return cells.screen_backend(&self.screen);
    }

    pub fn text_at(self: *const Display, x: i32, y: i32) []const u8 {
        const cell = self.screen.at(x, y) orelse return "";
        return cell.text();
    }

    pub fn row_text(self: *const Display, y: i32, out: []u8) []const u8 {
        std.debug.assert(out.len >= @as(usize, @intCast(self.screen.width)) * 4);
        var length: usize = 0;
        var x: i32 = 0;
        while (x < self.screen.width) : (x += 1) {
            const bytes = self.text_at(x, y);
            @memcpy(out[length..][0..bytes.len], bytes);
            length += bytes.len;
        }
        std.debug.assert(length <= out.len);
        return out[0..length];
    }

    pub fn shows(self: *const Display, needle: []const u8) bool {
        return self.shows_in(needle, markix.Rect.init(0, 0, self.width(), self.height()));
    }

    pub fn shows_in(self: *const Display, needle: []const u8, area: markix.Rect) bool {
        std.debug.assert(area.width >= 0 and area.height >= 0);
        var buffer: [columns_max * 4]u8 = undefined;
        var y: i32 = @max(area.y, 0);
        while (y < @min(area.bottom(), self.height())) : (y += 1) {
            var length: usize = 0;
            var x: i32 = @max(area.x, 0);
            while (x < @min(area.right(), self.width())) : (x += 1) {
                const bytes = self.text_at(x, y);
                @memcpy(buffer[length..][0..bytes.len], bytes);
                length += bytes.len;
            }
            std.debug.assert(length <= buffer.len);
            if (std.mem.indexOf(u8, buffer[0..length], needle) != null) return true;
        }
        return false;
    }
};

test "a display paints its base tree onto its screen" {
    const node = @import("node.zig");
    const display = try Display.create(std.testing.allocator, 20, 3, .none);
    defer display.destroy(std.testing.allocator);
    display.frame.begin();
    const root = try node.box(&display.frame.base, node.none, .{});
    _ = try node.label(&display.frame.base, root, "readmarks", .{});
    node.resolve(&display.frame.base, display.width(), display.height());
    display.present();
    try std.testing.expect(display.shows("readmarks"));
    try std.testing.expect(!display.shows("bookmarks"));
}
