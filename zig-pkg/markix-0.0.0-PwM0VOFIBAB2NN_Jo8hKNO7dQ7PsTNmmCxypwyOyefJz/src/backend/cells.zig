const std = @import("std");
const layout = @import("../layout/resolve.zig");
const tree_mod = @import("../layout/tree.zig");
const style_mod = @import("../layout/style.zig");
const measure = @import("../layout/measure.zig");
const canvas_mod = @import("canvas.zig");
const patch = @import("patch.zig");
const graphics_mod = @import("terminal/graphics.zig");

const Tree = tree_mod.Tree;
const Rect = @import("../layout/rect.zig").Rect;
const Style = style_mod.Style;
const Color = style_mod.Color;

pub const Palette = struct {
    line: u24 = 0x393552,
    muted: u24 = 0x908caa,
    surface: u24 = 0x2a273f,
};

pub const Cell = struct {
    bytes: [4]u8 = .{ ' ', 0, 0, 0 },
    len: u8 = 1,
    style: Style = .{},

    pub fn blank(style: Style) Cell {
        return .{ .bytes = .{ ' ', 0, 0, 0 }, .len = 1, .style = style };
    }

    pub fn text(self: *const Cell) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Screen = struct {
    cells: []Cell,
    width: i32 = 0,
    height: i32 = 0,
    output: []u8 = &.{},
    sources: []tree_mod.Index = &.{},
    current_source: tree_mod.Index = tree_mod.none,
    clip: ?Rect = null,
    dirty: ?[]const Rect = null,
    graphics: ?*graphics_mod.Graphics = null,

    pub fn init(storage: []Cell, width: i32, height: i32) Screen {
        std.debug.assert(width >= 0 and height >= 0);
        std.debug.assert(@as(usize, @intCast(width * height)) <= storage.len);
        return .{ .cells = storage, .width = width, .height = height };
    }

    pub const escape_per_cell: usize = 64;

    pub fn alloc(
        gpa: std.mem.Allocator,
        width: i32,
        height: i32,
        hit_testing: bool,
    ) !Screen {
        std.debug.assert(width > 0 and height > 0);
        std.debug.assert(escape_per_cell > 0);
        const capacity = @as(usize, @intCast(width)) * @as(usize, @intCast(height));
        const cells = try gpa.alloc(Cell, capacity);
        errdefer gpa.free(cells);
        const output = try gpa.alloc(u8, capacity * escape_per_cell);
        errdefer gpa.free(output);
        const sources: []tree_mod.Index = if (hit_testing)
            try gpa.alloc(tree_mod.Index, capacity)
        else
            &.{};
        var screen = Screen.init(cells, width, height);
        screen.output = output;
        screen.sources = sources;
        return screen;
    }

    pub fn free(self: *Screen, gpa: std.mem.Allocator) void {
        gpa.free(self.cells);
        gpa.free(self.output);
        if (self.sources.len > 0) gpa.free(self.sources);
        self.* = .{ .cells = &.{} };
    }

    pub fn at_source(self: *const Screen, x: i32, y: i32) tree_mod.Index {
        if (self.sources.len == 0) return tree_mod.none;
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return tree_mod.none;
        const offset = @as(usize, @intCast(y)) * @as(usize, @intCast(self.width)) +
            @as(usize, @intCast(x));
        if (offset >= self.sources.len) return tree_mod.none;
        return self.sources[offset];
    }

    pub fn resize(self: *Screen, width: i32, height: i32) void {
        std.debug.assert(width >= 0 and height >= 0);
        const wanted = @as(usize, @intCast(width)) * @as(usize, @intCast(height));
        std.debug.assert(wanted <= self.cells.len);
        self.width = width;
        self.height = height;
    }

    pub fn clear(self: *Screen, style: Style) void {
        const used = @as(usize, @intCast(self.width)) * @as(usize, @intCast(self.height));
        std.debug.assert(used <= self.cells.len);
        @memset(self.cells[0..used], Cell.blank(style));
        if (self.sources.len > 0) {
            @memset(self.sources[0..@min(used, self.sources.len)], tree_mod.none);
        }
    }

    pub fn at(self: *const Screen, x: i32, y: i32) ?*Cell {
        if (self.clip) |box| {
            if (!box.contains(x, y)) return null;
        }
        return self.cell_at(x, y);
    }

    fn cell_at(self: *const Screen, x: i32, y: i32) ?*Cell {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return null;
        const offset = @as(usize, @intCast(y)) * @as(usize, @intCast(self.width)) +
            @as(usize, @intCast(x));
        std.debug.assert(offset < self.cells.len);
        return &self.cells[offset];
    }

    pub fn erase(self: *Screen, rect: Rect, style: Style) void {
        std.debug.assert(rect.width >= 0);
        std.debug.assert(rect.height >= 0);
        const blank = Cell.blank(style);
        var row = @max(0, rect.y);
        while (row < @min(self.height, rect.bottom())) : (row += 1) {
            var column = @max(0, rect.x);
            while (column < @min(self.width, rect.right())) : (column += 1) {
                const offset = @as(usize, @intCast(row)) *
                    @as(usize, @intCast(self.width)) + @as(usize, @intCast(column));
                std.debug.assert(offset < self.cells.len);
                self.cells[offset] = blank;
                if (offset < self.sources.len) self.sources[offset] = tree_mod.none;
            }
        }
    }

    pub fn fill(self: *Screen, rect: Rect, background: Color) void {
        var row = rect.y;
        while (row < rect.y + rect.height) : (row += 1) {
            var column = rect.x;
            while (column < rect.x + rect.width) : (column += 1) {
                const cell = self.at(column, row) orelse continue;
                cell.style.background = background;
            }
        }
    }

    pub fn cover(self: *Screen, rect: Rect, background: Color) void {
        std.debug.assert(rect.width >= 0);
        std.debug.assert(rect.height >= 0);
        const blank = Cell.blank(.{ .background = background });
        var row = rect.y;
        while (row < rect.y + rect.height) : (row += 1) {
            var column = rect.x;
            while (column < rect.x + rect.width) : (column += 1) {
                const cell = self.at(column, row) orelse continue;
                cell.* = blank;
            }
        }
    }

    pub fn set(self: *Screen, x: i32, y: i32, bytes: []const u8, style: Style) void {
        std.debug.assert(bytes.len <= 4);
        std.debug.assert(bytes.len > 0);
        const cell = self.at(x, y) orelse return;
        @memset(&cell.bytes, 0);
        @memcpy(cell.bytes[0..bytes.len], bytes);
        cell.len = @intCast(bytes.len);
        const under = cell.style.background;
        cell.style = style;
        if (!style.background.is_set()) cell.style.background = under;
        if (self.sources.len > 0 and x >= 0 and y >= 0 and
            x < self.width and y < self.height)
        {
            const offset = @as(usize, @intCast(y)) * @as(usize, @intCast(self.width)) +
                @as(usize, @intCast(x));
            if (offset < self.sources.len) self.sources[offset] = self.current_source;
        }
    }

    pub fn write(self: *Screen, x: i32, y: i32, value: []const u8, style: Style) i32 {
        var column = x;
        var at_byte: usize = 0;
        while (at_byte < value.len) {
            const length = code_point_len(value[at_byte]);
            const end = @min(at_byte + length, value.len);
            self.set(column, y, value[at_byte..end], style);
            column += 1;
            at_byte = end;
        }
        return column - x;
    }

    pub fn repeat(self: *Screen, x: i32, y: i32, glyph: []const u8, count: i32, style: Style) void {
        var column: i32 = 0;
        while (column < count) : (column += 1) {
            self.set(x + column, y, glyph, style);
        }
    }
};

pub fn code_point_len(lead: u8) usize {
    if (lead < 0x80) return 1;
    if (lead & 0xe0 == 0xc0) return 2;
    if (lead & 0xf0 == 0xe0) return 3;
    if (lead & 0xf8 == 0xf0) return 4;
    return 1;
}

pub const Output = struct {
    color: bool = true,
    last_newline: bool = true,
};

pub fn write_ansi(writer: *std.Io.Writer, screen: *const Screen, options: Output) !void {
    std.debug.assert(screen.width >= 0 and screen.height >= 0);
    std.debug.assert(@as(usize, @intCast(screen.width * screen.height)) <= screen.cells.len);
    var row: i32 = 0;
    while (row < screen.height) : (row += 1) {
        try write_row(writer, screen, row, 0, last_used(screen, row, options.color), options);
        if (options.color) try writer.writeAll("\x1b[K");
        if (row + 1 < screen.height or options.last_newline) {
            try writer.writeAll(if (options.color) "\r\n" else "\n");
        }
    }
}

pub fn write_region(
    writer: *std.Io.Writer,
    screen: *const Screen,
    region: Rect,
    options: Output,
) !void {
    std.debug.assert(screen.width >= 0 and screen.height >= 0);
    std.debug.assert(@as(usize, @intCast(screen.width * screen.height)) <= screen.cells.len);
    const from = @max(0, region.x);
    const to = @min(screen.width, region.right());
    if (to <= from) return;
    var row = @max(0, region.y);
    while (row < @min(screen.height, region.bottom())) : (row += 1) {
        try writer.print("\x1b[{d};{d}H", .{ row + 1, from + 1 });
        try write_row(writer, screen, row, from, to, options);
    }
}

fn write_row(
    writer: *std.Io.Writer,
    screen: *const Screen,
    row: i32,
    from: i32,
    to: i32,
    options: Output,
) !void {
    std.debug.assert(from >= 0);
    std.debug.assert(row >= 0 and row < screen.height);
    var current: ?Style = null;
    var column = from;
    while (column < to) : (column += 1) {
        const cell = screen.cell_at(column, row).?;
        if (options.color) {
            if (current == null or !current.?.eql(cell.style)) {
                try write_style(writer, cell.style);
                current = cell.style;
            }
        }
        try writer.writeAll(cell.text());
    }
    if (options.color and current != null) try writer.writeAll("\x1b[0m");
}

fn last_used(screen: *const Screen, row: i32, color: bool) i32 {
    std.debug.assert(row >= 0 and row < screen.height);
    std.debug.assert(screen.width >= 0);
    var column = screen.width;
    while (column > 0) : (column -= 1) {
        const cell = screen.cell_at(column - 1, row).?;
        const painted = !std.mem.eql(u8, cell.text(), " ") or
            (color and cell.style.background.is_set());
        if (painted) return column;
    }
    return 0;
}

fn write_style(writer: *std.Io.Writer, style: Style) !void {
    try writer.writeAll("\x1b[0m");
    if (style.bold) try writer.writeAll("\x1b[1m");
    if (style.dim) try writer.writeAll("\x1b[2m");
    if (style.italic) try writer.writeAll("\x1b[3m");
    if (style.underline) try writer.writeAll("\x1b[4m");
    if (style.strikethrough) try writer.writeAll("\x1b[9m");
    if (style.foreground.is_set()) try write_color(writer, style.foreground, 38);
    if (style.background.is_set()) try write_color(writer, style.background, 48);
}

fn write_color(writer: *std.Io.Writer, color: Color, role: u8) !void {
    std.debug.assert(role == 38 or role == 48);
    switch (color.kind) {
        .none => {},
        .rgb => try writer.print("\x1b[{d};2;{d};{d};{d}m", .{
            role,
            color.r,
            color.g,
            color.b,
        }),
        .ansi => try writer.print("\x1b[{d};5;{d}m", .{ role, color.r }),
        .default => {},
    }
}

const event_loop = @import("loop.zig");
const terminal = @import("terminal/terminal.zig");
const input = @import("../utils/input.zig");

pub fn screen_backend(screen: *Screen) event_loop.Backend {
    std.debug.assert(screen.width > 0);
    std.debug.assert(screen.height > 0);
    return .{
        .context = screen,
        .size_fn = screen_size,
        .resizable_fn = screen_resizable,
        .resize_fn = screen_resize,
        .render_fn = screen_render,
        .poll_background_fn = screen_poll_background,
        .handle_pointer_fn = screen_handle_pointer,
        .copy_selection_fn = screen_copy_selection,
        .enter_alternate_screen = terminal.enter_alternate_screen,
        .exit_alternate_screen = terminal.exit_alternate_screen,
    };
}

fn screen_size(context: *anyopaque) event_loop.Size {
    const self: *Screen = @ptrCast(@alignCast(context));
    return .{ .width = @intCast(self.width), .height = @intCast(self.height) };
}

fn screen_resizable(context: *anyopaque) bool {
    const self: *Screen = @ptrCast(@alignCast(context));
    std.debug.assert(self.width <= std.math.maxInt(u16));
    return true;
}

fn screen_resize(context: *anyopaque, size_: terminal.TerminalSize) !void {
    const self: *Screen = @ptrCast(@alignCast(context));
    const columns_i: i32 = @intCast(size_.width);
    const columns: i32 = @max(1, columns_i);
    const rows: i32 = @min(
        @as(i32, @intCast(size_.height)),
        @as(i32, @intCast(self.cells.len / @max(1, @as(usize, @intCast(columns))))),
    );
    self.resize(columns, rows);
}

fn screen_render(context: *anyopaque, io: std.Io) !bool {
    const self: *Screen = @ptrCast(@alignCast(context));
    std.debug.assert(self.output.len > 0);
    std.debug.assert(self.output.len >= self.cells.len * Screen.escape_per_cell);
    var writer = std.Io.Writer.fixed(self.output);
    const stale = if (self.graphics) |graphics| graphics.stale() else null;
    try write_frame(&writer, self, stale);
    const wrote = writer.buffered().len > 0;
    if (wrote) try std.Io.File.stdout().writeStreamingAll(io, writer.buffered());
    if (self.graphics) |graphics| graphics.flush(io, self.dirty);
    return wrote;
}

fn write_frame(writer: *std.Io.Writer, screen: *const Screen, stale: ?Rect) !void {
    std.debug.assert(screen.width > 0);
    std.debug.assert(writer.buffered().len == 0);
    const regions = screen.dirty orelse {
        try writer.writeAll(home);
        return write_ansi(writer, screen, .{ .last_newline = false });
    };
    if (regions.len == 0 and stale == null) return;
    try writer.writeAll(home);
    for (regions) |region| try write_region(writer, screen, region, .{});
    if (stale) |region| try write_region(writer, screen, region, .{});
}

pub const home = "\x1b[H" ++ hide_cursor;

const hide_cursor = "\x1b[?25l";

fn screen_poll_background(context: *anyopaque, io: std.Io) !bool {
    const self: *Screen = @ptrCast(@alignCast(context));
    std.debug.assert(self.width > 0);
    const graphics = self.graphics orelse return false;
    return graphics.poll(io);
}

fn screen_handle_pointer(
    context: *anyopaque,
    pointer: input.Pointer,
) event_loop.PointerAction {
    const self: *Screen = @ptrCast(@alignCast(context));
    std.debug.assert(self.width > 0);
    _ = pointer;
    return .ignored;
}

fn screen_copy_selection(context: *anyopaque, io: std.Io) !void {
    const self: *Screen = @ptrCast(@alignCast(context));
    std.debug.assert(self.width > 0);
    _ = io;
}

const nesting_max: usize = 8;

fn style_of(tree: *const Tree, root: tree_mod.Index, node: tree_mod.Index, base: Style) Style {
    std.debug.assert(root < tree.len);
    std.debug.assert(node < tree.len);
    var chain: [nesting_max]tree_mod.Index = undefined;
    var depth: usize = 0;
    var walker = node;
    while (walker != root and walker != tree_mod.none and depth < nesting_max) {
        chain[depth] = walker;
        depth += 1;
        walker = tree.at(walker).parent;
    }
    var style = base;
    while (depth > 0) {
        depth -= 1;
        style = merge(style, tree.at(chain[depth]));
    }
    return style;
}

fn over(style: Style, overlay: ?Style) Style {
    const value = overlay orelse return style;
    return merge(style, &.{ .style = value });
}

pub fn merge(into: Style, node: *const tree_mod.Node) Style {
    var result = into;
    if (node.style.foreground.is_set()) result.foreground = node.style.foreground;
    if (node.style.background.is_set()) result.background = node.style.background;
    result.bold = result.bold or node.style.bold or node.element == .strong;
    result.italic = result.italic or node.style.italic or node.element == .emphasis;
    result.underline = result.underline or node.style.underline;
    result.dim = result.dim or node.style.dim;
    result.strikethrough = result.strikethrough or node.style.strikethrough;
    return result;
}

pub const FlowOptions = struct {
    x: i32,
    y: i32,
    width: i32,
    base: Style = .{},
    line_units: u8 = 1,
    wrap: bool = true,
    overlay: ?Style = null,
};

const Runs = struct {
    tree: *const Tree,
    root: tree_mod.Index,
    cursor: tree_mod.Index,
    emitted_root: bool = false,

    fn init(tree: *const Tree, root: tree_mod.Index) Runs {
        return .{ .tree = tree, .root = root, .cursor = root };
    }

    fn next(self: *Runs) ?Run {
        if (!self.emitted_root) {
            self.emitted_root = true;
            const node = self.tree.at(self.root);
            self.advance();
            if (node.text.len > 0) return .{ .node = self.root, .text = node.text };
            return self.pump();
        }
        return self.pump();
    }

    fn pump(self: *Runs) ?Run {
        while (self.cursor != tree_mod.none) {
            const here = self.cursor;
            const node = self.tree.at(here);
            self.advance();
            if (node.text.len > 0) return .{ .node = here, .text = node.text };
        }
        return null;
    }

    fn advance(self: *Runs) void {
        std.debug.assert(self.cursor != tree_mod.none);
        std.debug.assert(self.root < self.tree.len);
        const node = self.tree.at(self.cursor);
        const child = node.first_child;
        if (child != tree_mod.none and self.tree.at(child).is_inline()) {
            self.cursor = child;
            return;
        }
        var walker = self.cursor;
        while (walker != self.root and walker != tree_mod.none) {
            const current = self.tree.at(walker);
            const sibling = current.next_sibling;
            if (sibling != tree_mod.none and self.tree.at(sibling).is_inline()) {
                self.cursor = sibling;
                return;
            }
            walker = current.parent;
        }
        self.cursor = tree_mod.none;
    }
};

const Run = struct {
    node: tree_mod.Index,
    text: []const u8,
};

fn flow_paint(screen: *Screen, tree: *const Tree, index: tree_mod.Index, options: FlowOptions) i32 {
    std.debug.assert(options.line_units >= 1);
    std.debug.assert(index < tree.len);
    if (!options.wrap) return paint_literal(screen, tree, index, options);

    var runs = Runs.init(tree, index);
    var setter = Setter{ .screen = screen, .tree = tree, .root = index, .options = options };
    var word = Word{};
    while (runs.next()) |run| {
        const style = over(style_of(tree, index, run.node, options.base), options.overlay);
        var start: usize = 0;
        var at: usize = 0;
        while (at <= run.text.len) : (at += 1) {
            const at_end = at == run.text.len;
            if (!at_end and run.text[at] != ' ' and run.text[at] != '\n') continue;
            word.push(&setter, run.text[start..at], run.node, style);
            if (at_end) break;
            setter.place(&word);
            if (run.text[at] == '\n') setter.newline();
            start = at + 1;
        }
    }
    if (word.columns > 0) setter.place(&word);
    return setter.line + 1;
}

fn paint_literal(
    screen: *Screen,
    tree: *const Tree,
    index: tree_mod.Index,
    options: FlowOptions,
) i32 {
    std.debug.assert(index < tree.len);
    std.debug.assert(options.line_units >= 1);
    var line: i32 = 0;
    var column: i32 = 0;
    var runs = Runs.init(tree, index);
    while (runs.next()) |run| {
        const style = over(style_of(tree, index, run.node, options.base), options.overlay);
        screen.current_source = run.node;
        var pieces = std.mem.splitScalar(u8, run.text, '\n');
        var first = true;
        while (pieces.next()) |piece| {
            if (!first) {
                line += 1;
                column = 0;
            }
            first = false;
            column += screen.write(
                options.x + column,
                options.y + line * @as(i32, options.line_units),
                piece,
                style,
            );
        }
    }
    return line + 1;
}

const pieces_max: usize = 8;

const Piece = struct {
    text: []const u8,
    style: Style,
    node: tree_mod.Index,
};

const Word = struct {
    pieces: [pieces_max]Piece = undefined,
    len: usize = 0,
    columns: i32 = 0,
    continued: bool = false,

    fn push(
        self: *Word,
        setter: *Setter,
        text: []const u8,
        node: tree_mod.Index,
        style: Style,
    ) void {
        std.debug.assert(self.len <= pieces_max);
        std.debug.assert(self.columns >= 0);
        if (text.len == 0) return;
        if (self.len > 0) {
            const last = &self.pieces[self.len - 1];
            if (last.style.eql(style) and last.node == node and
                last.text.ptr + last.text.len == text.ptr)
            {
                last.text = last.text.ptr[0 .. last.text.len + text.len];
                self.columns += measure.columns(text);
                return;
            }
        }
        if (self.len == pieces_max) setter.place_continuing(self);
        self.pieces[self.len] = .{ .text = text, .style = style, .node = node };
        self.len += 1;
        self.columns += measure.columns(text);
    }

    fn reset(self: *Word) void {
        self.len = 0;
        self.columns = 0;
        self.continued = false;
    }
};

const Setter = struct {
    screen: *Screen,
    tree: *const Tree,
    root: tree_mod.Index,
    options: FlowOptions,
    column: i32 = 0,
    line: i32 = 0,

    fn row(self: *const Setter) i32 {
        return self.options.y + self.line * @as(i32, self.options.line_units);
    }

    fn newline(self: *Setter) void {
        self.line += 1;
        self.column = 0;
    }

    fn place(self: *Setter, word: *Word) void {
        std.debug.assert(word.len <= pieces_max);
        std.debug.assert(self.column >= 0);
        const available = self.options.width;
        if (word.columns == 0) {
            if (self.column > 0) self.column += 1;
            word.reset();
            return;
        }
        if (word.columns > available and available > 0) {
            if (self.column > 0) self.newline();
            self.draw_chopped(word);
            word.reset();
            return;
        }
        const spacing: i32 = if (self.column == 0 or word.continued) 0 else 1;
        if (available > 0 and self.column + spacing + word.columns > available) {
            self.newline();
        } else {
            self.column += spacing;
        }
        self.draw(word);
        word.reset();
    }

    fn place_continuing(self: *Setter, word: *Word) void {
        self.place(word);
        word.continued = true;
    }

    fn draw(self: *Setter, word: *const Word) void {
        for (word.pieces[0..word.len]) |piece| {
            self.screen.current_source = piece.node;
            self.column += self.screen.write(
                self.options.x + self.column,
                self.row(),
                piece.text,
                piece.style,
            );
        }
    }

    fn draw_chopped(self: *Setter, word: *const Word) void {
        const available = self.options.width;
        std.debug.assert(available > 0);
        std.debug.assert(word.len <= pieces_max);
        for (word.pieces[0..word.len]) |piece| {
            var at: usize = 0;
            while (at < piece.text.len) {
                if (self.column == available) self.newline();
                const length = code_point_len(piece.text[at]);
                const end = @min(at + length, piece.text.len);
                self.screen.current_source = piece.node;
                self.screen.set(
                    self.options.x + self.column,
                    self.row(),
                    piece.text[at..end],
                    piece.style,
                );
                self.column += 1;
                at = end;
            }
        }
    }
};

pub const Canvas = struct {
    context: *anyopaque,
    draw: *const fn (context: *anyopaque, screen: *Screen, rect: Rect, id: []const u8) void,

    damage: ?*const fn (context: *anyopaque, rect: Rect, id: []const u8) ?Rect = null,
};

pub const Options = struct {
    x: i32 = 0,
    y: i32 = 0,
    scroll: i32 = 0,
    base: Style = .{},
    palette: Palette = .{},
    canvas: ?Canvas = null,
    focus: tree_mod.Index = tree_mod.none,
    focus_style: Style = .{},
    rows_per_cell: i32 = 1,
    clip: ?Rect = null,
    cover: bool = false,
};

pub fn paint(screen: *Screen, tree: *const Tree, styles: []Style, options: Options) void {
    std.debug.assert(styles.len >= tree.len);
    std.debug.assert(options.rows_per_cell >= 1);
    cascade(tree, styles, options);
    screen.dirty = null;
    paint_region(screen, tree, styles, options, options.clip);
    request_images(screen, tree, styles, options);
}

fn request_images(
    screen: *const Screen,
    tree: *const Tree,
    styles: []const Style,
    options: Options,
) void {
    std.debug.assert(styles.len >= tree.len);
    std.debug.assert(options.rows_per_cell >= 1);
    const graphics = screen.graphics orelse return;
    if (tree.len == 0) return;
    if (painted_of(tree, 0, styles, options, screen.height)) |root| graphics.cover(root.rect);
    if (options.rows_per_cell != 1) return;
    const bounds = narrow(Rect.init(0, 0, screen.width, screen.height), options.clip).?;
    var index: tree_mod.Index = 0;
    while (index < tree.len) : (index += 1) {
        const node = tree.at(index);
        if (node.element != .image) continue;
        const it = painted_of(tree, index, styles, options, screen.height) orelse continue;
        const placement = image_placement(bounds, it.rect, node.href) orelse continue;
        graphics.request(placement);
        return;
    }
}

fn image_placement(bounds: Rect, rect: Rect, path: []const u8) ?graphics_mod.Placement {
    std.debug.assert(rect.width > 0);
    std.debug.assert(rect.height > 0);
    if (!std.fs.path.isAbsolute(path)) return null;
    if (rect.height > std.math.maxInt(u16)) return null;
    const visible = narrow(bounds, rect).?;
    if (visible.width != rect.width or visible.height <= 0) return null;
    return graphics_mod.Placement.init(
        visible,
        @intCast(visible.y - rect.y),
        @intCast(rect.height),
        path,
    ) catch null;
}

fn cascade(tree: *const Tree, styles: []Style, options: Options) void {
    std.debug.assert(styles.len >= tree.len);
    std.debug.assert(options.rows_per_cell >= 1);
    var index: tree_mod.Index = 0;
    while (index < tree.len) : (index += 1) {
        const node = tree.at(index);
        const inherited = if (node.parent == tree_mod.none)
            options.base
        else
            styles[node.parent];
        styles[index] = merge(inherited, node);

        if (options.focus != tree_mod.none and within(tree, index, options.focus)) {
            styles[index] = merge(styles[index], &.{ .style = options.focus_style });
        }
    }
}

const Painted = struct {
    rect: Rect,
    ink: Rect,
    style: Style,
    focused: bool,
};

fn painted_of(
    tree: *const Tree,
    index: tree_mod.Index,
    styles: []const Style,
    options: Options,
    height: i32,
) ?Painted {
    std.debug.assert(index < tree.len);
    std.debug.assert(options.rows_per_cell >= 1);
    const node = tree.at(index);
    if (node.is_inline()) return null;

    const scale = @max(1, options.rows_per_cell);
    const ink = Rect{
        .x = node.rect.x + options.x,
        .y = node.rect.y + options.y - options.scroll,
        .width = node.rect.width,
        .height = node.rect.height,
    };
    const rect = Rect{
        .x = ink.x,
        .y = @divFloor(ink.y, scale),
        .width = ink.width,
        .height = @max(1, @divTrunc(ink.height, scale)),
    };
    if (ink.width <= 0 or ink.height <= 0) return null;
    if (rect.y + rect.height <= 0 or rect.y >= height) return null;
    return .{
        .rect = rect,
        .ink = ink,
        .style = styles[index],
        .focused = options.focus != tree_mod.none and
            within(tree, index, options.focus),
    };
}

fn paint_region(
    screen: *Screen,
    tree: *const Tree,
    styles: []const Style,
    options: Options,
    clip: ?Rect,
) void {
    std.debug.assert(styles.len >= tree.len);
    std.debug.assert(options.rows_per_cell >= 1);
    const restore = screen.clip;
    defer screen.clip = restore;
    screen.clip = narrow(restore, clip);
    var index: tree_mod.Index = 0;
    while (index < tree.len) : (index += 1) {
        const it = painted_of(tree, index, styles, options, screen.height) orelse continue;
        if (clip) |box| {
            if (!box.overlaps(it.rect)) continue;
        }
        paint_node(screen, tree, index, it.rect, it.ink, it.style, options, it.focused);
    }
}

fn narrow(outer: ?Rect, inner: ?Rect) ?Rect {
    const wide = outer orelse return inner;
    const tight = inner orelse return wide;
    const x = @max(wide.x, tight.x);
    const y = @max(wide.y, tight.y);
    return .{
        .x = x,
        .y = y,
        .width = @min(wide.right(), tight.right()) - x,
        .height = @min(wide.bottom(), tight.bottom()) - y,
    };
}

fn within(tree: *const Tree, index: tree_mod.Index, ancestor: tree_mod.Index) bool {
    var walker = index;
    while (walker != tree_mod.none) {
        if (walker == ancestor) return true;
        walker = tree.at(walker).parent;
    }
    return false;
}

pub const Damage = struct {
    pub const Draw = canvas_mod.Draw;

    frames: [2]canvas_mod.Frame,
    parity: usize = 0,
    regions: [patch.damage_max]Rect = undefined,

    pub fn init(storage: [2][]canvas_mod.Draw) Damage {
        return .{ .frames = .{
            canvas_mod.Frame.init(storage[0]),
            canvas_mod.Frame.init(storage[1]),
        } };
    }

    pub fn alloc(gpa: std.mem.Allocator, draws_max: usize) !Damage {
        std.debug.assert(draws_max > 0);
        std.debug.assert(patch.damage_max > 0);
        const first = try gpa.alloc(canvas_mod.Draw, draws_max);
        errdefer gpa.free(first);
        const second = try gpa.alloc(canvas_mod.Draw, draws_max);
        return Damage.init(.{ first, second });
    }

    pub fn free(self: *Damage, gpa: std.mem.Allocator) void {
        gpa.free(self.frames[0].items);
        gpa.free(self.frames[1].items);
        self.* = undefined;
    }

    pub fn forget(self: *Damage) void {
        for (&self.frames) |*frame| frame.* = canvas_mod.Frame.init(frame.items);
    }
};

pub const Layer = struct {
    tree: *const Tree,
    styles: []Style,
    options: Options = .{},
};

pub fn repaint(
    screen: *Screen,
    damage: *Damage,
    tree: *const Tree,
    styles: []Style,
    options: Options,
) void {
    std.debug.assert(styles.len >= tree.len);
    std.debug.assert(options.clip == null);
    repaint_layers(screen, damage, &.{.{ .tree = tree, .styles = styles, .options = options }});
}

pub fn repaint_layers(screen: *Screen, damage: *Damage, layers: []const Layer) void {
    std.debug.assert(layers.len > 0);
    std.debug.assert(damage.parity < 2);
    const base = layers[0].options.base;
    const frame = &damage.frames[damage.parity];
    frame.reset();
    frame.width = screen.width;
    frame.height = screen.height;
    frame.background = base.background.value();
    for (layers) |layer| {
        std.debug.assert(layer.styles.len >= layer.tree.len);
        cascade(layer.tree, layer.styles, layer.options);
        describe(frame, layer, screen.height);
    }
    const dirty = dirty_regions(damage, screen, layers);
    if (dirty) |regions| {
        for (regions) |region| {
            screen.erase(region, base);
            for (layers, 0..) |layer, index| paint_layer(screen, layer, region, index > 0);
        }
    } else {
        screen.clear(base);
        for (layers, 0..) |layer, index| paint_layer(screen, layer, null, index > 0);
    }
    screen.dirty = dirty;
    for (layers) |layer| request_images(screen, layer.tree, layer.styles, layer.options);
    damage.parity = 1 - damage.parity;
}

fn paint_layer(screen: *Screen, layer: Layer, region: ?Rect, above: bool) void {
    const clip = narrow(region, layer.options.clip);
    if (clip) |box| {
        if (box.width <= 0 or box.height <= 0) return;
    }
    var options = layer.options;
    options.cover = options.cover or above;
    paint_region(screen, layer.tree, layer.styles, options, clip);
}

const partial_share: i32 = 2;

fn dirty_regions(damage: *Damage, screen: *const Screen, layers: []const Layer) ?[]const Rect {
    std.debug.assert(damage.parity < 2);
    std.debug.assert(layers.len > 0);
    const next = &damage.frames[damage.parity];
    const previous = &damage.frames[1 - damage.parity];
    const found = patch.regions(&damage.regions, previous, next) orelse return null;
    var count = found.len;
    for (layers) |layer| {
        if (!collect_holes(&damage.regions, &count, layer, screen.height)) return null;
    }
    const regions = damage.regions[0..count];
    var area: i32 = 0;
    for (regions) |region| area += region.width * region.height;
    if (area * partial_share >= screen.width * screen.height) return null;
    return regions;
}

fn collect_holes(into: []Rect, count: *usize, layer: Layer, height: i32) bool {
    std.debug.assert(into.len > 0);
    std.debug.assert(count.* <= into.len);
    const hole = layer.options.canvas orelse return true;
    const tree = layer.tree;
    var index: tree_mod.Index = 0;
    while (index < tree.len) : (index += 1) {
        if (tree.at(index).element != .canvas) continue;
        const it = painted_of(tree, index, layer.styles, layer.options, height) orelse continue;
        const ask = hole.damage orelse {
            if (!patch.merge_region(into, count, it.rect)) return false;
            continue;
        };
        const moved = ask(hole.context, it.rect, tree.at(index).id) orelse continue;
        if (!patch.merge_region(into, count, moved)) return false;
    }
    return true;
}

fn describe(out: *canvas_mod.Frame, layer: Layer, height: i32) void {
    std.debug.assert(layer.styles.len >= layer.tree.len);
    std.debug.assert(layer.options.rows_per_cell >= 1);
    var index: tree_mod.Index = 0;
    while (index < layer.tree.len) : (index += 1) {
        const it = painted_of(layer.tree, index, layer.styles, layer.options, height) orelse
            continue;
        out.push(describe_node(layer.tree, layer.styles, index, it, layer.options));
    }
}

fn describe_node(
    tree: *const Tree,
    styles: []const Style,
    index: tree_mod.Index,
    it: Painted,
    options: Options,
) canvas_mod.Draw {
    std.debug.assert(index < tree.len);
    std.debug.assert(it.rect.width > 0);
    const node = tree.at(index);
    const ground = switch (node.element) {
        .rule => rule_color(node, options),
        .image, .canvas => Color.rgb(options.palette.line),
        else => ground_of(node, it.style, it.focused),
    };
    const text = if (node.element == .canvas) node.id else canvas_mod.text_of(tree, index);
    return .{
        .rect = it.rect,
        .damage = it.rect,
        .color = ground.value(),
        .text = text,
        .digest = content_digest(tree, styles, index, text),
        .bold = it.style.bold,
        .attributes = attributes_of(it.style, ground),
        .node = index,
    };
}

const inline_depth_max: usize = 16;

fn content_digest(
    tree: *const Tree,
    styles: []const Style,
    index: tree_mod.Index,
    text: []const u8,
) u64 {
    std.debug.assert(index < tree.len);
    std.debug.assert(styles.len >= tree.len);
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&text.len));
    hasher.update(text);
    var stack: [inline_depth_max]tree_mod.Index = undefined;
    var depth: usize = 0;
    var child = tree.at(index).first_child;
    while (true) {
        while (child == tree_mod.none and depth > 0) {
            depth -= 1;
            child = tree.at(stack[depth]).next_sibling;
        }
        if (child == tree_mod.none) break;
        const kid = tree.at(child);
        if (!kid.is_inline()) {
            child = kid.next_sibling;
            continue;
        }
        const style = styles[child];
        const shape = [5]u32{
            @intCast(kid.text.len),
            style.foreground.value(),
            style.background.value(),
            attributes_of(style, style.background),
            @intFromBool(style.bold),
        };
        hasher.update(std.mem.asBytes(&shape));
        hasher.update(kid.text);
        if (kid.first_child != tree_mod.none and depth < stack.len) {
            stack[depth] = child;
            depth += 1;
            child = kid.first_child;
        } else {
            child = kid.next_sibling;
        }
    }
    return hasher.final();
}

