const std = @import("std");
const shared_paint = @import("paint.zig");
const DomTree = @import("../dom/tree.zig").Tree;
const DomNode = @import("../dom/node.zig").DomNode;
const NodeKind = @import("../dom/node.zig").NodeKind;
const Semantic = @import("../dom/node.zig").Semantic;
const Color = @import("../style/color.zig").Color;
const Style = @import("../style/style.zig").Style;
const Attributes = @import("../style/text_style.zig").Attributes;
const Rect = @import("../layout/rect.zig").Rect;
const color_to_rgba = @import("../backend/web/serialize.zig").color_to_rgba;

// Renders a DOM tree as HTML, one element per widget.
//
// This is the terminal renderer's counterpart: the same nodes, the same props,
// the same widget vocabulary, drawn with elements instead of cells. Colours
// come from each widget's Style exactly as they do on a terminal, so a theme
// is defined once in markix rather than restated in a stylesheet.
//
// Every position is resolved by the layout engine. Elements are placed
// absolutely and text is pre-wrapped, so the browser performs no layout of its
// own and cannot disagree with what was measured.

pub const depth_max: u8 = 32;

pub const Options = struct {
    /// Advance of one cell. Must match the rendered font, or glyphs drift out
    /// of the columns the layout assigned them.
    cell_width_px: u16 = 9,
    cell_height_px: u16 = 19,
    /// Tag each element with the widget that produced it and whether the
    /// layout considered it dirty. Off by default: it is for inspecting a
    /// render, not for shipping.
    annotate: bool = false,
};

