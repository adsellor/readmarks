const std = @import("std");
const DomTree = @import("../dom/tree.zig").Tree;
const DomNode = @import("../dom/node.zig").DomNode;
const NodeKind = @import("../dom/node.zig").NodeKind;
const Semantic = @import("../dom/node.zig").Semantic;
const Color = @import("../style/color.zig").Color;
const Style = @import("../style/style.zig").Style;
const Rect = @import("../layout/rect.zig").Rect;
const color_to_rgba = @import("../backend/web/serialize.zig").color_to_rgba;
const paint = @import("paint.zig");

// Serializes a DOM tree for the web backend.
//
// Unlike the canvas serializer, which ships a flat list of rects and text runs,
// this keeps the tree: every record carries its parent and its semantic tag, so
// the renderer can build real nested elements -- <article>, <h2>, <a href> --
// rather than a sheet of positioned spans. The same records also drive
// build-time HTML, which is why text and hrefs travel with them.

pub const dom_magic: u32 = 0x4D4B5844;
pub const dom_version: u32 = 3;
pub const header_size: u32 = 20;
/// Fixed part of a node record; text, href and id bytes follow it, in that
/// order. Anything added goes on the end: a reader mirrors these offsets by
/// hand, and moving one shifts every field after it.
pub const node_record_size: u32 = 32;

pub const flags_dirty: u8 = 1;
pub const flags_focused: u8 = 2;
pub const flags_hovered: u8 = 4;
pub const flags_interactable: u8 = 8;
pub const flags_selected: u8 = 16;

pub const Header = struct {
    magic: u32,
    version: u32,
    node_count: u32,
    dirty_count: u32,
    total_size: u32,
};

pub const Writer = struct {
    bytes: []u8,
    index: usize = 0,

    pub fn write_u8(self: *Writer, value: u8) !void {
        if (self.index >= self.bytes.len) return error.BufferTooSmall;
        self.bytes[self.index] = value;
        self.index += 1;
    }

    pub fn write_u16(self: *Writer, value: u16) !void {
        if (self.bytes.len -| self.index < 2) return error.BufferTooSmall;
        std.mem.writeInt(u16, self.bytes[self.index..][0..2], value, .little);
        self.index += 2;
    }

    pub fn write_i16(self: *Writer, value: i16) !void {
        if (self.bytes.len -| self.index < 2) return error.BufferTooSmall;
        std.mem.writeInt(i16, self.bytes[self.index..][0..2], value, .little);
        self.index += 2;
    }

    pub fn write_u32(self: *Writer, value: u32) !void {
        if (self.bytes.len -| self.index < 4) return error.BufferTooSmall;
        std.mem.writeInt(u32, self.bytes[self.index..][0..4], value, .little);
        self.index += 4;
    }

    pub fn write_rgba(self: *Writer, color: Color) !void {
        const rgba = color_to_rgba(color);
        try self.write_u32(
            @as(u32, rgba.a) << 24 |
                @as(u32, rgba.b) << 16 |
                @as(u32, rgba.g) << 8 |
                @as(u32, rgba.r),
        );
    }

    pub fn write_bytes(self: *Writer, value: []const u8) !void {
        if (self.bytes.len -| self.index < value.len) return error.BufferTooSmall;
        @memcpy(self.bytes[self.index..][0..value.len], value);
        self.index += value.len;
    }

    pub fn patch_u32(self: *Writer, at: usize, value: u32) void {
        std.debug.assert(at + 4 <= self.index);
        std.mem.writeInt(u32, self.bytes[at..][0..4], value, .little);
    }
};

/// Every node in the tree.
pub fn serialize_tree(tree: *const DomTree, output: []u8) !usize {
    return serialize(tree, output, .whole_tree);
}

/// Only the nodes marked dirty.
///
/// The counterpart of what the terminal renderer already does: a frame costs
/// what changed rather than what exists. Moving a list's selection touches two
/// rows, and sending a thousand records to say so is the O(rows) repaint the
/// row nodes were made to avoid -- now paid over a wire instead of to a
/// terminal.
///
/// The records are identical to a whole-tree frame's, so a reader needs no
/// second decoder. What it does need is to know which it asked for: a partial
/// frame says nothing about the nodes it leaves out, and a reader that treats
/// their absence as removal deletes the document.
pub fn serialize_dirty(tree: *const DomTree, output: []u8) !usize {
    return serialize(tree, output, .dirty_only);
}

