const std = @import("std");
const dom = @import("dom.zig");
const render = @import("render.zig");
const layout = @import("layout.zig");

const Rect = layout.Rect;
const LayoutElement = layout.LayoutElement;
const DomTree = dom.DomTree;
const TerminalCanvas = @import("backend/terminal/canvas.zig").TerminalCanvas;

// What a frame costs.
//
// A TUI framework is judged on one number: the work between "something
// changed" and "the terminal has been told". That splits into three parts,
// and they are measured separately because they scale differently and a
// single blended figure hides which one is the problem.
//
//   layout      resolving every rect from the tree
//   repaint     turning dirty nodes into cells
//   frame       diffing those cells and writing the escape sequence
//
// The measurements that matter are the incremental ones. Every framework can
// redraw everything; the question is what moving a selection costs, because
// that is what a key press does and it is the latency a user feels.
//
// Run with `zig build bench`. Release only -- a debug build measures the
// assertions rather than the work, and the numbers are meaningless.

/// Rows in the list benchmarks. A file tree or a log view is this size.
const rows_bench: u16 = 500;

/// Blocks in the document benchmark. A long article is a few hundred.
const blocks_bench: u16 = 300;

/// Repeats per measurement. Enough that a single scheduling hiccup does not
/// decide the result.
const samples_min: u32 = 32;

/// Total time to spend on one measurement before reporting it.
const sample_ns_max: u64 = 200 * std.time.ns_per_ms;

const rule_line =
    "----------------------------------------------------------------------";

/// The monotonic clock, taken from the process at startup.
///
/// Held in a global rather than threaded through every measurement: this is a
/// benchmark, and a clock handle in each signature would be noise in the one
/// place the code is supposed to be easy to read.
var clock: std.Io = undefined;

fn now_ns() u64 {
    const timestamp = std.Io.Timestamp.now(clock, .awake);
    std.debug.assert(timestamp.nanoseconds >= 0);
    return @intCast(timestamp.nanoseconds);
}

pub fn main(init: std.process.Init) !void {
    clock = init.io;
    // Collected into a buffer and printed once at the end: writing between
    // measurements would put a syscall inside the window being timed.
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const out = &writer;

    try out.writeAll("markix -- what a frame costs\n\n");
    try out.print("{s:<44}{s:>12}{s:>14}\n", .{ "measurement", "per op", "ops/sec" });
    try out.writeAll(rule_line ++ "\n");

    try bench_layout_full(out);
    try bench_layout_document(out);
    try bench_selection_move(out);
    try bench_repaint_full(out);
    try bench_repaint_selection(out);
    try bench_frame_write(out);
    try bench_serialize_whole(out);
    try bench_serialize_dirty(out);
    try bench_html(out);

    try out.writeAll(
        \\
        \\The incremental rows are the ones that matter: a key press moves a
        \\selection, and what it costs is the latency a reader feels. A
        \\framework that only knows how to redraw everything pays the full-tree
        \\row for it instead.
        \\
    );
    std.debug.print("{s}", .{out.buffered()});
}

/// Runs `work` until the time budget is spent, reporting the fastest sample.
///
/// The fastest rather than the mean: every sample is the same work, so the
/// spread is interference from the rest of the machine, and the minimum is the
/// closest thing to the cost of the work itself.
fn measure(
    out: *std.Io.Writer,
    name: []const u8,
    context: anytype,
    comptime work: fn (@TypeOf(context)) anyerror!void,
) !void {
    std.debug.assert(name.len > 0);
    std.debug.assert(samples_min > 0);
    // Once before timing: the first run faults in pages and warms the caches,
    // and measuring that measures the allocator rather than the framework.
    try work(context);

    var fastest_ns: u64 = std.math.maxInt(u64);
    var samples: u32 = 0;
    var spent: u64 = 0;
    while (samples < samples_min or spent < sample_ns_max) {
        const started = now_ns();
        try work(context);
        const elapsed = now_ns() -| started;
        if (elapsed < fastest_ns) fastest_ns = elapsed;
        spent += elapsed;
        samples += 1;
        if (samples > 1_000_000) break;
    }
    std.debug.assert(samples >= samples_min);
    std.debug.assert(fastest_ns < std.math.maxInt(u64));
    try report(out, name, fastest_ns);
}

fn report(out: *std.Io.Writer, name: []const u8, per_op_ns: u64) !void {
    std.debug.assert(name.len > 0);
    const per_second = if (per_op_ns == 0)
        @as(u64, 0)
    else
        std.time.ns_per_s / per_op_ns;
    var scratch: [32]u8 = undefined;
    const timing = try write_duration(&scratch, per_op_ns);
    try out.print("{s:<44}{s:>12}{d:>14}\n", .{ name, timing, per_second });
}