pub const Renderer = struct {
    writer: *std.Io.Writer,
    options: Options,

    pub fn init(writer: *std.Io.Writer, options: Options) Renderer {
        std.debug.assert(options.cell_width_px > 0);
        std.debug.assert(options.cell_height_px > 0);
        return .{ .writer = writer, .options = options };
    }

    /// Emits the whole tree. Depth-first without recursion: the frame stack is
    /// explicit and bounded, so nesting cannot run away.
    pub fn render(self: *Renderer, tree: *const DomTree) !void {
        std.debug.assert(self.options.cell_width_px > 0);
        if (tree.node_count == 0) return;
        std.debug.assert(tree.root != null);

        var stack: [depth_max]Frame = undefined;
        var depth: u8 = 0;
        stack[0] = try self.open(tree, 0, .{}, null);
        depth = 1;

        var guard: u32 = 0;
        const guard_max: u32 = @as(u32, tree.node_count) * 2 + depth_max;
        while (depth > 0) {
            guard += 1;
            std.debug.assert(guard <= guard_max);
            const frame = &stack[depth - 1];
            const next = frame.child;
            if (next) |child_index| {
                std.debug.assert(child_index < tree.node_count);
                frame.child = tree.nodes[child_index].next_sibling;
                std.debug.assert(depth < depth_max);
                stack[depth] = try self.open(tree, child_index, frame.origin, frame.tag);
                depth += 1;
                continue;
            }
            try self.close(frame.*);
            depth -= 1;
        }
        std.debug.assert(depth == 0);
    }

    /// Writes a node's opening tag and its own content, returning the frame
    /// describing what still has to be closed.
    fn open(
        self: *Renderer,
        tree: *const DomTree,
        index: DomTree.NodeIndex,
        origin: Origin,
        parent_tag: ?Element,
    ) !Frame {
        std.debug.assert(tree.node_count > 0);
        std.debug.assert(index < tree.node_count);
        const node = &tree.nodes[index].element;
        const rect = node.rect();
        const tag = element_in(parent_tag, node);

        try self.writer.print("<{s}", .{tag.name()});
        try self.write_attributes(node);
        try self.write_state(node);
        try self.write_annotations(node);
        try self.write_box(tree, index, rect, origin);

        if (tag.is_void()) return Frame.void_leaf(tag);
        try self.write_own_content(tree, index);
        if (node.kind == .status_line) try self.write_hints(node);
        if (node.kind == .panel) try self.write_panel_chrome(node);

        // Children are placed by the layout, including the pieces a run of
        // text was flowed into. Nothing is wrapped or arranged here.
        return .{
            .tag = tag,
            .origin = content_origin(node, rect),
            .child = tree.nodes[index].first_child,
        };
    }

    fn close(self: *Renderer, frame: Frame) !void {
        if (frame.void_element) return;
        try self.writer.print("</{s}>", .{frame.tag.name()});
    }

    fn write_attributes(self: *Renderer, node: *const DomNode) !void {
        std.debug.assert(node.semantic.href.len <= 4096);
        std.debug.assert(node.semantic.level <= 6);
        try self.write_id(node);
        if (node.semantic.tag == .link) {
            try self.writer.writeAll(" href=\"");
            try write_escaped(self.writer, node.semantic.href);
            try self.writer.writeAll("\"");
            return;
        }
        if (node.semantic.tag != .image) return;
        try self.writer.writeAll(" src=\"");
        try write_escaped(self.writer, node.semantic.href);
        try self.writer.writeAll("\" alt=\"");
        try write_escaped(self.writer, text_of(node));
        try self.writer.writeAll("\" loading=\"lazy\"");
    }

    /// The name a link elsewhere in the document points at.
    fn write_id(self: *Renderer, node: *const DomNode) !void {
        const id = node.semantic.id;
        if (id.len == 0) return;
        std.debug.assert(id.len <= semantic_id_bytes_max);
        try self.writer.writeAll(" id=\"");
        try write_escaped(self.writer, id);
        try self.writer.writeAll("\"");
    }

    /// State the DOM owns, said in the terms a document has for it.
    ///
    /// The terminal renderer draws this state as colour; a document cannot,
    /// because a reader may be navigating it without seeing it. A selected row
    /// is where the reader is, which is what `aria-current` means, and a node
    /// the tree considers interactable has to be reachable by keyboard whether
    /// or not it happens to be an anchor.
    fn write_state(self: *Renderer, node: *const DomNode) !void {
        if (node.kind == .list_item and node.props.list_item.selected) {
            try self.writer.writeAll(" aria-current=\"true\"");
        }
        if (!node.interactable) return;
        if (node.semantic.tag == .link and node.semantic.href.len > 0) return;
        try self.writer.writeAll(" tabindex=\"0\"");
    }

    /// Records which widget produced an element and whether the layout had it
    /// marked dirty.
    ///
    /// The dirty flag is what drives incremental repaint: on a terminal only
    /// dirty nodes are redrawn. A generated document has no frames to compare,
    /// so surfacing the flag is the only way to see the mechanism at all --
    /// and a stylesheet can then outline exactly what a repaint would touch.
    fn write_annotations(self: *Renderer, node: *const DomNode) !void {
        if (!self.options.annotate) return;
        try self.writer.print(" data-mx=\"{s}\"", .{@tagName(node.kind)});
        if (node.dirty) try self.writer.writeAll(" data-mx-dirty=\"1\"");
    }

    /// Position and colour, both from the node itself.
    ///
    /// Coordinates are parent-relative: the layout works in absolute page
    /// space, but these elements nest and are absolutely positioned, so each
    /// resolves against its parent. Emitting the absolute value would add
    /// every ancestor's offset again at each level.
    fn write_box(
        self: *Renderer,
        tree: *const DomTree,
        index: DomTree.NodeIndex,
        rect: Rect,
        origin: Origin,
    ) !void {
        std.debug.assert(index < tree.node_count);
        std.debug.assert(rect.x >= origin.x or rect.width == 0);
        const width_px = self.options.cell_width_px;
        const height_px = self.options.cell_height_px;
        try self.writer.print(
            " style=\"left:{d}px;top:{d}px;width:{d}px;height:{d}px",
            .{
                (rect.x -| origin.x) * width_px,
                (rect.y -| origin.y) * height_px,
                rect.width * width_px,
                rect.height * height_px,
            },
        );
        try self.write_paint(tree, index);
        try self.writer.writeAll("\">");
    }

    /// Colours a widget the same way the terminal renderer does, from the
    /// Style its props carry.
    fn write_paint(self: *Renderer, tree: *const DomTree, index: DomTree.NodeIndex) !void {
        std.debug.assert(self.options.cell_width_px > 0);
        std.debug.assert(index < tree.node_count);
        const paint = shared_paint.of(tree, index);
        if (paint.background) |background| {
            try self.writer.writeAll(";background:");
            try write_color(self.writer, background);
        }
        if (paint.foreground) |foreground| {
            try self.writer.writeAll(";color:");
            try write_color(self.writer, foreground);
        }
        if (paint.attributes.bold) try self.writer.writeAll(";font-weight:700");
        if (paint.attributes.dim) try self.writer.writeAll(";opacity:0.65");
        if (paint.attributes.underline) {
            try self.writer.writeAll(";text-decoration:underline");
        }
    }

    /// Text a node prints itself, as opposed to text held by its children.
    fn write_own_content(
        self: *Renderer,
        tree: *const DomTree,
        index: DomTree.NodeIndex,
    ) !void {
        std.debug.assert(index < tree.node_count);
        const node = &tree.nodes[index].element;
        if (tree.nodes[index].first_child != null) return;
        const text = text_of(node);
        if (text.len == 0) return;
        try write_escaped(self.writer, text);
    }

    /// A panel's own chrome: its rail, its title and its meta.
    ///
    /// A panel that holds children never writes its own text -- `text_of`
    /// would be the title, and a node with children keeps its text for the
    /// measure pass rather than printing it. So the title of every panel that
    /// contained anything, which is every panel, was silently dropped: a post
    /// rendered without its own name on it, and the contents rail without a
    /// heading. The terminal drew all three the whole time, which is exactly
    /// the divergence between the two renderers this design exists to prevent.
    ///
    /// Placed at the columns `widgets/panel.zig` puts them at, so the two
    /// renderers agree cell for cell.
    fn write_panel_chrome(self: *Renderer, node: *const DomNode) !void {
        std.debug.assert(node.kind == .panel);
        std.debug.assert(self.options.cell_width_px > 0);
        const props = node.props.panel;
        const rect = node.rect();
        if (rect.width == 0 or rect.height == 0) return;
        const chrome = props.chrome;
        const rail_width = @min(@as(u16, chrome.rail_width), rect.width);
        try self.write_panel_rail(props, rect, rail_width);

        const header_width = rect.width - rail_width;
        const padding_left = @min(@as(u16, chrome.content_padding_left), header_width);
        if (props.title.len > 0 and padding_left < header_width) {
            try self.write_chrome_text(
                props.title,
                rail_width + padding_left,
                if (node.focused) props.style.accent else props.style.muted,
                chrome.title_attributes,
            );
        }

        const padding_right = @min(@as(u16, chrome.meta_padding_right), header_width);
        const meta_length: u16 = @intCast(@min(props.meta.len, header_width -| padding_right));
        const meta_x = rect.width -| padding_right -| meta_length;
        const title_length: u16 = @intCast(@min(props.title.len, header_width));
        const title_end = rail_width + padding_left + title_length;
        if (meta_length > 0 and meta_x > title_end) {
            try self.write_chrome_text(
                props.meta[0..meta_length],
                meta_x,
                props.style.muted,
                chrome.meta_attributes,
            );
        }
    }

    /// The bar down a panel's edge. A filled rect on the terminal, and a box
    /// with a background here, because that is the same thing.
    fn write_panel_rail(
        self: *Renderer,
        props: @import("../dom/types.zig").PanelProps,
        rect: Rect,
        rail_width: u16,
    ) !void {
        std.debug.assert(rail_width <= rect.width);
        std.debug.assert(rect.height > 0);
        if (rail_width == 0) return;
        const rail_height = if (props.chrome.rail_height == 0)
            rect.height
        else
            @min(@as(u16, props.chrome.rail_height), rect.height);
        try self.writer.print(
            "<span aria-hidden=\"true\" style=\"left:0px;top:0px" ++
                ";width:{d}px;height:{d}px;background:",
            .{
                rail_width * self.options.cell_width_px,
                rail_height * self.options.cell_height_px,
            },
        );
        try write_color(self.writer, props.style.border);
        try self.writer.writeAll("\"></span>");
    }

    fn write_chrome_text(
        self: *Renderer,
        text: []const u8,
        column: u16,
        color: Color,
        attributes: Attributes,
    ) !void {
        std.debug.assert(text.len > 0);
        std.debug.assert(text.len <= std.math.maxInt(u16));
        try self.writer.print(
            "<span style=\"left:{d}px;top:0px;color:",
            .{column * self.options.cell_width_px},
        );
        try write_color(self.writer, color);
        if (attributes.bold) try self.writer.writeAll(";font-weight:700");
        if (attributes.dim) try self.writer.writeAll(";opacity:0.65");
        try self.writer.writeAll("\">");
        try write_escaped(self.writer, text);
        try self.writer.writeAll("</span>");
    }

    /// A status line's key hints, laid out from the right exactly as the
    /// terminal widget places them.
    fn write_hints(self: *Renderer, node: *const DomNode) !void {
        std.debug.assert(node.kind == .status_line);
        const props = node.props.status_line;
        const width = node.rect().width;
        var column = width -| hints_width(props.hints, props.visual.hint_gap);
        for (props.hints) |hint| {
            std.debug.assert(hint.key.len <= width);
            if (column >= width) return;
            try self.write_hint_part(hint.key, column, props.style.selected_foreground);
            column +|= @intCast(hint.key.len + 1);
            if (column >= width) return;
            try self.write_hint_part(hint.label, column, props.style.muted);
            column +|= @intCast(hint.label.len);
            column +|= props.visual.hint_gap;
        }
    }

    fn write_hint_part(
        self: *Renderer,
        text: []const u8,
        column: u16,
        color: Color,
    ) !void {
        std.debug.assert(self.options.cell_width_px > 0);
        if (text.len == 0) return;
        std.debug.assert(text.len <= std.math.maxInt(u16));
        try self.writer.print(
            "<span style=\"left:{d}px;top:0px;color:",
            .{column * self.options.cell_width_px},
        );
        try write_color(self.writer, color);
        try self.writer.writeAll("\">");
        try write_escaped(self.writer, text);
        try self.writer.writeAll("</span>");
    }
};