const Scope = enum { whole_tree, dirty_only };

fn serialize(tree: *const DomTree, output: []u8, scope: Scope) !usize {
    var writer = Writer{ .bytes = output };
    const count: u32 = switch (scope) {
        .whole_tree => tree.node_count,
        .dirty_only => tree.dirty_count,
    };
    std.debug.assert(count <= tree.node_count);
    try writer.write_u32(dom_magic);
    try writer.write_u32(dom_version);
    try writer.write_u32(count);
    try writer.write_u32(tree.dirty_count);
    const size_at = writer.index;
    try writer.write_u32(0);

    var written: u32 = 0;
    var index: DomTree.NodeIndex = 0;
    while (index < tree.node_count) : (index += 1) {
        if (scope == .dirty_only and !tree.is_dirty(index)) continue;
        try write_node(&writer, tree, index);
        written += 1;
    }
    // A count the records do not back up leaves a reader parsing whatever
    // follows the frame as a node.
    std.debug.assert(written == count);
    writer.patch_u32(size_at, @intCast(writer.index));
    return writer.index;
}

fn node_flags(tree: *const DomTree, index: DomTree.NodeIndex) u8 {
    std.debug.assert(index < tree.node_count);
    const node = tree.nodes[index].element;
    var flags: u8 = 0;
    if (node.dirty) flags |= flags_dirty;
    if (node.focused) flags |= flags_focused;
    if (node.hovered) flags |= flags_hovered;
    if (node.interactable) flags |= flags_interactable;
    if (node.kind == .list_item and node.props.list_item.selected) {
        flags |= flags_selected;
    }
    return flags;
}

/// Columns of hierarchy a row is shifted by; zero for anything that is not a
/// row, since only a list has rows to nest.
fn node_indent(node: *const DomNode) u8 {
    if (node.kind != .list_item) return 0;
    return node.props.list_item.indent;
}

fn parent_value(tree: *const DomTree, index: DomTree.NodeIndex) i16 {
    if (tree.parent_index(index)) |p| return @intCast(p);
    return -1;
}

const NodeColors = struct { fg: Color, bg: Color };

/// What a node paints, as the generator would paint it.
///
/// Shared with the static renderer rather than decided again here. A widget
/// that paints no surface of its own sends a transparent colour, which the page
/// reads as "leave whatever is underneath": a label used to be given its
/// style's background, which drew a filled box behind every line of prose that
/// neither the generator nor the terminal ever drew.
fn node_colors(tree: *const DomTree, index: DomTree.NodeIndex) NodeColors {
    const painted = paint.of(tree, index);
    return .{
        .fg = painted.foreground orelse Color.from_rgba(0, 0, 0, 0),
        .bg = painted.background orelse Color.from_rgba(0, 0, 0, 0),
    };
}

fn write_node(
    writer: *Writer,
    tree: *const DomTree,
    index: DomTree.NodeIndex,
) !void {
    std.debug.assert(index < tree.node_count);
    const node = &tree.nodes[index].element;
    const rect = node.rect();
    const colors = node_colors(tree, index);
    const text = payload_of(node_text(node));
    const href = payload_of(node.semantic.href);
    const id = payload_of(node.semantic.id);
    std.debug.assert(id.len <= semantic_id_bytes_max);
    try writer.write_u16(index);
    try writer.write_i16(parent_value(tree, index));
    try writer.write_u8(@backingInt(node.kind));
    try writer.write_u8(node_flags(tree, index));
    try writer.write_u8(@backingInt(node.semantic.tag));
    try writer.write_u8(node.semantic.level);
    try writer.write_u16(rect.x);
    try writer.write_u16(rect.y);
    try writer.write_u16(rect.width);
    try writer.write_u16(rect.height);
    try writer.write_u16(@intCast(text.len));
    try writer.write_u16(@intCast(href.len));
    try writer.write_rgba(colors.fg);
    try writer.write_rgba(colors.bg);
    try writer.write_u16(@intCast(id.len));
    try writer.write_u8(node_indent(node));
    try writer.write_u8(0);
    try writer.write_bytes(text);
    try writer.write_bytes(href);
    try writer.write_bytes(id);
}