fn attributes_of(style: Style, ground: Color) u32 {
    std.debug.assert(@backingInt(style.foreground.kind) < 4);
    std.debug.assert(@backingInt(ground.kind) < 4);
    var bits: u32 = @as(u32, style.foreground.value()) << 8;
    bits |= @as(u32, @backingInt(style.foreground.kind)) << 6;
    bits |= @as(u32, @backingInt(ground.kind)) << 4;
    if (style.dim) bits |= 1;
    if (style.italic) bits |= 2;
    if (style.underline) bits |= 4;
    if (style.strikethrough) bits |= 8;
    return bits;
}

fn ground_of(node: *const tree_mod.Node, node_style: Style, focused: bool) Color {
    if (node.style.background.is_set()) return node.style.background;
    if (focused) return node_style.background;
    return .{};
}

fn rule_color(node: *const tree_mod.Node, options: Options) Color {
    if (node.style.background.is_set()) return node.style.background;
    return Color.rgb(options.palette.line);
}

fn paint_node(
    screen: *Screen,
    tree: *const Tree,
    index: tree_mod.Index,
    rect: Rect,
    ink: Rect,
    node_style: Style,
    options: Options,
    focused: bool,
) void {
    std.debug.assert(index < tree.len);
    std.debug.assert(ink.width == rect.width);
    screen.current_source = tree_mod.none;
    const node = tree.at(index);
    switch (node.element) {
        .rule => screen.repeat(rect.x, rect.y, "\u{2500}", rect.width, .{
            .foreground = rule_color(node, options),
        }),
        .image => paint_image(screen, rect, node.text, options.palette),
        .canvas => {
            if (options.canvas) |canvas| {
                canvas.draw(canvas.context, screen, rect, node.id);
            } else {
                paint_frame(screen, rect, Color.rgb(options.palette.line));
            }
        },
        else => {
            const ground = ground_of(node, node_style, focused);
            if (ground.is_set()) {
                if (options.rows_per_cell > 1) {
                    fill_half_rows(screen, ink, ground, options.rows_per_cell);
                } else {
                    if (options.cover) screen.cover(rect, ground) else screen.fill(rect, ground);
                }
            }
            if (!holds_text(tree, index)) return;
            const padding = node.layout.padding;
            const restore = screen.clip;
            defer screen.clip = restore;
            if (node.clip) screen.clip = narrow(restore, rect);
            _ = flow_paint(screen, tree, index, .{
                .x = rect.x + padding.left,
                .y = rect.y + padding.top,
                .width = @max(0, rect.width - padding.horizontal()),
                .base = node_style,
                .line_units = node.line_units,
                .wrap = node.wrap,
                .overlay = if (focused) options.focus_style else null,
            });
        },
    }
}