fn write_duration(scratch: []u8, nanoseconds: u64) ![]const u8 {
    std.debug.assert(scratch.len >= 32);
    if (nanoseconds < 1_000) {
        return std.fmt.bufPrint(scratch, "{d} ns", .{nanoseconds});
    }
    if (nanoseconds < 1_000_000) {
        return std.fmt.bufPrint(scratch, "{d}.{d:0>2} us", .{
            nanoseconds / 1_000,
            (nanoseconds % 1_000) / 10,
        });
    }
    return std.fmt.bufPrint(scratch, "{d}.{d:0>2} ms", .{
        nanoseconds / 1_000_000,
        (nanoseconds % 1_000_000) / 10_000,
    });
}

// ------------------------------------------------------------------ layout

const ListFixture = struct {
    tree: *DomTree,
};

fn bench_layout_full(out: *std.Io.Writer) !void {
    var tree = DomTree.init();
    try build_list(&tree, rows_bench);
    var fixture = ListFixture{ .tree = &tree };
    try measure(out, "layout: 500-row list, whole tree", &fixture, struct {
        fn work(state: *ListFixture) anyerror!void {
            try state.tree.layout(Rect.init(0, 0, 120, rows_bench));
        }
    }.work);
}

fn bench_layout_document(out: *std.Io.Writer) !void {
    var tree = DomTree.init();
    try build_document(&tree, blocks_bench);
    var fixture = ListFixture{ .tree = &tree };
    try measure(out, "layout: 300-block document, whole tree", &fixture, struct {
        fn work(state: *ListFixture) anyerror!void {
            try state.tree.layout(Rect.init(0, 0, 96, 4096));
        }
    }.work);
}

fn bench_selection_move(out: *std.Io.Writer) !void {
    var tree = DomTree.init();
    try build_list(&tree, rows_bench);
    try tree.layout(Rect.init(0, 0, 120, rows_bench));
    var fixture = ListFixture{ .tree = &tree };
    try measure(out, "selection: move one row in 500", &fixture, struct {
        var at: u16 = 0;
        fn work(state: *ListFixture) anyerror!void {
            at = (at + 1) % rows_bench;
            _ = state.tree.select_row(0, at);
            state.tree.clear_dirty();
        }
    }.work);
}

// ----------------------------------------------------------------- repaint

const PaintFixture = struct {
    tree: *DomTree,
    canvas: *TerminalCanvas,
};

fn bench_repaint_full(out: *std.Io.Writer) !void {
    var canvas = try TerminalCanvas.init(std.heap.page_allocator, 120, 80);
    defer canvas.deinit();
    var tree = DomTree.init();
    try build_list(&tree, 40);
    try tree.layout(Rect.init(0, 0, 120, 40));
    var fixture = PaintFixture{ .tree = &tree, .canvas = &canvas };
    try measure(out, "repaint: 40-row list, every node", &fixture, struct {
        fn work(state: *PaintFixture) anyerror!void {
            state.tree.mark_all_dirty();
            var renderer = render.TerminalRenderer.init(
                state.canvas,
                layout.Color.from_rgb(0, 0, 0),
            );
            try renderer.paint(state.tree);
        }
    }.work);
}

fn bench_repaint_selection(out: *std.Io.Writer) !void {
    var canvas = try TerminalCanvas.init(std.heap.page_allocator, 120, 80);
    defer canvas.deinit();
    var tree = DomTree.init();
    try build_list(&tree, 40);
    try tree.layout(Rect.init(0, 0, 120, 40));
    var fixture = PaintFixture{ .tree = &tree, .canvas = &canvas };
    try measure(out, "repaint: 40-row list, selection moved", &fixture, struct {
        var at: u16 = 0;
        fn work(state: *PaintFixture) anyerror!void {
            at = (at + 1) % 40;
            _ = state.tree.select_row(0, at);
            var renderer = render.TerminalRenderer.init(
                state.canvas,
                layout.Color.from_rgb(0, 0, 0),
            );
            try renderer.paint(state.tree);
        }
    }.work);
}

const FrameFixture = struct {
    canvas: *TerminalCanvas,
    output: []u8,
};

fn bench_frame_write(out: *std.Io.Writer) !void {
    var canvas = try TerminalCanvas.init(std.heap.page_allocator, 120, 80);
    defer canvas.deinit();
    var tree = DomTree.init();
    try build_list(&tree, 40);
    try tree.layout(Rect.init(0, 0, 120, 40));
    var renderer = render.TerminalRenderer.init(
        &canvas,
        layout.Color.from_rgb(0, 0, 0),
    );
    try renderer.paint(&tree);

    const buffer = try std.heap.page_allocator.alloc(u8, 1 << 20);
    defer std.heap.page_allocator.free(buffer);
    var fixture = FrameFixture{ .canvas = &canvas, .output = buffer };
    try measure(out, "frame: serialize 120x80 canvas", &fixture, struct {
        fn work(state: *FrameFixture) anyerror!void {
            const serialize = @import("backend/web/serialize.zig");
            _ = try serialize.serialize_frame(state.canvas, state.output);
        }
    }.work);
}