const Origin = struct {
    x: u16 = 0,
    y: u16 = 0,
};

/// Columns a run of hints occupies, key plus separator plus label plus gap.
fn hints_width(hints: []const StatusHint, gap: u8) u16 {
    std.debug.assert(hints.len <= std.math.maxInt(u16));
    var width: u32 = 0;
    for (hints) |hint| {
        width += @intCast(hint.key.len + hint.label.len + 1 + gap);
    }
    std.debug.assert(width <= std.math.maxInt(u16));
    return @intCast(@min(width, std.math.maxInt(u16)));
}

const StatusHint = @import("../dom/types.zig").StatusHint;

const Frame = struct {
    tag: Element,
    origin: Origin = .{},
    child: ?DomTree.NodeIndex = null,
    void_element: bool = false,

    /// An element that takes neither children nor a closing tag.
    fn void_leaf(tag: Element) Frame {
        std.debug.assert(tag.is_void());
        return .{ .tag = tag, .child = null, .void_element = true };
    }
};

const semantic_id_bytes_max = @import("../dom/types.zig").semantic_id_bytes_max;

/// Children resolve against the box their parent paints them into, which for
/// a panel is inside its chrome.
fn content_origin(node: *const DomNode, rect: Rect) Origin {
    const inner = node.content_rect();
    std.debug.assert(inner.x >= rect.x);
    std.debug.assert(inner.y >= rect.y);
    return .{ .x = inner.x, .y = inner.y };
}