const half_block = "\u{2580}";

fn fill_half_rows(screen: *Screen, rect: Rect, color: Color, scale: i32) void {
    std.debug.assert(scale > 1);
    std.debug.assert(color.is_set());
    var row = rect.y;
    while (row < rect.y + rect.height) : (row += 1) {
        const line = @divFloor(row, scale);
        const upper = @mod(row, scale) * 2 < scale;
        var column = rect.x;
        while (column < rect.x + rect.width) : (column += 1) {
            const cell = screen.at(column, line) orelse continue;
            if (!std.mem.eql(u8, cell.text(), half_block)) {
                const under = cell.style.background;
                cell.* = .{ .style = .{ .foreground = under, .background = under } };
                @memcpy(cell.bytes[0..half_block.len], half_block);
                cell.len = half_block.len;
            }
            if (upper) {
                cell.style.foreground = color;
            } else {
                cell.style.background = color;
            }
        }
    }
}

fn holds_text(tree: *const Tree, index: tree_mod.Index) bool {
    const node = tree.at(index);
    if (node.text.len > 0) return true;
    const child = node.first_child;
    return child != tree_mod.none and tree.at(child).is_inline();
}

fn paint_image(screen: *Screen, rect: Rect, alt: []const u8, palette: Palette) void {
    paint_frame(screen, rect, Color.rgb(palette.line));
    if (alt.len == 0 or rect.height < 3) return;
    const ink = Style{ .foreground = Color.rgb(palette.muted), .italic = true };
    const inner = @max(0, rect.width - 4);
    const columns = @min(measure.columns(alt), inner);
    const left = rect.x + 2 + @divTrunc(@max(0, inner - columns), 2);
    _ = screen.write(left, rect.y + @divTrunc(rect.height, 2), alt, ink);
}