/// A payload cut to what its length field can describe.
///
/// Writing more bytes than the length says would leave the reader parsing the
/// tail of one string as the head of the next record, so the two are derived
/// from the same slice rather than clamped twice and trusted to agree.
fn payload_of(value: []const u8) []const u8 {
    const bytes_max: usize = std.math.maxInt(u16);
    if (value.len <= bytes_max) return value;
    return value[0..bytes_max];
}

const semantic_id_bytes_max = @import("../dom/types.zig").semantic_id_bytes_max;

pub fn node_text(node: *const DomNode) []const u8 {
    return switch (node.kind) {
        .label => node.props.label.text,
        .badge => node.props.badge.text,
        .button => node.props.button.text,
        .list_item => node.props.list_item.title,
        .heading => node.props.heading.text,
        .code_block => node.props.code_block.text,
        .panel => node.props.panel.title,
        .text_input => node.props.text_input.value,
        .status_line => node.props.status_line.message,
        .image => node.props.image.path,
        .container, .list, .segmented, .rule => "",
    };
}

/// One node, as it appears in a frame.
pub const Record = struct {
    index: u16,
    /// The node's parent, or -1 for the root.
    parent: i16,
    kind: u8,
    flags: u8,
    semantic: u8,
    level: u8,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    foreground: u32,
    background: u32,
    indent: u8,
    text: []const u8,
    href: []const u8,
    id: []const u8,

    pub fn is_selected(self: Record) bool {
        return self.flags & flags_selected != 0;
    }

    pub fn is_dirty(self: Record) bool {
        return self.flags & flags_dirty != 0;
    }
};

/// Reads a frame back.
///
/// The format is mirrored by hand wherever a frame is consumed -- the page's
/// script most of all -- and a reader that mirrors it a fourth time in the
/// tests would let the two drift together. This is the one place the offsets
/// are stated for reading, so a field moved without moving them fails here
/// rather than as a misparse far downstream.
pub const FrameReader = struct {
    bytes: []const u8,
    node_count: u32,
    dirty_count: u32,
    at: u32 = header_size,
    read: u32 = 0,

    pub fn init(bytes: []const u8) !FrameReader {
        std.debug.assert(header_size == 20);
        std.debug.assert(node_record_size == 32);
        if (bytes.len < header_size) return error.FrameTruncated;
        if (std.mem.readInt(u32, bytes[0..4], .little) != dom_magic) {
            return error.NotAFrame;
        }
        if (std.mem.readInt(u32, bytes[4..8], .little) != dom_version) {
            return error.FrameVersionMismatch;
        }
        const total = std.mem.readInt(u32, bytes[16..20], .little);
        if (total > bytes.len) return error.FrameTruncated;
        return .{
            .bytes = bytes[0..total],
            .node_count = std.mem.readInt(u32, bytes[8..12], .little),
            .dirty_count = std.mem.readInt(u32, bytes[12..16], .little),
        };
    }

    /// The next record, or null once every node the header promised has been
    /// read. Bounded by that count, so a corrupt length cannot spin here.
    pub fn next(self: *FrameReader) !?Record {
        std.debug.assert(self.read <= self.node_count);
        std.debug.assert(self.at <= self.bytes.len);
        if (self.read >= self.node_count) return null;
        const start = self.at;
        if (start +| node_record_size > self.bytes.len) return error.FrameTruncated;
        const fixed = self.bytes[start..][0..node_record_size];
        const text_length = std.mem.readInt(u16, fixed[16..18], .little);
        const href_length = std.mem.readInt(u16, fixed[18..20], .little);
        const id_length = std.mem.readInt(u16, fixed[28..30], .little);
        const payload = start + node_record_size;
        const total = @as(u32, text_length) + href_length + id_length;
        if (payload +| total > self.bytes.len) return error.FrameTruncated;
        self.at = payload + total;
        self.read += 1;
        return .{
            .index = std.mem.readInt(u16, fixed[0..2], .little),
            .parent = std.mem.readInt(i16, fixed[2..4], .little),
            .kind = fixed[4],
            .flags = fixed[5],
            .semantic = fixed[6],
            .level = fixed[7],
            .x = std.mem.readInt(u16, fixed[8..10], .little),
            .y = std.mem.readInt(u16, fixed[10..12], .little),
            .width = std.mem.readInt(u16, fixed[12..14], .little),
            .height = std.mem.readInt(u16, fixed[14..16], .little),
            .foreground = std.mem.readInt(u32, fixed[20..24], .little),
            .background = std.mem.readInt(u32, fixed[24..28], .little),
            .indent = fixed[30],
            .text = self.bytes[payload..][0..text_length],
            .href = self.bytes[payload + text_length ..][0..href_length],
            .id = self.bytes[payload + text_length + href_length ..][0..id_length],
        };
    }
};