pub fn text_of(node: *const DomNode) []const u8 {
    return switch (node.kind) {
        .label => node.props.label.text,
        .heading => node.props.heading.text,
        .code_block => node.props.code_block.text,
        .badge => node.props.badge.text,
        .button => node.props.button.text,
        .list_item => node.props.list_item.title,
        .panel => node.props.panel.title,
        .status_line => node.props.status_line.message,
        .text_input => node.props.text_input.value,
        .container, .list, .segmented, .image, .rule => "",
    };
}

/// The HTML vocabulary this renderer emits.
///
/// An enum rather than the tag strings themselves: which element a node becomes
/// is decided for every node of every tree, and asking it as a string means a
/// run of `mem.eql` against two lists per node. As a value it is a switch, the
/// name is recovered once at the point of writing, and a tag that is not in the
/// vocabulary stops being expressible.
pub const Element = enum(u8) {
    div,
    span,
    a,
    p,
    em,
    strong,
    code,
    time,
    img,
    br,
    pre,
    hr,
    ul,
    li,
    article,
    section,
    nav,
    header,
    footer,
    aside,
    main,
    blockquote,
    button,
    h1,
    h2,
    h3,
    h4,
    h5,
    h6,

    pub fn name(self: Element) []const u8 {
        return @tagName(self);
    }

    /// An element the parser closes at the first flow content inside it.
    fn holds_phrasing_only(self: Element) bool {
        return switch (self) {
            .p, .a, .span, .em, .strong, .code, .time, .pre => true,
            .h1, .h2, .h3, .h4, .h5, .h6 => true,
            .div,
            .img,
            .br,
            .hr,
            .ul,
            .li,
            .article,
            .section,
            .nav,
            .header,
            .footer,
            .aside,
            .main,
            .blockquote,
            .button,
            => false,
        };
    }

    fn is_phrasing(self: Element) bool {
        return switch (self) {
            .span, .a, .em, .strong, .code, .time, .img, .br => true,
            else => false,
        };
    }

    /// An element that takes neither children nor a closing tag. Writing one
    /// for it is not merely redundant: the parser treats the stray end tag as
    /// an error and the document stops being the one that was rendered.
    fn is_void(self: Element) bool {
        return switch (self) {
            .img, .br, .hr => true,
            else => false,
        };
    }
};