fn paint_frame(screen: *Screen, rect: Rect, color: Color) void {
    std.debug.assert(rect.width >= 0);
    std.debug.assert(rect.height >= 0);
    if (rect.width < 2 or rect.height < 2) return;
    const edge = Style{ .foreground = color };
    const last_x = rect.x + rect.width - 1;
    const last_y = rect.y + rect.height - 1;
    screen.repeat(rect.x + 1, rect.y, "\u{2500}", rect.width - 2, edge);
    screen.repeat(rect.x + 1, last_y, "\u{2500}", rect.width - 2, edge);
    var row = rect.y + 1;
    while (row < last_y) : (row += 1) {
        screen.set(rect.x, row, "\u{2502}", edge);
        screen.set(last_x, row, "\u{2502}", edge);
    }
    screen.set(rect.x, rect.y, "\u{256d}", edge);
    screen.set(last_x, rect.y, "\u{256e}", edge);
    screen.set(rect.x, last_y, "\u{2570}", edge);
    screen.set(last_x, last_y, "\u{256f}", edge);
}

pub fn scroll_max(tree: *const Tree, window: i32) i32 {
    std.debug.assert(window >= 0);
    return @max(0, height_of(tree) - window);
}

pub fn height_of(tree: *const Tree) i32 {
    if (tree.len == 0) return 0;
    var tallest: i32 = 0;
    var index: tree_mod.Index = 0;
    while (index < tree.len) : (index += 1) {
        const node = tree.at(index);
        if (node.is_inline()) continue;
        tallest = @max(tallest, node.rect.y + node.rect.height);
    }
    return tallest;
}