test "the record layout is fixed at these offsets" {
    // Readers mirror this layout by hand, and getting one offset wrong shifts
    // everything after it -- surfacing far away, as an unrelated error several
    // records later. These are the numbers such a reader must use.
    var tree = DomTree.init();
    _ = try tree.set_root(.{
        .kind = .label,
        .props = .{ .label = .{ .text = "ab" } },
        .layout = .{ .kind = .{ .leaf = {} }, .rect = Rect.init(3, 5, 7, 11) },
        .semantic = .{ .tag = .heading, .level = 4, .href = "xyz", .id = "one" },
    });
    var buffer: [256]u8 = undefined;
    const length = try serialize_tree(&tree, &buffer);
    try std.testing.expect(length >= header_size + node_record_size);

    const record = buffer[header_size..];
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, record[0..2], .little));
    try std.testing.expectEqual(@as(i16, -1), std.mem.readInt(i16, record[2..4], .little));
    try std.testing.expectEqual(@as(u8, @backingInt(NodeKind.label)), record[4]);
    try std.testing.expectEqual(@as(u8, @backingInt(Semantic.heading)), record[6]);
    try std.testing.expectEqual(@as(u8, 4), record[7]);
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, record[8..10], .little));
    try std.testing.expectEqual(@as(u16, 5), std.mem.readInt(u16, record[10..12], .little));
    try std.testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, record[12..14], .little));
    try std.testing.expectEqual(@as(u16, 11), std.mem.readInt(u16, record[14..16], .little));
    // Lengths sit at 16 and 18; the colours follow at 20 and 24, and what was
    // added since -- the anchor name and the row's depth -- after those.
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, record[16..18], .little));
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, record[18..20], .little));
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, record[28..30], .little));
    try std.testing.expectEqual(@as(u8, 0), record[30]);
    try std.testing.expectEqual(@as(u32, node_record_size), 32);
    try std.testing.expectEqualStrings("ab", record[32..34]);
    try std.testing.expectEqualStrings("xyz", record[34..37]);
    try std.testing.expectEqualStrings("one", record[37..40]);
    // The header ends where the first record begins.
    try std.testing.expectEqual(@as(u32, 20), header_size);
}

test "a row carries its depth and whether it is the selected one" {
    const LayoutElement = @import("../layout/tree.zig").LayoutElement;
    var tree = DomTree.init();
    const list = try tree.set_root(.{
        .kind = .list,
        .props = .{ .list = .{ .item_count = 2 } },
        .layout = LayoutElement.sized(2),
    });
    _ = try tree.append_child(list, .{
        .kind = .list_item,
        .props = .{ .list_item = .{ .title = "one" } },
        .layout = LayoutElement.sized(1),
    });
    _ = try tree.append_child(list, .{
        .kind = .list_item,
        .props = .{ .list_item = .{ .title = "two", .indent = 2 } },
        .layout = LayoutElement.sized(1),
    });
    try std.testing.expect(tree.select_row(list, 1));

    var buffer: [512]u8 = undefined;
    _ = try serialize_tree(&tree, &buffer);
    // Records are variable length, so each one is found by stepping over the
    // payload the one before it declared.
    const first = buffer[header_size + node_record_size ..];
    try std.testing.expectEqual(@as(u8, 0), first[30]);
    try std.testing.expectEqual(@as(u8, 0), first[5] & flags_selected);
    const second = first[node_record_size + "one".len ..];
    try std.testing.expectEqual(@as(u8, 2), second[30]);
    try std.testing.expect(second[5] & flags_selected != 0);
    try std.testing.expectEqualStrings("two", second[32..35]);
}