fn element_for(node: *const DomNode) Element {
    // Meaning wins where a node states it; otherwise the widget decides.
    if (node.semantic.tag != .none) {
        return semantic_element(node.semantic.tag, node.semantic.level);
    }
    return widget_element(node.kind);
}

/// The element a node takes given what encloses it.
///
/// A `p`, an `a` and the headings may only hold phrasing content, and the
/// parser does not merely disapprove of a `div` inside one: it closes the
/// parent where the `div` starts and reparents everything that follows to an
/// ancestor. Since a child's position here is relative to its parent, those
/// children then resolve against the wrong origin -- every paragraph's text
/// lands at the top of the page, on top of every other paragraph's.
///
/// Inside such a parent, a node that would be flow content becomes a span.
/// Nothing is lost by it: the sheet positions every element absolutely, so the
/// two are laid out identically and only the parse differs.
fn element_in(parent: ?Element, node: *const DomNode) Element {
    const chosen = element_for(node);
    const enclosing = parent orelse return chosen;
    if (!enclosing.holds_phrasing_only()) return chosen;
    // An anchor inside an anchor is closed by the parser just as eagerly.
    if (enclosing == .a and chosen == .a) return .span;
    if (chosen.is_phrasing()) return chosen;
    return .span;
}

fn semantic_element(tag: Semantic, level: u8) Element {
    return switch (tag) {
        .article => .article,
        .section => .section,
        .nav => .nav,
        .header => .header,
        .footer => .footer,
        .aside => .aside,
        .main_content => .main,
        .heading => heading_element(level),
        .paragraph => .p,
        .link => .a,
        .list => .ul,
        .list_item => .li,
        .code => .pre,
        .quote => .blockquote,
        .emphasis => .em,
        .strong => .strong,
        .time => .time,
        .image => .img,
        .none => .div,
    };
}

fn widget_element(kind: NodeKind) Element {
    return switch (kind) {
        .heading => .h2,
        .rule => .hr,
        .code_block => .pre,
        .list => .ul,
        .list_item => .li,
        .panel => .section,
        .status_line => .footer,
        .badge => .span,
        .button => .button,
        .label, .container, .text_input, .segmented, .image => .div,
    };
}

fn heading_element(level: u8) Element {
    std.debug.assert(level <= 6);
    return switch (level) {
        0, 1 => .h1,
        2 => .h2,
        3 => .h3,
        4 => .h4,
        5 => .h5,
        else => .h6,
    };
}

pub fn write_color(writer: *std.Io.Writer, color: Color) !void {
    const rgba = color_to_rgba(color);
    if (rgba.a == 255) {
        try writer.print("#{x:0>2}{x:0>2}{x:0>2}", .{ rgba.r, rgba.g, rgba.b });
        return;
    }
    try writer.print("rgba({d},{d},{d},{d})", .{ rgba.r, rgba.g, rgba.b, rgba.a });
}

/// Writes text so the document shows exactly the characters the tree holds.
///
/// Every ampersand is escaped, including one that begins what looks like a
/// character reference. Letting `&nbsp;` through was treating the tree's text
/// as markup, and that breaks the one invariant the whole renderer rests on:
/// the layout measured six columns for those six bytes, and the browser drew
/// one. Six columns of space were reserved for a single character, and every
/// piece placed after it on the row sat where nothing was.
///
/// It diverged between backends as well. The engine in the page builds text
/// nodes, which never interpret a reference, so the same document showed a
/// space when generated and the literal `&nbsp;` when laid out live.
///
/// Text that is meant to contain a non-breaking space should contain one --
/// decoding a source format's escapes is the business of whatever parsed it,
/// where the decoded length is what gets measured.
pub fn write_escaped(writer: *std.Io.Writer, value: []const u8) !void {
    var start: u32 = 0;
    var index: u32 = 0;
    std.debug.assert(value.len <= std.math.maxInt(u32));
    while (index < value.len) : (index += 1) {
        const replacement = switch (value[index]) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => continue,
        };
        try writer.writeAll(value[start..index]);
        try writer.writeAll(replacement);
        start = index + 1;
    }
    std.debug.assert(start <= value.len);
    try writer.writeAll(value[start..]);
}

