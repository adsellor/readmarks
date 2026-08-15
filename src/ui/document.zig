//! A scrolling document pane. The parsed article is flattened into styled
//! lines and written into one mounted row per visible line, so scrolling moves
//! text through fixed rows instead of relaying the tree out.
//!
//! Every line reserves a two-column gutter for its block's prefix. Body text
//! then starts in the same column as a heading's `#` or a quote's bar, which
//! is what gives the document a straight left margin.

const std = @import("std");
const markix = @import("markix");
const dom = markix.dom;
const layout = markix.layout;
const document = markix.document;
const theme = @import("../theme.zig");
const tokens = @import("tokens.zig");

const NodeIndex = dom.DomTree.NodeIndex;
const LayoutElement = layout.LayoutElement;
const Rect = layout.Rect;
const text_measure = layout.text_measure;

pub const rows_max: u16 = 96;
pub const gutter_width: u16 = 2;

pub fn measure_for(inner_width: u16, measure_max: u16) u16 {
    std.debug.assert(measure_max > gutter_width);
    const width = @min(inner_width, measure_max);
    std.debug.assert(width <= inner_width);
    return width;
}

/// How much of an article image is on screen. Derived from the scroll by the
/// host, because it moves the text rows underneath it and so belongs to the
/// shape rather than to per-frame props.
pub const ImageWindow = struct {
    /// Rows the image occupies in the line stream; zero when there is none.
    rows: u16 = 0,
    visible_rows: u16 = 0,
    crop_top: u16 = 0,
};

pub const Slot = struct {
    mounted: bool = false,
    panel: NodeIndex = 0,
    image: NodeIndex = 0,
    /// Two nodes per row: the gutter and the text.
    first_row: NodeIndex = 0,
    row_count: u16 = 0,
    inner: Rect = Rect.init(0, 0, 0, 0),
};

pub const Line = struct {
    gutter: []const u8 = "",
    text: []const u8 = "",
    style: markix.Style = undefined,
};

pub const Config = struct {
    title: []const u8,
    meta: []const u8,
    focused: bool,
    /// Absent when nothing is selected, in which case the pane says so.
    empty_text: ?[]const u8 = null,
    image_path: ?[]const u8 = null,
};

pub fn mount(
    tree: *dom.DomTree,
    parent: NodeIndex,
    placement: Rect,
    rows: u16,
    width: u16,
    image: ImageWindow,
) !Slot {
    std.debug.assert(rows <= rows_max);
    var slot = Slot{ .mounted = true };
    slot.panel = try tree.append_child(parent, .{
        .kind = .panel,
        .props = .{ .panel = .{
            .chrome = tokens.pane_chrome,
            .style = theme.panel_style,
        } },
        .layout = LayoutElement.placed_free(
            placement.x,
            placement.y,
            placement.width,
            placement.height,
        ),
    });
    var top: u16 = 0;
    if (image.visible_rows > 0) {
        slot.image = try tree.append_child(slot.panel, .{
            .kind = .image,
            .props = .{ .image = .{} },
            .layout = LayoutElement.placed(0, 0, width, image.visible_rows),
        });
        top = image.visible_rows;
    }
    slot.first_row = tree.node_count;
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        _ = try tree.append_child(slot.panel, .{
            .kind = .label,
            .props = .{ .label = .{} },
            .layout = LayoutElement.placed(0, top + row, gutter_width, 1),
        });
        _ = try tree.append_child(slot.panel, .{
            .kind = .label,
            .props = .{ .label = .{} },
            .layout = LayoutElement.placed(
                gutter_width,
                top + row,
                width -| gutter_width,
                1,
            ),
        });
    }
    slot.row_count = rows;
    return slot;
}

pub fn update_frame(tree: *dom.DomTree, slot: *const Slot, config: Config) void {
    if (!slot.mounted) return;
    tree.set_focused(slot.panel, config.focused);
    tree.set_props(slot.panel, .{ .panel = .{
        .style = theme.pane_style(theme.accent, config.focused),
        .chrome = tokens.pane_chrome,
        .title = config.title,
        .meta = config.meta,
    } });
}