const testing = std.testing;
const el = @import("../layout/dsl.zig");

fn render(tree: *Tree, storage: []Cell, width: i32, height: i32) Screen {
    _ = layout;
    resolve_for_test(tree, width);
    var screen = Screen.init(storage, width, height);
    screen.clear(.{});
    return screen;
}

fn resolve_for_test(tree: *Tree, width: i32) void {
    const layout_mod = @import("../layout/resolve.zig");
    _ = layout_mod.resolve(tree, .{
        .width = width,
        .height = layout_mod.unbounded,
    }, .{ .measure = @import("../layout/measure.zig").monospace });
}

fn line_at(screen: *const Screen, row: i32) []const u8 {
    const holder = struct {
        var bytes: [4096]u8 = undefined;
    };
    var at: usize = 0;
    var column: i32 = 0;
    while (column < screen.width) : (column += 1) {
        const cell = screen.at(column, row).?;
        @memcpy(holder.bytes[at..][0..cell.len], cell.text());
        at += cell.len;
    }
    while (at > 0 and holder.bytes[at - 1] == ' ') at -= 1;
    return holder.bytes[0..at];
}

test "a paragraph breaks where the measure said it would" {
    var nodes: [8]tree_mod.Node = undefined;
    var tree = Tree.init(&nodes);
    const box = try el.mount_under(&tree, tree_mod.none, el.rich(.{
        .width = .{ .fixed = 12 },
    }, .{}));
    _ = try el.mount_under(&tree, box, el.run("the quick brown fox", .{}));
    var cells: [12 * 4]Cell = undefined;
    var screen = render(&tree, &cells, 12, 4);
    _ = flow_paint(&screen, &tree, box, .{ .x = 0, .y = 0, .width = 12 });

    try testing.expectEqualStrings("the quick", line_at(&screen, 0));
    try testing.expectEqualStrings("brown fox", line_at(&screen, 1));
    try testing.expectEqual(tree.at(box).rect.height, 2);
}

test "a word split across two spans is one word" {
    var nodes: [8]tree_mod.Node = undefined;
    var tree = Tree.init(&nodes);
    const box = try el.mount_under(&tree, tree_mod.none, el.rich(.{
        .width = .{ .fixed = 7 },
    }, .{}));
    _ = try el.mount_under(&tree, box, el.run("say ", .{}));
    _ = try el.mount_under(&tree, box, el.code_span("code", .{}));
    _ = try el.mount_under(&tree, box, el.run(", now", .{}));

    var cells: [7 * 4]Cell = undefined;
    var screen = render(&tree, &cells, 7, 4);
    _ = flow_paint(&screen, &tree, box, .{ .x = 0, .y = 0, .width = 7 });

    try testing.expectEqualStrings("say", line_at(&screen, 0));
    try testing.expectEqualStrings("code,", line_at(&screen, 1));
}