test "renders a container tree without recursion" {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var tree = DomTree.init();
    const LayoutElement = @import("../layout/tree.zig").LayoutElement;
    const root = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.stack(.column, 0),
        .semantic = .{ .tag = .article },
    });
    _ = try tree.append_child(root, .{
        .kind = .label,
        .props = .{ .label = .{ .text = "Title" } },
        .layout = LayoutElement.sized(1),
        .semantic = .{ .tag = .heading, .level = 2 },
    });
    try tree.evaluate(Rect.init(0, 0, 40, 10));

    var renderer = Renderer.init(&writer, .{});
    try renderer.render(&tree);
    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "<article") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<h2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "</article>") != null);
}

test "a widget without a semantic tag still picks its own element" {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const LayoutElement = @import("../layout/tree.zig").LayoutElement;
    var tree = DomTree.init();
    _ = try tree.set_root(.{
        .kind = .panel,
        .props = .{ .panel = .{ .title = "BROWSE" } },
        .layout = LayoutElement.stack(.column, 0),
    });
    try tree.evaluate(Rect.init(0, 0, 30, 8));

    var renderer = Renderer.init(&writer, .{});
    try renderer.render(&tree);
    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "<section") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "BROWSE") != null);
}

test "colours come from the widget's own style" {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const LayoutElement = @import("../layout/tree.zig").LayoutElement;
    var style = Style.monochrome(Color.from_rgb(0x4e, 0xd3, 0xae), Color.from_rgb(0, 0, 0));
    style.background = Color.from_rgb(0x16, 0x19, 0x1d);
    var tree = DomTree.init();
    _ = try tree.set_root(.{
        .kind = .list,
        .props = .{ .list = .{ .style = style, .item_count = 0 } },
        .layout = LayoutElement.leaf(),
    });
    try tree.evaluate(Rect.init(0, 0, 20, 4));

    var renderer = Renderer.init(&writer, .{});
    try renderer.render(&tree);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "#16191d") != null);
}

test "an image is a void element" {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const LayoutElement = @import("../layout/tree.zig").LayoutElement;
    var tree = DomTree.init();
    _ = try tree.set_root(.{
        .kind = .label,
        .props = .{ .label = .{ .text = "a pigeon" } },
        .layout = LayoutElement.sized(8),
        .semantic = .{ .tag = .image, .href = "/i.jpg" },
    });
    try tree.evaluate(Rect.init(0, 0, 20, 8));

    var renderer = Renderer.init(&writer, .{});
    try renderer.render(&tree);
    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "<img src=\"/i.jpg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "alt=\"a pigeon\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "</img>") == null);
}

test "nested boxes are placed relative to their parent" {
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const LayoutElement = @import("../layout/tree.zig").LayoutElement;
    var tree = DomTree.init();
    const root = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.stack(.column, 0),
    });
    const inner = try tree.append_child(root, .{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.stack(.column, 0),
    });
    _ = try tree.append_child(root, .{
        .kind = .label,
        .props = .{ .label = .{ .text = "second" } },
        .layout = LayoutElement.sized(1),
    });
    _ = try tree.append_child(inner, .{
        .kind = .label,
        .props = .{ .label = .{ .text = "first" } },
        .layout = LayoutElement.sized(1),
    });
    try tree.evaluate(Rect.init(0, 0, 40, 10));

    var renderer = Renderer.init(&writer, .{});
    try renderer.render(&tree);
    // The first child of a container at the origin sits at zero, not at the
    // container's absolute position.
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "top:0px") != null);
}