// --------------------------------------------------------------- transport

const FrameBuffer = struct {
    tree: *DomTree,
    bytes: []u8,
};

fn bench_serialize_whole(out: *std.Io.Writer) !void {
    var tree = DomTree.init();
    try build_list(&tree, rows_bench);
    try tree.layout(Rect.init(0, 0, 120, rows_bench));
    const bytes = try std.heap.page_allocator.alloc(u8, 1 << 20);
    defer std.heap.page_allocator.free(bytes);
    var fixture = FrameBuffer{ .tree = &tree, .bytes = bytes };
    try measure(out, "frame: 500-row tree, every node", &fixture, struct {
        fn work(state: *FrameBuffer) anyerror!void {
            _ = try render.WebRenderer.serialize_tree(state.tree, state.bytes);
        }
    }.work);
}

fn bench_serialize_dirty(out: *std.Io.Writer) !void {
    var tree = DomTree.init();
    try build_list(&tree, rows_bench);
    try tree.layout(Rect.init(0, 0, 120, rows_bench));
    tree.clear_dirty();
    const bytes = try std.heap.page_allocator.alloc(u8, 1 << 20);
    defer std.heap.page_allocator.free(bytes);
    var fixture = FrameBuffer{ .tree = &tree, .bytes = bytes };
    try measure(out, "frame: 500-row tree, selection moved", &fixture, struct {
        var at: u16 = 0;
        fn work(state: *FrameBuffer) anyerror!void {
            at = (at + 1) % rows_bench;
            _ = state.tree.select_row(0, at);
            _ = try render.WebRenderer.serialize_dirty(state.tree, state.bytes);
            state.tree.clear_dirty();
        }
    }.work);
}

const HtmlFixture = struct {
    tree: *DomTree,
    bytes: []u8,
};

fn bench_html(out: *std.Io.Writer) !void {
    var tree = DomTree.init();
    try build_document(&tree, blocks_bench);
    try tree.layout(Rect.init(0, 0, 96, 4096));
    const bytes = try std.heap.page_allocator.alloc(u8, 4 << 20);
    defer std.heap.page_allocator.free(bytes);
    var fixture = HtmlFixture{ .tree = &tree, .bytes = bytes };
    try measure(out, "html: 300-block document", &fixture, struct {
        fn work(state: *HtmlFixture) anyerror!void {
            var writer = std.Io.Writer.fixed(state.bytes);
            var renderer = render.HtmlRenderer.Renderer.init(&writer, .{});
            try renderer.render(state.tree);
        }
    }.work);
}

// ---------------------------------------------------------------- fixtures

fn build_list(tree: *DomTree, rows: u16) !void {
    std.debug.assert(rows > 0);
    std.debug.assert(tree.node_count == 0);
    const list = try tree.set_root(.{
        .kind = .list,
        .props = .{ .list = .{ .item_count = rows, .visual = .{ .row_height = 1 } } },
        .layout = LayoutElement.content_stack(.column, 0),
        .semantic = .{ .tag = .list },
    });
    var index: u16 = 0;
    while (index < rows) : (index += 1) {
        _ = try tree.append_child(list, .{
            .kind = .list_item,
            .props = .{ .list_item = .{
                .title = "a row of a list, about as long as one usually is",
                .detail = "detail",
            } },
            .layout = LayoutElement.sized(1),
            .semantic = .{ .tag = .list_item },
        });
    }
    std.debug.assert(tree.node_count == rows + 1);
}

fn build_document(tree: *DomTree, blocks: u16) !void {
    std.debug.assert(blocks > 0);
    std.debug.assert(tree.node_count == 0);
    const root = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.content_stack(.column, 1),
        .semantic = .{ .tag = .article },
    });
    const prose =
        "Every position is resolved by the layout engine, so the renderer " ++
        "draws what was measured rather than measuring again and disagreeing.";
    var index: u16 = 0;
    while (index < blocks) : (index += 1) {
        if (index % 8 == 0) {
            _ = try tree.append_child(root, .{
                .kind = .heading,
                .props = .{ .heading = .{ .text = "A Section Heading", .level = 2 } },
                .layout = LayoutElement.content_sized(),
                .semantic = .{ .tag = .heading, .level = 2, .id = "a-section-heading" },
            });
            continue;
        }
        _ = try tree.append_child(root, .{
            .kind = .label,
            .props = .{ .label = .{ .text = prose, .wrap = true } },
            .layout = LayoutElement.content_sized(),
            .semantic = .{ .tag = .paragraph },
        });
    }
    std.debug.assert(tree.node_count == blocks + 1);
}
