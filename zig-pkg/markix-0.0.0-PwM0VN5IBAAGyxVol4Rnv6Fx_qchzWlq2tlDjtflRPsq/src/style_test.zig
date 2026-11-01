const std = @import("std");

pub const SourceFile = struct {
    name: []const u8,
    source: [:0]const u8,
    reusable: bool = false,
};

pub const source_files = [_]SourceFile{
    source("src/backend.zig", "backend.zig", true),
    source("src/backend/canvas.zig", "backend/canvas.zig", true),
    source("src/backend/cells.zig", "backend/cells.zig", true),
    source("src/backend/html.zig", "backend/html.zig", true),
    source("src/backend/loop.zig", "backend/loop.zig", true),
    source("src/backend/patch.zig", "backend/patch.zig", true),
    source("src/backend/renderer.zig", "backend/renderer.zig", true),
    source("src/backend/terminal.zig", "backend/terminal.zig", true),
    source("src/backend/terminal/event.zig", "backend/terminal/event.zig", true),
    source("src/backend/terminal/graphics.zig", "backend/terminal/graphics.zig", true),
    source("src/backend/terminal/input.zig", "backend/terminal/input.zig", true),
    source("src/backend/terminal/limits.zig", "backend/terminal/limits.zig", true),
    source("src/backend/terminal/sixel.zig", "backend/terminal/sixel.zig", true),
    source("src/backend/terminal/terminal.zig", "backend/terminal/terminal.zig", true),
    source("src/layout.zig", "layout.zig", true),
    source("src/layout/box.zig", "layout/box.zig", true),
    source("src/layout/dsl.zig", "layout/dsl.zig", true),
    source("src/layout/element.zig", "layout/element.zig", true),
    source("src/layout/measure.zig", "layout/measure.zig", true),
    source("src/layout/rect.zig", "layout/rect.zig", true),
    source("src/layout/resolve.zig", "layout/resolve.zig", true),
    source("src/layout/style.zig", "layout/style.zig", true),
    source("src/layout/tree.zig", "layout/tree.zig", true),
    source("src/layout/units.zig", "layout/units.zig", true),
    source("src/pipeline_tests.zig", "pipeline_tests.zig", false),
    source("src/reader.zig", "reader.zig", true),
    source("src/root.zig", "root.zig", true),
    source("src/style_test.zig", "style_test.zig", false),
    source("src/tests.zig", "tests.zig", false),
    source("src/utils/input.zig", "utils/input.zig", true),
    source("src/widgets.zig", "widgets.zig", true),
    source("src/widgets/text_input.zig", "widgets/text_input.zig", true),
};

fn source(
    comptime name: []const u8,
    comptime path: []const u8,
    comptime reusable: bool,
) SourceFile {
    return .{ .name = name, .source = @embedFile(path), .reusable = reusable };
}

test "source lines do not exceed 100 columns" {
    for (source_files) |file| {
        var lines = std.mem.splitScalar(u8, file.source, '\n');
        var line_number: u32 = 1;
        while (lines.next()) |line| : (line_number += 1) {
            if (line.len > 100) {
                std.debug.print(
                    "{s}:{d}: line has {d} columns\n",
                    .{ file.name, line_number, line.len },
                );
                return error.LineTooLong;
            }
        }
    }
}

const Function = struct {
    file: []const u8,
    line: u32,
    name: []const u8,
    source: []const u8,
    below_tests: bool = false,

    fn line_count(self: Function) u32 {
        return @intCast(std.mem.count(u8, self.source, "\n") + 1);
    }

    fn assertions(self: Function) u32 {
        return @intCast(std.mem.count(u8, self.source, "assert("));
    }

    fn builds_a_type(self: Function) bool {
        if (self.name.len == 0) return false;
        return std.ascii.isUpper(self.name[0]);
    }

    fn is_test_scaffolding(self: Function) bool {
        if (std.mem.indexOf(u8, self.source, "std.testing") != null) return true;
        if (std.mem.indexOf(u8, self.source, "testing.") != null) return true;
        return self.below_tests;
    }

    fn is_total_mapping(self: Function) bool {
        if (std.mem.indexOf(u8, self.source, "return switch (") == null) return false;
        return std.mem.count(u8, self.source, "return ") == 1;
    }
};

fn tests_begin(text: []const u8) usize {
    const marker = std.mem.indexOf(u8, text, "\nconst testing = std.testing;") orelse text.len;
    const first = std.mem.indexOf(u8, text, "\ntest ") orelse text.len;
    return @min(marker, first);
}

fn walk_functions(context: anytype, comptime visit: fn (@TypeOf(context), Function) void) !void {
    for (source_files) |file| {
        var ast = try std.zig.Ast.parse(
            std.testing.allocator,
            file.source,
            .{ .mode = .zig },
        );
        defer ast.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);

        const tags = ast.nodes.items(.tag);
        for (tags, 0..) |tag, node_raw| {
            if (tag != .fn_decl) continue;
            const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(node_raw));
            const first = ast.firstToken(node);
            const last = ast.lastToken(node);
            const start = ast.tokenStart(first);
            const end = ast.tokenStart(last) + ast.tokenSlice(last).len;
            std.debug.assert(end > start);
            std.debug.assert(end <= file.source.len);
            visit(context, .{
                .file = file.name,
                .line = @intCast(std.mem.count(u8, file.source[0..start], "\n") + 1),
                .name = ast.tokenSlice(ast.nodes.items(.main_token)[node_raw] + 1),
                .source = file.source[start..end],
                .below_tests = start > tests_begin(file.source),
            });
        }
    }
}

const Tally = struct {
    over_length: u32 = 0,
    under_asserted: u32 = 0,
};

test "functions do not exceed 70 lines" {
    var tally = Tally{};
    try walk_functions(&tally, struct {
        fn visit(counts: *Tally, function: Function) void {
            const lines = function.line_count();
            if (lines <= 70) return;
            if (function.builds_a_type()) return;
            counts.over_length += 1;
            std.debug.print("{s}:{d}: {s} has {d} lines\n", .{
                function.file,
                function.line,
                function.name,
                lines,
            });
        }
    }.visit);
    try std.testing.expectEqual(@as(u32, 0), tally.over_length);
}

const under_asserted_max: u32 = 0;

test "functions of substance assert what they assume" {
    var tally = Tally{};
    try walk_functions(&tally, struct {
        fn visit(counts: *Tally, function: Function) void {
            if (function.line_count() < 15) return;
            if (function.builds_a_type()) return;
            if (function.is_test_scaffolding()) return;
            if (function.is_total_mapping()) return;
            if (function.assertions() >= 2) return;
            counts.under_asserted += 1;
            std.debug.print("{s}:{d}: {s} asserts {d} times\n", .{
                function.file,
                function.line,
                function.name,
                function.assertions(),
            });
        }
    }.visit);
    try std.testing.expect(tally.under_asserted <= under_asserted_max);
}