pub fn update_image(
    tree: *dom.DomTree,
    slot: *const Slot,
    path: []const u8,
    image: ImageWindow,
) void {
    if (slot.image == 0) return;
    tree.set_props(slot.image, .{ .image = .{
        .path = path,
        .id = 1,
        .crop_top_rows = image.crop_top,
        .full_height_rows = image.rows,
    } });
}

/// Writes one flattened line into the mounted row at `index`.
pub fn set_line(
    tree: *dom.DomTree,
    slot: *const Slot,
    index: u16,
    line: ?Line,
) void {
    std.debug.assert(slot.mounted);
    std.debug.assert(index < slot.row_count);
    const gutter_node = slot.first_row + index * 2;
    const text_node = gutter_node + 1;
    const value = line orelse {
        tree.set_props(gutter_node, .{ .label = .{} });
        tree.set_props(text_node, .{ .label = .{} });
        return;
    };
    tree.set_props(gutter_node, .{ .label = .{
        .text = value.gutter,
        .style = value.style,
    } });
    tree.set_props(text_node, .{ .label = .{
        .text = value.text,
        .style = value.style,
    } });
}

/// Writes a plain message where the document would be.
pub fn set_message(tree: *dom.DomTree, slot: *const Slot, text: []const u8) void {
    if (slot.row_count == 0) return;
    var style = theme.panel_style;
    style.foreground = theme.muted;
    set_line(tree, slot, 0, .{ .text = text, .style = style });
    var row: u16 = 1;
    while (row < slot.row_count) : (row += 1) set_line(tree, slot, row, null);
}

/// Fills `out` with the document's lines starting `scroll` lines in, and
/// reports how many were written.
pub fn window(
    parsed: *const document.Document,
    width: u16,
    scroll: u16,
    image_rows: u16,
    out: []Line,
) u16 {
    std.debug.assert(parsed.count <= document.block_count_max);
    std.debug.assert(out.len <= rows_max);
    if (width == 0 or out.len == 0) return 0;
    var cursor = Cursor{ .scroll = scroll, .out = out };
    var line: u16 = 0;
    while (line < image_rows) : (line += 1) cursor.emit(.{ .style = theme.panel_style });
    var index: u8 = 0;
    while (index < parsed.count and !cursor.full()) : (index += 1) {
        const block = &parsed.blocks[index];
        emit_block(&cursor, block, width);
        if (index + 1 < parsed.count) cursor.emit(.{ .style = theme.panel_style });
    }
    return cursor.written;
}

/// Lines the whole document occupies, for the scroll bounds.
pub fn line_count(
    parsed: *const document.Document,
    width: u16,
    image_rows: u16,
) u16 {
    std.debug.assert(parsed.count <= document.block_count_max);
    if (width == 0) return 0;
    var count: u16 = image_rows;
    var index: u8 = 0;
    while (index < parsed.count) : (index += 1) {
        const block = &parsed.blocks[index];
        count +|= block_lines(block, width);
        if (index + 1 < parsed.count) count +|= 1;
    }
    return count;
}

const Cursor = struct {
    scroll: u16,
    out: []Line,
    logical: u16 = 0,
    written: u16 = 0,

    fn full(self: *const Cursor) bool {
        return self.written >= self.out.len;
    }

    fn emit(self: *Cursor, line: Line) void {
        if (self.logical >= self.scroll and self.written < self.out.len) {
            self.out[self.written] = line;
            self.written += 1;
        }
        self.logical +|= 1;
    }
};

fn emit_block(cursor: *Cursor, block: *const document.Block, width: u16) void {
    const presentation = block_presentation(block.kind);
    emit_text(cursor, block.text.bytes(), presentation, width);
    if (!block.url.is_empty()) {
        emit_text(cursor, block.url.bytes(), link_presentation(), width);
    }
}

fn emit_text(
    cursor: *Cursor,
    text: []const u8,
    presentation: Presentation,
    width: u16,
) void {
    const text_width = @max(width -| gutter_width, 1);
    var offset: usize = 0;
    var first = true;
    while (offset < text.len and !cursor.full()) {
        const line = text_measure.next_line(text, offset, text_width);
        cursor.emit(.{
            .gutter = if (first) presentation.prefix else "",
            .text = line.text,
            .style = presentation.style,
        });
        if (line.next <= offset) break;
        offset = line.next;
        first = false;
    }
}