test "a paragraph's parts are phrasing, so the parser keeps them inside it" {
    // A div inside a p is closed by the parser at the div, and everything after
    // it is reparented. Positions here are relative to the parent, so that puts
    // every paragraph's text at the top of the page, stacked on itself.
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const LayoutElement = @import("../layout/tree.zig").LayoutElement;
    var tree = DomTree.init();
    const root = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.content_stack(.column, 0),
    });
    const paragraph = try tree.append_child(root, .{
        .kind = .label,
        .props = .{ .label = .{ .text = "flowed", .wrap = true } },
        .layout = LayoutElement.content_free(),
        .semantic = .{ .tag = .paragraph },
    });
    // A link broken across two rows: one anchor, a fragment per row.
    const link = try tree.append_child(paragraph, .{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.placed_free(0, 0, 6, 2),
        .semantic = .{ .tag = .link, .href = "https://example.com/a" },
    });
    for ([_]u16{ 0, 1 }) |row| {
        _ = try tree.append_child(link, .{
            .kind = .label,
            .props = .{ .label = .{ .text = "part" } },
            .layout = LayoutElement.placed(0, row, 4, 1),
            .semantic = .{ .tag = .link, .href = "https://example.com/a" },
        });
    }
    try tree.layout(Rect.init(0, 0, 40, 10));

    var renderer = Renderer.init(&writer, .{});
    try renderer.render(&tree);
    const output = writer.buffered();

    const start = std.mem.indexOf(u8, output, "<p ") orelse return error.MissingParagraph;
    const end = std.mem.indexOfPos(u8, output, start, "</p>") orelse return error.Unclosed;
    const inside = output[start..end];
    try std.testing.expect(std.mem.indexOf(u8, inside, "<div") == null);
    // The link survives as one anchor, and its rows do not become more of them.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, inside, "<a "));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, inside, "<span"));
}

test "a heading's parts are phrasing too" {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const LayoutElement = @import("../layout/tree.zig").LayoutElement;
    var tree = DomTree.init();
    const root = try tree.set_root(.{
        .kind = .heading,
        .props = .{ .heading = .{ .text = "Title", .level = 2 } },
        .layout = LayoutElement.content_free(),
        .semantic = .{ .tag = .heading, .level = 2 },
    });
    _ = try tree.append_child(root, .{
        .kind = .label,
        .props = .{ .label = .{ .text = "Title" } },
        .layout = LayoutElement.placed(0, 0, 5, 1),
    });
    try tree.layout(Rect.init(0, 0, 40, 4));
    var renderer = Renderer.init(&writer, .{});
    try renderer.render(&tree);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "<div") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "<span") != null);
}

test "a named node can be linked to, and the link says where it points" {
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const LayoutElement = @import("../layout/tree.zig").LayoutElement;
    var tree = DomTree.init();
    const root = try tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.stack(.column, 0),
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

    var renderer = Renderer.init(&writer, .{});
    try renderer.render(&tree);
    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "<h2 id=\"pigeons\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "href=\"#pigeons\"") != null);
    // A node with no name gets no id at all, rather than an empty one.
    try std.testing.expect(std.mem.indexOf(u8, output, "id=\"\"") == null);
}

test "the selected row is announced, and an interactable node is reachable" {
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const LayoutElement = @import("../layout/tree.zig").LayoutElement;
    var tree = DomTree.init();
    const list = try tree.set_root(.{
        .kind = .list,
        .props = .{ .list = .{ .item_count = 2 } },
        .layout = LayoutElement.sized(2),
        .semantic = .{ .tag = .list },
    });
    _ = try tree.append_child(list, .{
        .kind = .list_item,
        .props = .{ .list_item = .{ .title = "one" } },
        .layout = LayoutElement.sized(1),
        .semantic = .{ .tag = .list_item },
    });
    _ = try tree.append_child(list, .{
        .kind = .list_item,
        .props = .{ .list_item = .{ .title = "two" } },
        .layout = LayoutElement.sized(1),
        .semantic = .{ .tag = .list_item },
        .interactable = true,
    });
    try std.testing.expect(tree.select_row(list, 1));
    try tree.evaluate(Rect.init(0, 0, 20, 2));

    var renderer = Renderer.init(&writer, .{});
    try renderer.render(&tree);
    const output = writer.buffered();
    try std.testing.expectEqual(@as(u16, 1), count_of(output, "aria-current=\"true\""));
    try std.testing.expectEqual(@as(u16, 1), count_of(output, "tabindex=\"0\""));
}