test "node records carry their text and href payloads" {
    var tree = DomTree.init();
    const root = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = .{ .kind = .{ .leaf = {} }, .rect = Rect.init(0, 0, 40, 10) },
        .semantic = .{ .tag = .article },
    });
    _ = try tree.append_child(root, .{
        .kind = .label,
        .props = .{ .label = .{ .text = "Pigeons" } },
        .layout = .{ .kind = .{ .leaf = {} }, .rect = Rect.init(0, 0, 20, 1) },
        .semantic = .{ .tag = .heading, .level = 2 },
    });
    _ = try tree.append_child(root, .{
        .kind = .label,
        .props = .{ .label = .{ .text = "source" } },
        .layout = .{ .kind = .{ .leaf = {} }, .rect = Rect.init(0, 2, 20, 1) },
        .semantic = .{ .tag = .link, .href = "https://example.com/a" },
    });

    var buffer: [1024]u8 = undefined;
    const length = try serialize_tree(&tree, &buffer);
    var reader = try FrameReader.init(buffer[0..length]);
    try std.testing.expectEqual(@as(u32, 3), reader.node_count);

    const article = (try reader.next()).?;
    try std.testing.expectEqual(@as(i16, -1), article.parent);
    try std.testing.expectEqual(@as(u8, @backingInt(NodeKind.container)), article.kind);
    try std.testing.expectEqual(@as(u8, @backingInt(Semantic.article)), article.semantic);
    try std.testing.expectEqual(@as(usize, 0), article.text.len);
    try std.testing.expectEqual(@as(usize, 0), article.href.len);

    const heading = (try reader.next()).?;
    try std.testing.expectEqual(@as(i16, 0), heading.parent);
    try std.testing.expectEqual(@as(u8, @backingInt(Semantic.heading)), heading.semantic);
    try std.testing.expectEqual(@as(u8, 2), heading.level);
    try std.testing.expectEqualStrings("Pigeons", heading.text);

    // Text and href both travel, and a reader that got the first one's length
    // wrong would find neither.
    const link = (try reader.next()).?;
    try std.testing.expectEqual(@as(u8, @backingInt(Semantic.link)), link.semantic);
    try std.testing.expectEqualStrings("source", link.text);
    try std.testing.expectEqualStrings("https://example.com/a", link.href);
    try std.testing.expectEqual(@as(u16, 2), link.y);
    try std.testing.expect((try reader.next()) == null);
}

test "an anchor name survives the frame and comes back attached to its node" {
    const LayoutElement = @import("../layout/tree.zig").LayoutElement;
    var tree = DomTree.init();
    const root = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.stack(.column, 0),
        .semantic = .{ .tag = .article },
    });
    _ = try tree.append_child(root, .{
        .kind = .heading,
        .props = .{ .heading = .{ .text = "Pigeons", .level = 2 } },
        .layout = LayoutElement.sized(1),
        .semantic = .{ .tag = .heading, .level = 2, .id = "pigeons" },
    });
    _ = try tree.append_child(root, .{
        .kind = .label,
        .props = .{ .label = .{ .text = "Pigeons" } },
        .layout = LayoutElement.sized(1),
        .semantic = .{ .tag = .link, .href = "#pigeons" },
    });
    try tree.evaluate(Rect.init(0, 0, 40, 10));

    var buffer: [1024]u8 = undefined;
    const length = try serialize_tree(&tree, &buffer);
    var reader = try FrameReader.init(buffer[0..length]);
    _ = try reader.next();
    const heading = (try reader.next()).?;
    try std.testing.expectEqualStrings("pigeons", heading.id);
    const link = (try reader.next()).?;
    // The link points at the name the heading carries, so the page can resolve
    // one to the other without either knowing where the other was placed.
    try std.testing.expectEqualStrings("#pigeons", link.href);
    try std.testing.expectEqual(@as(usize, 0), link.id.len);
    try std.testing.expectEqual(heading.id.len + 1, link.href.len);
}