test "emphasis and strong are the terminal's own attributes" {
    var nodes: [8]tree_mod.Node = undefined;
    var tree = Tree.init(&nodes);
    const box = try el.mount_under(&tree, tree_mod.none, el.rich(.{
        .width = .{ .fixed = 20 },
    }, .{}));
    _ = try el.mount_under(&tree, box, el.strong("bold", .{}));
    _ = try el.mount_under(&tree, box, el.run(" ", .{}));
    _ = try el.mount_under(&tree, box, el.emphasis("slant", .{}));

    var cells: [20 * 2]Cell = undefined;
    var screen = render(&tree, &cells, 20, 2);
    _ = flow_paint(&screen, &tree, box, .{ .x = 0, .y = 0, .width = 20 });

    try testing.expect(screen.at(0, 0).?.style.bold);
    try testing.expect(!screen.at(0, 0).?.style.italic);
    try testing.expect(screen.at(5, 0).?.style.italic);
}

test "a word longer than the measure fills lines rather than being cut" {
    var nodes: [8]tree_mod.Node = undefined;
    var tree = Tree.init(&nodes);
    const box = try el.mount_under(&tree, tree_mod.none, el.rich(.{
        .width = .{ .fixed = 6 },
    }, .{}));
    _ = try el.mount_under(&tree, box, el.run("abcdefghijkl", .{}));

    var cells: [6 * 4]Cell = undefined;
    var screen = render(&tree, &cells, 6, 4);
    _ = flow_paint(&screen, &tree, box, .{ .x = 0, .y = 0, .width = 6 });

    try testing.expectEqualStrings("abcdef", line_at(&screen, 0));
    try testing.expectEqualStrings("ghijkl", line_at(&screen, 1));
    try testing.expectEqual(tree.at(box).rect.height, 2);
}

test "a fenced block keeps the author's lines" {
    var nodes: [8]tree_mod.Node = undefined;
    var tree = Tree.init(&nodes);
    const box = try el.mount_under(&tree, tree_mod.none, el.code_block(
        "one\n  two",
        .{ .width = .{ .fixed = 20 } },
    ));

    var cells: [20 * 4]Cell = undefined;
    var screen = render(&tree, &cells, 20, 4);
    _ = flow_paint(&screen, &tree, box, .{ .x = 0, .y = 0, .width = 20, .wrap = false });

    try testing.expectEqualStrings("one", line_at(&screen, 0));
    try testing.expectEqualStrings("  two", line_at(&screen, 1));
}

test "a page is drawn where the engine put it" {
    var nodes: [16]tree_mod.Node = undefined;
    var tree = Tree.init(&nodes);
    const root = try el.mount_under(&tree, tree_mod.none, el.column(.{
        .width = .{ .fixed = 20 },
    }, .{}));
    _ = try el.mount_under(&tree, root, el.text("first", .{
        .width = .{ .fixed = 20 },
    }));
    _ = try el.mount_under(&tree, root, el.text("second", .{
        .width = .{ .fixed = 20 },
    }));
    resolve_for_test(&tree, 20);

    var cells: [20 * 4]Cell = undefined;
    var screen = Screen.init(&cells, 20, 4);
    screen.clear(.{});
    var styles: [16]Style = undefined;
    paint(&screen, &tree, &styles, .{});

    try testing.expectEqualStrings("f", screen.at(0, 0).?.text());
    try testing.expectEqualStrings("s", screen.at(0, 1).?.text());
    try testing.expectEqual(@as(i32, 2), height_of(&tree));
}

test "scrolling moves the page under the screen" {
    var nodes: [16]tree_mod.Node = undefined;
    var tree = Tree.init(&nodes);
    const root = try el.mount_under(&tree, tree_mod.none, el.column(.{
        .width = .{ .fixed = 20 },
    }, .{}));
    _ = try el.mount_under(&tree, root, el.text("first", .{ .width = .{ .fixed = 20 } }));
    _ = try el.mount_under(&tree, root, el.text("second", .{ .width = .{ .fixed = 20 } }));
    resolve_for_test(&tree, 20);

    var cells: [20 * 4]Cell = undefined;
    var screen = Screen.init(&cells, 20, 4);
    screen.clear(.{});
    var styles: [16]Style = undefined;
    paint(&screen, &tree, &styles, .{ .scroll = 1 });

    try testing.expectEqualStrings("s", screen.at(0, 0).?.text());
}

test "a rule is a line, not a wall" {
    var nodes: [8]tree_mod.Node = undefined;
    var tree = Tree.init(&nodes);
    _ = try el.mount_under(&tree, tree_mod.none, el.rule(.{
        .style = .{ .background = Color.rgb(0x393552) },
        .width = .{ .fixed = 6 },
        .height = .{ .fixed = 2 },
    }));
    resolve_for_test(&tree, 6);

    var cells: [6 * 4]Cell = undefined;
    var screen = Screen.init(&cells, 6, 4);
    screen.clear(.{});
    var styles: [8]Style = undefined;
    paint(&screen, &tree, &styles, .{});

    try testing.expectEqualStrings("\u{2500}", screen.at(0, 0).?.text());
    try testing.expectEqualStrings(" ", screen.at(0, 1).?.text());
    try testing.expect(!screen.at(0, 1).?.style.background.is_set());
}

test "plain ansi output is the page as text" {
    var storage: [32]Cell = undefined;
    var screen = Screen.init(&storage, 8, 2);
    screen.clear(.{});
    _ = screen.write(0, 0, "hello", .{ .bold = true });
    _ = screen.write(2, 1, "hi", .{});

    var bytes: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try write_ansi(&writer, &screen, .{ .color = false });
    try testing.expectEqualStrings("hello\n  hi\n", writer.buffered());
}

test "a run of one style costs one escape sequence" {
    var storage: [32]Cell = undefined;
    var screen = Screen.init(&storage, 8, 1);
    screen.clear(.{});
    _ = screen.write(0, 0, "abcd", .{ .foreground = Color.rgb(0xeb6f92) });

    var bytes: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try write_ansi(&writer, &screen, .{ .color = true });
    const emitted = writer.buffered();
    try testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, emitted, "\x1b[38;2;235;111;146m"),
    );
}

test "sub-cell rows put two colours in one terminal row" {
    var storage: [8]tree_mod.Node = undefined;
    var tree = Tree.init(&storage);
    const red = Color.rgb(0xff0000);
    const blue = Color.rgb(0x0000ff);
    try el.mount(&tree, el.column(.{ .width = .{ .fixed = 2 } }, .{
        el.column(.{
            .width = .{ .fixed = 2 },
            .height = .{ .fixed = 1 },
            .style = .{ .background = red },
        }, .{}),
        el.column(.{
            .width = .{ .fixed = 2 },
            .height = .{ .fixed = 1 },
            .style = .{ .background = blue },
        }, .{}),
    }));
    resolve_for_test(&tree, 2);

    var cells: [2 * 1]Cell = undefined;
    var styles: [8]Style = undefined;
    var screen = Screen.init(&cells, 2, 1);
    screen.clear(.{});
    paint(&screen, &tree, &styles, .{ .rows_per_cell = 2 });

    const cell = screen.at(0, 0).?;
    try testing.expectEqualStrings(half_block, cell.text());
    try testing.expect(cell.style.foreground.eql(red));
    try testing.expect(cell.style.background.eql(blue));

    screen.clear(.{});
    paint(&screen, &tree, &styles, .{});
    try testing.expect(screen.at(0, 0).?.style.background.eql(red));
}

test "a cell split into halves keeps its ground in both of them" {
    var nodes: [8]tree_mod.Node = undefined;
    var tree = Tree.init(&nodes);
    const root = try el.mount_under(&tree, tree_mod.none, el.column(.{
        .width = .{ .fixed = 4 },
        .height = .{ .fixed = 2 },
    }, .{}));
    _ = try el.mount_under(&tree, root, el.column(.{
        .width = .{ .fixed = 4 },
        .height = .{ .fixed = 1 },
    }, .{}));
    _ = try el.mount_under(&tree, root, el.column(.{
        .width = .{ .fixed = 4 },
        .height = .{ .fixed = 1 },
        .style = .{ .background = Color.rgb(0xeb6f92) },
    }, .{}));
    resolve_for_test(&tree, 4);

    const ground = Color.rgb(0x2a273f);
    var cells: [4 * 2]Cell = undefined;
    var styles: [8]Style = undefined;
    var screen = Screen.init(&cells, 4, 2);
    screen.clear(.{ .background = ground });
    paint(&screen, &tree, &styles, .{ .rows_per_cell = 2 });

    const cell = screen.at(0, 0).?;
    try testing.expectEqualStrings(half_block, cell.text());
    try testing.expect(cell.style.background.eql(Color.rgb(0xeb6f92)));
    try testing.expect(cell.style.foreground.eql(ground));
}

