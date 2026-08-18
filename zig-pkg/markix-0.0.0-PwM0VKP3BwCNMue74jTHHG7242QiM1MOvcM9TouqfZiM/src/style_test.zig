const std = @import("std");

pub const SourceFile = struct {
    name: []const u8,
    source: [:0]const u8,
    reusable: bool = false,
};

pub const source_files = [_]SourceFile{
    source("src/backend/terminal.zig", "backend/terminal.zig", true),
    source("src/backend/web.zig", "backend/web.zig", true),
    source("src/backend/web/commands.zig", "backend/web/commands.zig", true),
    source("src/backend/web/input.zig", "backend/web/input.zig", true),
    source("src/backend/web/serialize.zig", "backend/web/serialize.zig", true),
    source("src/layout.zig", "layout.zig", true),
    source("src/render/paint.zig", "render/paint.zig", true),
    source("src/backend/terminal/canvas.zig", "backend/terminal/canvas.zig", true),
    source("src/backend/terminal/event.zig", "backend/terminal/event.zig", true),
    source("src/backend/terminal/image.zig", "backend/terminal/image.zig", true),
    source("src/backend/terminal/input.zig", "backend/terminal/input.zig", true),
    source("src/backend/terminal/limits.zig", "backend/terminal/limits.zig", true),
    source("src/backend/terminal/selection.zig", "backend/terminal/selection.zig", true),
    source("src/backend/terminal/sixel.zig", "backend/terminal/sixel.zig", true),
    source("src/backend/terminal/terminal.zig", "backend/terminal/terminal.zig", true),
    source("src/backend/terminal/text_entry.zig", "backend/terminal/text_entry.zig", true),
    source("src/backend/terminal/text_width.zig", "backend/terminal/text_width.zig", true),
    source("src/widgets/badge.zig", "widgets/badge.zig", true),
    source("src/widgets/fuzzy_text.zig", "widgets/fuzzy_text.zig", true),
    source("src/widgets/image.zig", "widgets/image.zig", true),
    source("src/widgets/inline.zig", "widgets/inline.zig", true),
    source("src/widgets/label.zig", "widgets/label.zig", true),
    source("src/widgets/list.zig", "widgets/list.zig", true),
    source("src/widgets/panel.zig", "widgets/panel.zig", true),
    source("src/widgets/code_block.zig", "widgets/code_block.zig", true),
    source("src/widgets/rule.zig", "widgets/rule.zig", true),
    source("src/widgets/heading.zig", "widgets/heading.zig", true),
    source("src/widgets/scrollbar.zig", "widgets/scrollbar.zig", true),
    source("src/widgets/segmented.zig", "widgets/segmented.zig", true),
    source("src/widgets/status_line.zig", "widgets/status_line.zig", true),
    source("src/widgets/surface.zig", "widgets/surface.zig", true),
    source("src/widgets/text_input.zig", "widgets/text_input.zig", true),
    source("src/style/color.zig", "style/color.zig", true),
    source("src/style/style.zig", "style/style.zig", true),
    source("src/style/text_style.zig", "style/text_style.zig", true),
    source("src/utils/fuzzy.zig", "utils/fuzzy.zig", true),
    source("src/utils/input.zig", "utils/input.zig", true),
    source("src/utils/limits.zig", "utils/limits.zig", true),
    source("src/layout/flex.zig", "layout/flex.zig", true),
    source("src/layout/grid.zig", "layout/grid.zig", true),
    source("src/layout/rect.zig", "layout/rect.zig", true),
    source("src/layout/tree.zig", "layout/tree.zig", true),
    source("src/layout/text_measure.zig", "layout/text_measure.zig", true),
    source("src/layout/inline_layout.zig", "layout/inline_layout.zig", true),
    source("src/layout/breakpoints.zig", "layout/breakpoints.zig", true),
    source("src/parser/document.zig", "parser/document.zig", true),
    source("src/parser/readable.zig", "parser/readable.zig", true),
    source("src/parser/xml.zig", "parser/xml.zig", true),
    source("src/dom/types.zig", "dom/types.zig", true),
    source("src/dom/node.zig", "dom/node.zig", true),
    source("src/dom/tree.zig", "dom/tree.zig", true),
    source("src/dom/event.zig", "dom/event.zig", true),
    source("src/render/terminal.zig", "render/terminal.zig", true),
    source("src/render/web.zig", "render/web.zig", true),
    source("src/render/html.zig", "render/html.zig", true),
    source("src/root.zig", "root.zig", true),
    source("src/dom.zig", "dom.zig", true),
    source("src/render.zig", "render.zig", true),
    source("src/widgets.zig", "widgets.zig", true),
    source("src/theme.zig", "theme.zig", true),
    source("src/style_test.zig", "style_test.zig", false),
    source("src/tests.zig", "tests.zig", false),
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

/// One function, located.
const Function = struct {
    file: []const u8,
    line: u32,
    name: []const u8,
    source: []const u8,

    fn line_count(self: Function) u32 {
        return @intCast(std.mem.count(u8, self.source, "\n") + 1);
    }

    fn assertions(self: Function) u32 {
        return @intCast(std.mem.count(u8, self.source, "assert("));
    }

    /// A function returning a type rather than a value.
    ///
    /// Zig writes generics as functions, and the struct one returns is a
    /// declaration rather than a body -- it is not read as a function is read
    /// and the rules for one do not describe it. Named by the convention Zig
    /// itself uses for them.
    fn builds_a_type(self: Function) bool {
        if (self.name.len == 0) return false;
        return std.ascii.isUpper(self.name[0]);
    }

    fn is_test_scaffolding(self: Function) bool {
        return std.mem.indexOf(u8, self.source, "std.testing") != null;
    }

    /// A function that is one exhaustive switch and nothing else.
    ///
    /// There is nothing for an assertion to catch in a total mapping from an
    /// enum: Zig already refuses to compile it if a case is missing, which is
    /// the whole of what could be asserted. Assertions are for what the type
    /// system cannot state, and here it states everything.
    fn is_total_mapping(self: Function) bool {
        if (std.mem.indexOf(u8, self.source, "return switch (") == null) return false;
        return std.mem.count(u8, self.source, "return ") == 1;
    }
};

/// Calls `visit` with every function in every source file.
///
/// The span comes from the function's first and last tokens, not from
/// `nodeToSpan`: for a `fn_decl` that returns the `pub fn` keywords alone. A
/// rule measured against those two words is a rule that passes on everything,
/// which is what the length rule here did until it was measured.
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

/// Functions of substance carrying fewer than two assertions.
///
/// TigerStyle asks for two per function. Applied to every accessor and every
/// three-line switch that would be noise, so this asks it of the functions
/// where an assertion can actually be wrong about something: fifteen lines or
/// more, and not test scaffolding.
///
/// The number is a debt, not a target. It only ever goes down -- a change that
/// raises it has added a function that states none of what it assumes.
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