test "a frame from a different version is refused rather than misread" {
    var tree = DomTree.init();
    _ = try tree.set_root(.{
        .kind = .label,
        .props = .{ .label = .{ .text = "x" } },
        .layout = .{ .kind = .{ .leaf = {} }, .rect = Rect.init(0, 0, 4, 1) },
    });
    var buffer: [256]u8 = undefined;
    const length = try serialize_tree(&tree, &buffer);
    try std.testing.expect(FrameReader.init(buffer[0..length]) catch null != null);
    std.mem.writeInt(u32, buffer[4..8], dom_version + 1, .little);
    try std.testing.expectError(
        error.FrameVersionMismatch,
        FrameReader.init(buffer[0..length]),
    );
    std.mem.writeInt(u32, buffer[0..4], 0, .little);
    try std.testing.expectError(error.NotAFrame, FrameReader.init(buffer[0..length]));
}

test "a moved selection costs two records, not the document" {
    const LayoutElement = @import("../layout/tree.zig").LayoutElement;
    var tree = DomTree.init();
    const list = try tree.set_root(.{
        .kind = .list,
        .props = .{ .list = .{ .item_count = 200 } },
        .layout = LayoutElement.sized(200),
        .semantic = .{ .tag = .list },
    });
    var row: u16 = 0;
    while (row < 200) : (row += 1) {
        _ = try tree.append_child(list, .{
            .kind = .list_item,
            .props = .{ .list_item = .{ .title = "row" } },
            .layout = LayoutElement.sized(1),
            .semantic = .{ .tag = .list_item },
        });
    }
    try tree.evaluate(Rect.init(0, 0, 30, 200));
    tree.clear_dirty();

    var buffer: [64 * 1024]u8 = undefined;
    try std.testing.expect(tree.select_row(list, 0));
    tree.clear_dirty();
    try std.testing.expect(tree.select_row(list, 40));

    const partial = try serialize_dirty(&tree, &buffer);
    var reader = try FrameReader.init(buffer[0..partial]);
    try std.testing.expectEqual(@as(u32, 2), reader.node_count);
    const lost = (try reader.next()).?;
    const gained = (try reader.next()).?;
    try std.testing.expect(!lost.is_selected());
    try std.testing.expect(gained.is_selected());
    try std.testing.expectEqual(@as(u16, 41), gained.index);
    try std.testing.expect((try reader.next()) == null);

    // And the whole tree is very much larger, which is the point.
    const whole = try serialize_tree(&tree, &buffer);
    try std.testing.expect(whole > partial * 20);
}

test "a frame with nothing dirty carries no records at all" {
    var tree = DomTree.init();
    _ = try tree.set_root(.{
        .kind = .label,
        .props = .{ .label = .{ .text = "settled" } },
        .layout = .{ .kind = .{ .leaf = {} }, .rect = Rect.init(0, 0, 8, 1) },
    });
    tree.clear_dirty();
    var buffer: [256]u8 = undefined;
    const length = try serialize_dirty(&tree, &buffer);
    try std.testing.expectEqual(@as(usize, header_size), length);
    var reader = try FrameReader.init(buffer[0..length]);
    try std.testing.expectEqual(@as(u32, 0), reader.node_count);
    try std.testing.expect((try reader.next()) == null);
}

test "serialize tree reports a buffer that is too small" {
    var tree = DomTree.init();
    _ = try tree.set_root(.{
        .kind = .label,
        .props = .{ .label = .{ .text = "a rather long stretch of text" } },
        .layout = .{ .kind = .{ .leaf = {} }, .rect = Rect.init(0, 0, 40, 1) },
    });
    var buffer: [24]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, serialize_tree(&tree, &buffer));
}

test "serialize tree produces header and node records" {
    var tree = DomTree.init();
    _ = try tree.set_root(.{
        .kind = .button,
        .props = .{ .button = .{ .text = "OK" } },
        .layout = .{
            .kind = .{ .leaf = {} },
            .rect = Rect.init(0, 0, 4, 1),
        },
        .interactable = true,
    });
    var buffer: [256]u8 = undefined;
    const length = try serialize_tree(&tree, &buffer);
    try std.testing.expect(length >= header_size + node_record_size);
    const magic = std.mem.readInt(u32, buffer[0..4], .little);
    try std.testing.expectEqual(dom_magic, magic);
}

test "serialize tree empty produces header only" {
    var tree = DomTree.init();
    var buffer: [64]u8 = undefined;
    const length = try serialize_tree(&tree, &buffer);
    try std.testing.expectEqual(@as(usize, header_size), length);
}
