const std = @import("std");
const layout = @import("../layout/resolve.zig");
const measure_mod = @import("../layout/measure.zig");
const paint = @import("cells.zig");
const style_mod = @import("../layout/style.zig");
const tree_mod = @import("../layout/tree.zig");
const units_mod = @import("../layout/units.zig");
const html = @import("html.zig");

const Tree = tree_mod.Tree;

const RendererKind = enum { html, terminal };

pub const Renderer = union(RendererKind) {
    html: Html,
    terminal: Terminal,

    pub const Kind = RendererKind;

    pub const Html = struct {
        writer: *std.Io.Writer,
        table: *const html.StyleTable,
        options: html.Options = .{},
    };

    pub const Terminal = struct {
        screen: *paint.Screen,
        styles: []style_mod.Style,
        options: paint.Options = .{},
        damage: ?*paint.Damage = null,
    };

    pub fn units(self: Renderer) units_mod.Units {
        return switch (self) {
            .html => |target| target.options.units,
            .terminal => units_mod.Units.cell,
        };
    }

    pub fn measure(kind: Kind) layout.Measure {
        return switch (kind) {
            .html, .terminal => measure_mod.monospace,
        };
    }

    pub fn resolve(kind: Kind, tree: *Tree, width: i32) void {
        std.debug.assert(width > 0);
        layout.resolve(tree, .{
            .width = width,
            .height = layout.unbounded,
        }, .{ .measure = measure(kind) });
    }

    pub fn draw(self: Renderer, tree: *const Tree) !void {
        switch (self) {
            .html => |target| try html.write(
                target.writer,
                tree,
                target.table,
                target.options,
            ),
            .terminal => |target| {
                std.debug.assert(target.styles.len >= tree.len);
                std.debug.assert(target.screen.cells.len > 0);
                if (target.damage) |damage| {
                    paint.repaint(
                        target.screen,
                        damage,
                        tree,
                        target.styles,
                        target.options,
                    );
                } else {
                    target.screen.clear(target.options.base);
                    paint.paint(target.screen, tree, target.styles, target.options);
                }
            },
        }
    }
};

const testing = std.testing;
const el = @import("../layout/dsl.zig");

fn build(tree: *Tree) !void {
    _ = try el.mount_under(tree, tree_mod.none, el.column(.{
        .width = .{ .fixed = 32 },
    }, .{
        el.heading(1, "Boxes", .{ .style = .{ .bold = true } }),
        el.rich(.{ .width = .{ .fixed = 32 } }, .{
            el.run("one layout, ", .{}),
            el.link("two renderers", "/both", .{ .style = .{ .underline = true } }),
        }),
    }));
}

test "one tree, two renderers, the same words" {
    var storage: [16]tree_mod.Node = undefined;
    var tree = Tree.init(&storage);
    try build(&tree);

    var bytes: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    const table = html.StyleTable.collect(&tree);
    const web = Renderer{ .html = .{ .writer = &writer, .table = &table } };
    Renderer.resolve(.html, &tree, 32);
    try web.draw(&tree);
    const page = writer.buffered();

    var cells: [32 * 8]paint.Cell = undefined;
    var styles: [16]style_mod.Style = undefined;
    var screen = paint.Screen.init(&cells, 32, 8);
    const terminal = Renderer{
        .terminal = .{ .screen = &screen, .styles = &styles },
    };
    Renderer.resolve(.terminal, &tree, 32);
    try terminal.draw(&tree);

    for ([_][]const u8{ "Boxes", "two renderers" }) |expected| {
        try testing.expect(std.mem.indexOf(u8, page, expected) != null);
        try testing.expect(on_screen(&screen, expected));
    }
    try testing.expectEqual(@as(i32, 0), tree.at(1).rect.y);
}

test "a logical pixel is a cell in a terminal and a page's measure on a page" {
    var cells: [1]paint.Cell = undefined;
    var screen = paint.Screen.init(&cells, 1, 1);
    var styles: [1]style_mod.Style = undefined;
    var bytes: [1]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    const table = html.StyleTable{};

    const terminal = Renderer{ .terminal = .{ .screen = &screen, .styles = &styles } };
    try testing.expect(terminal.units().eql(units_mod.Units.cell));

    const web = Renderer{ .html = .{
        .writer = &writer,
        .table = &table,
        .options = .{ .units = .{ .width = 9, .height = 30 } },
    } };
    try testing.expectEqual(@as(i32, 630), web.units().x(70));
    try testing.expectEqual(@as(i32, 70), terminal.units().x(70));
}

test "a renderer measures the same way whichever it is" {
    try testing.expectEqual(Renderer.measure(.html), Renderer.measure(.terminal));
}

fn on_screen(screen: *const paint.Screen, expected: []const u8) bool {
    var line: [256]u8 = undefined;
    var row: i32 = 0;
    while (row < screen.height) : (row += 1) {
        var at: usize = 0;
        var column: i32 = 0;
        while (column < screen.width and at < line.len) : (column += 1) {
            const cell = screen.at(column, row) orelse continue;
            const text = cell.text();
            if (at + text.len > line.len) break;
            @memcpy(line[at..][0..text.len], text);
            at += text.len;
        }
        if (std.mem.indexOf(u8, line[0..at], expected) != null) return true;
    }
    return false;
}