test "sub-cell rows leave text on whole rows" {
    var storage: [8]tree_mod.Node = undefined;
    var tree = Tree.init(&storage);
    try el.mount(&tree, el.column(.{ .width = .{ .fixed = 8 } }, .{
        el.column(.{ .width = .{ .fixed = 8 }, .height = .{ .fixed = 2 } }, .{}),
        el.text("hi", .{ .width = .{ .fixed = 8 }, .height = .{ .fixed = 2 } }),
    }));
    resolve_for_test(&tree, 8);

    var cells: [8 * 2]Cell = undefined;
    var styles: [8]Style = undefined;
    var screen = Screen.init(&cells, 8, 2);
    screen.clear(.{});
    paint(&screen, &tree, &styles, .{ .rows_per_cell = 2 });

    try testing.expectEqualStrings("h", screen.at(0, 1).?.text());
    try testing.expectEqualStrings("i", screen.at(1, 1).?.text());
}

const Page = struct {
    nodes: [64]tree_mod.Node = undefined,
    tree: Tree = undefined,

    const columns: i32 = 24;
    const rows: i32 = 12;

    fn build(self: *Page) !void {
        self.tree = Tree.init(&self.nodes);
        try el.mount(&self.tree, el.column(.{ .width = .{ .fixed = columns } }, .{
            el.heading(1, "Index", .{ .width = .{ .fixed = columns } }),
            el.rule(.{ .width = .{ .fixed = columns }, .height = .{ .fixed = 1 } }),
            el.list(.{ .width = .{ .fixed = columns } }, .{
                el.item(.{ .width = .{ .grow = .{} } }, .{
                    el.link("one", "/one/", .{ .display = .block }),
                }),
                el.item(.{ .width = .{ .grow = .{} } }, .{
                    el.link("two", "/two/", .{ .display = .block }),
                }),
                el.item(.{ .width = .{ .grow = .{} } }, .{
                    el.link("three", "/three/", .{ .display = .block }),
                }),
            }),
            el.paragraph(
                "Prose enough to run past the bottom of a short window, so a " ++
                    "scroll has somewhere to go and a row to land on.",
                .{ .width = .{ .fixed = columns } },
            ),
        }));
        resolve_for_test(&self.tree, columns);
    }
};

const Tracked = struct {
    cells: [Page.columns * Page.rows]Cell = undefined,
    draws: [2][64]canvas_mod.Draw = undefined,
    styles: [64]Style = undefined,
    screen: Screen = undefined,
    damage: Damage = undefined,

    fn start(self: *Tracked) void {
        self.screen = Screen.init(&self.cells, Page.columns, Page.rows);
        self.screen.clear(.{});
        self.damage = Damage.init(.{ &self.draws[0], &self.draws[1] });
    }

    fn frame(self: *Tracked, tree: *const Tree, options: Options) void {
        repaint(&self.screen, &self.damage, tree, &self.styles, options);
    }
};

fn touched(screen: *const Screen) i32 {
    const regions = screen.dirty orelse return screen.width * screen.height;
    var total: i32 = 0;
    for (regions) |region| total += region.width * region.height;
    return total;
}

fn same_cells(one: *const Screen, other: *const Screen) bool {
    if (one.width != other.width or one.height != other.height) return false;
    var row: i32 = 0;
    while (row < one.height) : (row += 1) {
        var column: i32 = 0;
        while (column < one.width) : (column += 1) {
            const here = one.at(column, row).?;
            const there = other.at(column, row).?;
            if (!std.mem.eql(u8, here.text(), there.text())) return false;
            if (!here.style.eql(there.style)) return false;
        }
    }
    return true;
}

fn reading(tree: *const Tree, at: usize) Options {
    return .{
        .scroll = @intCast(at % 4),
        .focus = tree.nth(.list_item, at % 3),
        .focus_style = .{ .background = Color.rgb(0xe0def4), .bold = true },
    };
}

test "a screen repainted from damage is cell for cell a painted one" {
    var page = Page{};
    try page.build();
    var tracked = Tracked{};
    tracked.start();

    var whole_cells: [Page.columns * Page.rows]Cell = undefined;
    var whole_styles: [64]Style = undefined;
    var whole = Screen.init(&whole_cells, Page.columns, Page.rows);

    var frame: usize = 0;
    while (frame < 16) : (frame += 1) {
        const options = reading(&page.tree, frame);
        tracked.frame(&page.tree, options);
        whole.clear(options.base);
        paint(&whole, &page.tree, &whole_styles, options);
        try testing.expect(same_cells(&tracked.screen, &whole));
    }
}

test "a frame in which nothing moved costs nothing" {
    var page = Page{};
    try page.build();
    var tracked = Tracked{};
    tracked.start();

    tracked.frame(&page.tree, .{});
    try testing.expect(tracked.screen.dirty == null);

    tracked.frame(&page.tree, .{});
    try testing.expectEqual(@as(usize, 0), tracked.screen.dirty.?.len);
}

test "a cursor that moved repaints the rows it touched, not the page" {
    var page = Page{};
    try page.build();
    var tracked = Tracked{};
    tracked.start();

    const highlight = Style{ .background = Color.rgb(0xe0def4), .bold = true };
    tracked.frame(&page.tree, .{
        .focus = page.tree.nth(.list_item, 0),
        .focus_style = highlight,
    });
    tracked.frame(&page.tree, .{
        .focus = page.tree.nth(.list_item, 1),
        .focus_style = highlight,
    });

    try testing.expect(tracked.screen.dirty != null);
    try testing.expect(touched(&tracked.screen) > 0);
    try testing.expect(touched(&tracked.screen) < Page.columns * Page.rows);
}

test "a paint clipped to a region leaves the rest of the screen alone" {
    var page = Page{};
    try page.build();

    var cells: [Page.columns * Page.rows]Cell = undefined;
    var styles: [64]Style = undefined;
    var screen = Screen.init(&cells, Page.columns, Page.rows);
    screen.clear(.{});
    paint(&screen, &page.tree, &styles, .{
        .clip = .{ .x = 0, .y = 2, .width = Page.columns, .height = 2 },
    });

    try testing.expectEqualStrings(" ", screen.at(0, 0).?.text());
    try testing.expectEqualStrings(" ", screen.at(0, 1).?.text());
    try testing.expect(line_at(&screen, 2).len > 0);
    try testing.expectEqualStrings(" ", screen.at(0, 4).?.text());
}

const Hole = struct {
    dirty: bool = true,
    asked: usize = 0,
    drawn: usize = 0,

    fn canvas(self: *Hole, ask: bool) Canvas {
        return .{
            .context = self,
            .draw = paint_hole,
            .damage = if (ask) moved else null,
        };
    }

    fn moved(context: *anyopaque, rect: Rect, id: []const u8) ?Rect {
        const self: *Hole = @ptrCast(@alignCast(context));
        _ = id;
        self.asked += 1;
        return if (self.dirty) rect else null;
    }

    fn paint_hole(context: *anyopaque, screen: *Screen, rect: Rect, id: []const u8) void {
        const self: *Hole = @ptrCast(@alignCast(context));
        _ = id;
        self.drawn += 1;
        screen.fill(rect, Color.rgb(0x203040));
    }
};

fn build_hole(tree: *Tree) !void {
    try el.mount(tree, el.column(.{ .width = .{ .fixed = Page.columns } }, .{
        el.heading(1, "Demo", .{ .width = .{ .fixed = Page.columns } }),
        el.column(.{
            .width = .{ .fixed = Page.columns },
            .height = .{ .fixed = 4 },
            .element = .canvas,
            .id = "wave",
        }, .{}),
    }));
    resolve_for_test(tree, Page.columns);
}

test "a hole that says it moved is repainted though the page did not" {
    var nodes: [16]tree_mod.Node = undefined;
    var tree = Tree.init(&nodes);
    try build_hole(&tree);

    var hole = Hole{};
    var tracked = Tracked{};
    tracked.start();
    const options = Options{ .canvas = hole.canvas(true) };

    tracked.frame(&tree, options);
    hole.dirty = false;
    tracked.frame(&tree, options);
    try testing.expectEqual(@as(usize, 0), tracked.screen.dirty.?.len);

    hole.dirty = true;
    const before = hole.drawn;
    tracked.frame(&tree, options);
    try testing.expectEqual(@as(usize, 1), tracked.screen.dirty.?.len);
    try testing.expectEqual(before + 1, hole.drawn);
}

test "a hole nobody can ask about is drawn every frame" {
    var nodes: [16]tree_mod.Node = undefined;
    var tree = Tree.init(&nodes);
    try build_hole(&tree);

    var hole = Hole{};
    var tracked = Tracked{};
    tracked.start();
    const options = Options{ .canvas = hole.canvas(false) };

    tracked.frame(&tree, options);
    const before = hole.drawn;
    tracked.frame(&tree, options);
    try testing.expectEqual(@as(usize, 0), hole.asked);
    try testing.expectEqual(before + 1, hole.drawn);
    try testing.expect(tracked.screen.dirty.?.len > 0);
}