fn block_lines(block: *const document.Block, width: u16) u16 {
    const text_width = @max(width -| gutter_width, 1);
    var count = text_measure.wrapped_rows(block.text.bytes(), text_width);
    if (!block.url.is_empty()) {
        count +|= text_measure.wrapped_rows(block.url.bytes(), text_width);
    }
    return count;
}

const Presentation = struct {
    prefix: []const u8,
    style: markix.Style,
};

fn block_presentation(kind: document.Kind) Presentation {
    return switch (kind) {
        .paragraph => .{ .prefix = "", .style = body_style(theme.foreground) },
        .heading => .{ .prefix = "# ", .style = bold_style(theme.accent_warm) },
        .list_item => .{ .prefix = "- ", .style = body_style(theme.foreground) },
        .quote => .{ .prefix = "| ", .style = body_style(theme.accent_cool) },
        .code => .{ .prefix = "  ", .style = code_style() },
        .link => link_presentation(),
        .image => .{ .prefix = "[]", .style = bold_style(theme.accent) },
    };
}

fn link_presentation() Presentation {
    return .{ .prefix = "  ", .style = body_style(theme.accent_cool) };
}

fn body_style(foreground: markix.Color) markix.Style {
    var style = theme.panel_style;
    style.foreground = foreground;
    return style;
}

fn bold_style(foreground: markix.Color) markix.Style {
    return body_style(foreground);
}

fn code_style() markix.Style {
    var style = theme.panel_style;
    style.foreground = theme.command;
    style.background = theme.panel_alt;
    return style;
}

test "a block's prefix lands in the gutter and its text beside it" {
    const parsed = document.parse("<h1>Heading</h1><p>Body text.</p>");
    var lines: [8]Line = undefined;
    const written = window(&parsed, 40, 0, 0, &lines);
    try std.testing.expect(written >= 3);
    try std.testing.expectEqualStrings("# ", lines[0].gutter);
    try std.testing.expectEqualStrings("Heading", lines[0].text);
    // A blank row separates the blocks, and body text has no prefix.
    try std.testing.expectEqualStrings("", lines[1].text);
    try std.testing.expectEqualStrings("", lines[2].gutter);
    try std.testing.expectEqualStrings("Body text.", lines[2].text);
}

test "scrolling drops the lines above it rather than repeating them" {
    const parsed = document.parse("<h1>Heading</h1><p>Body text.</p>");
    var lines: [8]Line = undefined;
    const written = window(&parsed, 40, 2, 0, &lines);
    try std.testing.expect(written >= 1);
    try std.testing.expectEqualStrings("Body text.", lines[0].text);
}

test "the line count covers every block and the rows between them" {
    const parsed = document.parse("<h1>Heading</h1><p>Body text.</p>");
    // Heading, separator, body.
    try std.testing.expectEqual(@as(u16, 3), line_count(&parsed, 40, 0));
}

test "an image reserves its rows at the top of the stream" {
    const parsed = document.parse("<p>Body text.</p>");
    var lines: [12]Line = undefined;
    const without = line_count(&parsed, 40, 0);
    try std.testing.expectEqual(without + 6, line_count(&parsed, 40, 6));

    const written = window(&parsed, 40, 0, 6, &lines);
    try std.testing.expect(written > 6);
    try std.testing.expectEqualStrings("", lines[0].text);
    try std.testing.expectEqualStrings("Body text.", lines[6].text);
}

test "a narrow pane wraps a block across rows" {
    const parsed = document.parse(
        "<p>Reliable systems software with explicit operational limits.</p>",
    );
    var lines: [16]Line = undefined;
    const written = window(&parsed, 20, 0, 0, &lines);
    try std.testing.expect(written > 1);
    try std.testing.expectEqual(written, line_count(&parsed, 20, 0));
    // Only the first row of a block carries the prefix.
    try std.testing.expectEqualStrings("", lines[1].gutter);
}