test "an anchor is already reachable, so it is not given a tab stop as well" {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const LayoutElement = @import("../layout/tree.zig").LayoutElement;
    var tree = DomTree.init();
    _ = try tree.set_root(.{
        .kind = .label,
        .props = .{ .label = .{ .text = "Contents" } },
        .layout = LayoutElement.sized(1),
        .semantic = .{ .tag = .link, .href = "#a" },
        .interactable = true,
    });
    try tree.evaluate(Rect.init(0, 0, 20, 1));
    var renderer = Renderer.init(&writer, .{});
    try renderer.render(&tree);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "tabindex") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "href=\"#a\"") != null);
}

test "a panel that holds something still says what it is" {
    // A panel's title is chrome, not content, so a node with children never
    // printed it: every panel that contained anything -- which is every panel
    // worth having -- rendered without its own name, while the terminal drew
    // it the whole time.
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const LayoutElement = @import("../layout/tree.zig").LayoutElement;
    var tree = DomTree.init();
    const panel = try tree.set_root(.{
        .kind = .panel,
        .props = .{ .panel = .{
            .title = "A Post Title",
            .meta = "2026-03-01",
            .chrome = .{ .rail_width = 1, .content_padding_left = 2 },
        } },
        .layout = LayoutElement.stack(.column, 0),
        .semantic = .{ .tag = .article },
    });
    _ = try tree.append_child(panel, .{
        .kind = .label,
        .props = .{ .label = .{ .text = "body text" } },
        .layout = LayoutElement.sized(1),
        .semantic = .{ .tag = .paragraph },
    });
    try tree.evaluate(Rect.init(0, 0, 40, 6));

    var renderer = Renderer.init(&writer, .{});
    try renderer.render(&tree);
    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "A Post Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "2026-03-01") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "body text") != null);
    // The title starts where the terminal starts it: past the rail and the
    // padding, which is three cells in at this chrome.
    try std.testing.expect(std.mem.indexOf(u8, output, "left:27px;top:0px") != null);
    // The rail is drawn, and is not announced -- it is a bar, not a word.
    try std.testing.expect(std.mem.indexOf(u8, output, "aria-hidden=\"true\"") != null);
}

test "a rule is a void element, closing tag and all" {
    // An hr takes no closing tag, and writing one is not cosmetic: the parser
    // reads the stray end tag as an error and the document stops being the one
    // that was rendered.
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const LayoutElement = @import("../layout/tree.zig").LayoutElement;
    var tree = DomTree.init();
    _ = try tree.set_root(.{
        .kind = .rule,
        .props = .{ .rule = .{} },
        .layout = LayoutElement.sized(1),
    });
    try tree.evaluate(Rect.init(0, 0, 20, 1));
    var renderer = Renderer.init(&writer, .{});
    try renderer.render(&tree);
    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "<hr") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "</hr>") == null);
}

test "every ampersand is escaped, including one that looks like markup" {
    // What the tree holds is what the document shows, character for
    // character. Passing `&nbsp;` through made the browser draw one column
    // where the layout had measured and reserved six, so everything placed
    // after it on that row sat five columns from where it belonged -- and the
    // engine in the page, which builds text nodes, drew all six regardless.
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try write_escaped(&writer, "a&nbsp;b & c <d>");
    try std.testing.expectEqualStrings(
        "a&amp;nbsp;b &amp; c &lt;d&gt;",
        writer.buffered(),
    );
}

test "escaped text draws the columns the layout measured for it" {
    // The invariant behind the rule above, stated as a count: a run of text is
    // as many columns wide on screen as the measure gave it, whatever the
    // bytes happen to spell.
    const text_measure = @import("../layout/text_measure.zig");
    const source = "a&nbsp;b";
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try write_escaped(&writer, source);
    // Eight characters in, eight characters out: the escaping lengthens the
    // markup, never the text the reader sees.
    try std.testing.expectEqual(@as(u16, 1), text_measure.literal_rows(source));
    try std.testing.expectEqual(@as(usize, 8), source.len);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "&amp;nbsp;") != null);
}

test "colours render as hex or rgba" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try write_color(&writer, Color.from_rgb(0x4e, 0xd3, 0xae));
    try std.testing.expectEqualStrings("#4ed3ae", writer.buffered());
}

fn count_of(haystack: []const u8, needle: []const u8) u16 {
    std.debug.assert(needle.len > 0);
    var total: u16 = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, needle)) |found| {
        total += 1;
        at = found + needle.len;
    }
    return total;
}

test "an empty tree renders nothing" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var tree = DomTree.init();
    var renderer = Renderer.init(&writer, .{});
    try renderer.render(&tree);
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
}