test "a region is sent where it belongs and nowhere else" {
    var cells: [8 * 3]Cell = undefined;
    var screen = Screen.init(&cells, 8, 3);
    screen.clear(.{});
    _ = screen.write(0, 0, "top", .{});
    _ = screen.write(0, 1, "middle", .{});

    var bytes: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try write_region(&writer, &screen, .{ .x = 0, .y = 1, .width = 6, .height = 1 }, .{});
    const out = writer.buffered();

    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2;1H") != null);
    try testing.expect(std.mem.indexOf(u8, out, "middle") != null);
    try testing.expect(std.mem.indexOf(u8, out, "top") == null);
}

test "an image scrolled half off the screen is placed by its visible rows" {
    var nodes: [8]tree_mod.Node = undefined;
    var tree = Tree.init(&nodes);
    const root = try el.mount_under(&tree, tree_mod.none, el.column(.{
        .width = .{ .fixed = 20 },
    }, .{}));
    _ = try el.mount_under(&tree, root, el.image("/tmp/cover.png", "cover", .{
        .width = .{ .fixed = 12 },
        .height = .{ .fixed = 6 },
    }));
    resolve_for_test(&tree, 20);

    var graphics = try graphics_mod.Graphics.alloc(testing.allocator, .kitty);
    defer graphics.free(testing.allocator);
    var cells: [20 * 4]Cell = undefined;
    var screen = Screen.init(&cells, 20, 4);
    screen.graphics = &graphics;
    screen.clear(.{});
    var styles: [8]Style = undefined;
    paint(&screen, &tree, &styles, .{ .scroll = 4 });

    const placement = graphics.requested.?;
    try testing.expectEqual(@as(u16, 0), placement.y);
    try testing.expectEqual(@as(u16, 2), placement.height);
    try testing.expectEqual(@as(u16, 4), placement.crop_top_rows);
    try testing.expectEqual(@as(u16, 6), placement.full_height_rows);
}

test "a tree painted over an image hides it and a relative source is never placed" {
    var nodes: [8]tree_mod.Node = undefined;
    var tree = Tree.init(&nodes);
    try el.mount(&tree, el.image("/tmp/cover.png", "cover", .{
        .width = .{ .fixed = 8 },
        .height = .{ .fixed = 3 },
    }));
    resolve_for_test(&tree, 8);
    var overlay_nodes: [8]tree_mod.Node = undefined;
    var overlay = Tree.init(&overlay_nodes);
    try el.mount(&overlay, el.text("menu", .{ .width = .{ .fixed = 4 } }));
    resolve_for_test(&overlay, 4);

    var graphics = try graphics_mod.Graphics.alloc(testing.allocator, .kitty);
    defer graphics.free(testing.allocator);
    var cells: [8 * 3]Cell = undefined;
    var screen = Screen.init(&cells, 8, 3);
    screen.graphics = &graphics;
    screen.clear(.{});
    var styles: [8]Style = undefined;
    paint(&screen, &tree, &styles, .{});
    try testing.expect(graphics.requested != null);
    paint(&screen, &overlay, &styles, .{ .x = 2, .y = 1 });
    try testing.expect(graphics.requested == null);

    tree.at(0).href = "cover.png";
    paint(&screen, &tree, &styles, .{});
    try testing.expect(graphics.requested == null);
}

const Popup = struct {
    nodes: [8]tree_mod.Node = undefined,
    tree: Tree = undefined,
    styles: [8]Style = undefined,

    fn build(self: *Popup, label: []const u8) !void {
        self.tree = Tree.init(&self.nodes);
        try el.mount(&self.tree, el.column(.{
            .width = .{ .fixed = 10 },
            .style = .{ .background = Color.rgb(0x26233a) },
        }, .{
            el.text(label, .{ .width = .{ .fixed = 10 } }),
        }));
        resolve_for_test(&self.tree, 10);
    }

    fn layer(self: *Popup) Layer {
        return .{ .tree = &self.tree, .styles = &self.styles, .options = .{ .x = 6, .y = 3 } };
    }
};

test "a popup over the page repaints alone once it is open" {
    var page = Page{};
    try page.build();
    var tracked = Tracked{};
    tracked.start();
    var popup = Popup{};
    try popup.build("abc");

    tracked.frame(&page.tree, .{});
    tracked.frame(&page.tree, .{});
    const base = Layer{ .tree = &page.tree, .styles = &tracked.styles };
    repaint_layers(&tracked.screen, &tracked.damage, &.{ base, popup.layer() });
    try testing.expect(tracked.screen.dirty == null);
    try testing.expectEqualStrings("a", tracked.screen.at(6, 3).?.text());

    try popup.build("abd");
    repaint_layers(&tracked.screen, &tracked.damage, &.{ base, popup.layer() });
    try testing.expect(touched(&tracked.screen) > 0);
    try testing.expect(touched(&tracked.screen) <= 10);

    var whole_cells: [Page.columns * Page.rows]Cell = undefined;
    var whole_styles: [64]Style = undefined;
    var whole = Screen.init(&whole_cells, Page.columns, Page.rows);
    whole.clear(.{});
    paint(&whole, &page.tree, &whole_styles, .{});
    paint(&whole, &popup.tree, &popup.styles, popup.layer().options);
    try testing.expect(same_cells(&tracked.screen, &whole));
}

test "a clipped node keeps its text inside its own rect" {
    var nodes: [8]tree_mod.Node = undefined;
    var tree = Tree.init(&nodes);
    try el.mount(&tree, el.row(.{ .width = .{ .fixed = 12 } }, .{
        el.text("overflowing", .{ .width = .{ .fixed = 4 }, .wrap = false, .clip = true }),
        el.text("next", .{ .width = .{ .fixed = 8 }, .wrap = false }),
    }));
    resolve_for_test(&tree, 12);

    var cells: [12 * 1]Cell = undefined;
    var screen = Screen.init(&cells, 12, 1);
    screen.clear(.{});
    var styles: [8]Style = undefined;
    paint(&screen, &tree, &styles, .{});

    try testing.expectEqualStrings("o", screen.at(0, 0).?.text());
    try testing.expectEqualStrings("r", screen.at(3, 0).?.text());
    try testing.expectEqualStrings("n", screen.at(4, 0).?.text());
    try testing.expectEqualStrings(" ", screen.at(8, 0).?.text());
}

test "a default ground is the terminal's own colour and still covers what lies under it" {
    var page = Page{};
    try page.build();
    var tracked = Tracked{};
    tracked.start();
    var overlay_nodes: [4]tree_mod.Node = undefined;
    var overlay = Tree.init(&overlay_nodes);
    try el.mount(&overlay, el.column(.{
        .width = .{ .fixed = 8 },
        .height = .{ .fixed = 2 },
        .style = .{ .background = Color.default() },
    }, .{}));
    resolve_for_test(&overlay, 8);
    var overlay_styles: [4]Style = undefined;

    const base = Layer{ .tree = &page.tree, .styles = &tracked.styles };
    const top = Layer{ .tree = &overlay, .styles = &overlay_styles };
    repaint_layers(&tracked.screen, &tracked.damage, &.{ base, top });

    try testing.expectEqualStrings(" ", tracked.screen.at(0, 0).?.text());
    try testing.expectEqualStrings(" ", tracked.screen.at(7, 1).?.text());
    try testing.expect(line_at(&tracked.screen, 2).len > 0);

    var bytes: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try write_style(&writer, .{ .background = Color.default() });
    try testing.expectEqualStrings("\x1b[0m", writer.buffered());
}

fn typed(tree: *Tree, value: []const u8, cursor: []const u8) !void {
    tree.reset();
    try el.mount(tree, el.column(.{ .width = .{ .fixed = Page.columns } }, .{
        el.rich(.{ .width = .{ .fixed = Page.columns }, .wrap = false }, .{
            el.run(":", .{}),
            el.run(value, .{}),
            el.run(cursor, .{ .style = .{ .background = Color.rgb(0x31748f) } }),
        }),
    }));
    resolve_for_test(tree, Page.columns);
}

test "a run that changed inside a line repaints the line" {
    var nodes: [8]tree_mod.Node = undefined;
    var tree = Tree.init(&nodes);
    var tracked = Tracked{};
    tracked.start();

    try typed(&tree, "ab", " ");
    tracked.frame(&tree, .{});
    try typed(&tree, "ab", " ");
    tracked.frame(&tree, .{});
    try testing.expectEqual(@as(i32, 0), touched(&tracked.screen));

    try typed(&tree, "ac", " ");
    tracked.frame(&tree, .{});
    try testing.expect(touched(&tracked.screen) > 0);
    try testing.expectEqualStrings("c", tracked.screen.at(2, 0).?.text());

    try typed(&tree, "ac", "x");
    tracked.frame(&tree, .{});
    try testing.expectEqualStrings("x", tracked.screen.at(3, 0).?.text());
}
