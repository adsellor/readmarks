const std = @import("std");
const tree_mod = @import("../layout/tree.zig");
const style_mod = @import("../layout/style.zig");
const dom = @import("../layout/element.zig");
const Units = @import("../layout/units.zig").Units;

const Tree = tree_mod.Tree;
const Index = tree_mod.Index;
const none = tree_mod.none;
const Style = style_mod.Style;
const rect_zero = @import("../layout/rect.zig").Rect{};

pub const styles_max: usize = 32;

pub const inline_class = "x";

pub const StyleTable = struct {
    entries: [styles_max]Style = undefined,
    len: usize = 0,
    overflowed: bool = false,

    pub fn collect(tree: *const Tree) StyleTable {
        var table = StyleTable{};
        var index: Index = 0;
        while (index < tree.len) : (index += 1) {
            const style = tree.at(index).style;
            if (style.is_empty()) continue;
            _ = table.intern(style);
        }
        return table;
    }

    fn intern(self: *StyleTable, style: Style) ?usize {
        for (self.entries[0..self.len], 0..) |entry, at| {
            if (entry.eql(style)) return at;
        }
        if (self.len == styles_max) {
            self.overflowed = true;
            return null;
        }
        self.entries[self.len] = style;
        self.len += 1;
        return self.len - 1;
    }

    pub fn index_of(self: *const StyleTable, style: Style) ?usize {
        for (self.entries[0..self.len], 0..) |entry, at| {
            if (entry.eql(style)) return at;
        }
        return null;
    }

    pub fn slice(self: *const StyleTable) []const Style {
        return self.entries[0..self.len];
    }
};

pub const Horizontal = enum {
    pixels,
    characters,
};

pub const Options = struct {
    units: Units = .{ .width = 9, .height = 19 },
    horizontal: Horizontal = .pixels,
    surface_class: []const u8 = "p",
    transform: bool = false,

    pub fn horizontal_unit(self: Options) []const u8 {
        return switch (self.horizontal) {
            .pixels => "px",
            .characters => "ch",
        };
    }

    pub fn scale_horizontal(self: Options, units: i32) i32 {
        return switch (self.horizontal) {
            .pixels => self.units.x(units),
            .characters => units,
        };
    }
};

pub fn write_reset(writer: *std.Io.Writer, options: Options) !void {
    std.debug.assert(options.surface_class.len > 0);
    std.debug.assert(options.units.width > 0);
    const class = options.surface_class;
    try writer.print(".{s}{{position:relative}}", .{class});
    try writer.print(
        ".{s} *{{position:absolute;box-sizing:border-box;margin:0;font:inherit;" ++
            "color:inherit;white-space:pre-wrap;overflow-wrap:break-word}}",
        .{class},
    );
    try writer.print(
        ".{s} .{s}{{position:static;white-space:inherit}}",
        .{ class, inline_class },
    );
    try writer.print(".{s} :is(b,strong){{font-weight:700}}", .{class});
    try writer.print(".{s} :is(i,em){{font-style:italic}}", .{class});
    try writer.print(".{s} pre{{white-space:pre;overflow-x:auto}}", .{class});
    try writer.print(".{s} ul{{list-style:none;padding:0}}", .{class});
    try writer.print(
        ".{s} img{{object-fit:contain;object-position:left top;max-width:100%}}",
        .{class},
    );
    try writer.print(".{s} canvas{{max-width:100%}}", .{class});
}

pub fn write_flow(writer: *std.Io.Writer, options: Options) !void {
    std.debug.assert(options.surface_class.len > 0);
    std.debug.assert(options.units.width > 0);
    try writer.print(
        ".{s} *:not(.{s}){{position:static;display:block;" ++
            "width:auto!important;height:auto!important}}",
        .{ options.surface_class, inline_class },
    );
}

pub fn write_styles(
    writer: *std.Io.Writer,
    table: *const StyleTable,
    options: Options,
) !void {
    for (table.slice(), 0..) |style, at| {
        try writer.print(".{s} .s{d}{{", .{ options.surface_class, at });
        try write_declarations(writer, style);
        try writer.writeAll("}");
    }
}

fn shows(color: style_mod.Color) bool {
    return color.is_set() and color.kind != .default;
}

fn write_declarations(writer: *std.Io.Writer, style: Style) !void {
    std.debug.assert(!style.is_empty());
    var written = false;
    std.debug.assert(!written);
    if (shows(style.foreground)) {
        try writer.print("color:#{x:0>6}", .{style.foreground.value()});
        written = true;
    }
    if (shows(style.background)) {
        if (written) try writer.writeAll(";");
        try writer.print("background:#{x:0>6}", .{style.background.value()});
        written = true;
    }
    if (style.bold) {
        if (written) try writer.writeAll(";");
        try writer.writeAll("font-weight:700");
        written = true;
    }
    if (style.italic) {
        if (written) try writer.writeAll(";");
        try writer.writeAll("font-style:italic");
        written = true;
    }
    if (style.dim) {
        if (written) try writer.writeAll(";");
        try writer.writeAll("opacity:.65");
        written = true;
    }
    if (style.underline or style.strikethrough) {
        if (written) try writer.writeAll(";");
        try writer.writeAll("text-decoration:");
        if (style.underline) try writer.writeAll("underline");
        if (style.underline and style.strikethrough) try writer.writeAll(" ");
        if (style.strikethrough) try writer.writeAll("line-through");
    }
}

pub fn write(
    writer: *std.Io.Writer,
    tree: *const Tree,
    table: *const StyleTable,
    options: Options,
) !void {
    if (tree.len == 0) return;
    try write_node(writer, tree, table, 0, options);
}

fn write_node(
    writer: *std.Io.Writer,
    tree: *const Tree,
    table: *const StyleTable,
    index: Index,
    options: Options,
) !void {
    std.debug.assert(index < tree.len);
    std.debug.assert(table.len <= styles_max);
    const node = tree.at(index);
    if (node.element == .text_run) {
        try write_escaped(writer, node.text);
        return;
    }
    const tag = node.element.tag_for(node.level);

    try writer.print("<{s}", .{tag});
    if (node.id.len > 0) try writer.print(" id=\"{s}\"", .{node.id});
    if (node.href.len > 0) {
        const attribute = if (node.element == .image) "src" else "href";
        try writer.print(" {s}=\"", .{attribute});
        try write_escaped_attribute(writer, node.href);
        try writer.writeAll("\"");
        if (node.external and node.element != .image) {
            try writer.writeAll(" target=_blank rel=noopener");
        }
    }
    if (node.element == .image) {
        try writer.writeAll(" alt=\"");
        try write_escaped_attribute(writer, node.text);
        try writer.writeAll("\" loading=\"lazy\"");
    }
    if (node.element == .canvas) {
        try writer.print(" width=\"{d}\" height=\"{d}\"", .{
            options.scale_horizontal(node.rect.width),
            options.units.y(node.rect.height),
        });
    }

    const style_index = if (node.style.is_empty()) null else table.index_of(node.style);
    try write_class(writer, node.is_inline(), style_index);

    if (!node.is_inline()) {
        try write_box(writer, tree, index, options);
        if (!node.style.is_empty() and style_index == null) {
            try writer.writeAll(";");
            try write_declarations(writer, node.style);
        }
        try writer.writeAll("\"");
    }
    try writer.writeAll(">");

    if (node.element.is_void()) return;

    if (node.element != .image and node.text.len > 0) {
        try write_escaped(writer, node.text);
    }

    var child = node.first_child;
    while (child != none) {
        try write_node(writer, tree, table, child, options);
        child = tree.at(child).next_sibling;
    }
    try writer.print("</{s}>", .{tag});
}

fn write_class(writer: *std.Io.Writer, flows: bool, style_index: ?usize) !void {
    std.debug.assert(style_index == null or style_index.? < styles_max);
    if (!flows and style_index == null) return;
    try writer.writeAll(" class=\"");
    if (flows) try writer.writeAll(inline_class);
    if (style_index) |at| {
        if (flows) try writer.writeAll(" ");
        try writer.print("s{d}", .{at});
    }
    try writer.writeAll("\"");
}

fn write_box(
    writer: *std.Io.Writer,
    tree: *const Tree,
    index: Index,
    options: Options,
) !void {
    std.debug.assert(index < tree.len);
    std.debug.assert(options.units.height > 0);
    const node = tree.at(index);
    const origin = if (node.parent == none)
        rect_zero
    else
        tree.at(node.parent).rect;

    const columns = node.rect.x - origin.x;
    const y = options.units.y(node.rect.y - origin.y);
    const height = options.units.y(node.rect.height);
    const unit = options.horizontal_unit();
    const x = options.scale_horizontal(columns);
    const width = options.scale_horizontal(node.rect.width);

    try writer.writeAll(" style=\"");
    if (options.transform) {
        try writer.print("transform:translate({d}{s},{d}px);", .{ x, unit, y });
    } else {
        try writer.print("left:{d}{s};top:{d}px;", .{ x, unit, y });
    }
    try writer.print("width:{d}{s};height:{d}px", .{ width, unit, height });

    const pad = node.layout.padding;
    if (pad.left != 0 or pad.right != 0 or pad.top != 0 or pad.bottom != 0) {
        try writer.print(";padding:{d}px {d}{s} {d}px {d}{s}", .{
            options.units.y(pad.top),
            options.scale_horizontal(pad.right),
            unit,
            options.units.y(pad.bottom),
            options.scale_horizontal(pad.left),
            unit,
        });
    }
}

pub const SemanticOptions = struct {
    base: []const u8 = "",
};

pub fn write_semantic(
    writer: *std.Io.Writer,
    tree: *const Tree,
    from: Index,
    options: SemanticOptions,
) !void {
    std.debug.assert(tree.len > 0);
    std.debug.assert(from < tree.len);
    const node = tree.at(from);

    if (node.element == .text_run) {
        try write_escaped(writer, node.text);
        return;
    }
    const tag = node.element.tag_for(node.level);
    try writer.print("<{s}", .{tag});
    if (node.id.len > 0) try writer.print(" id=\"{s}\"", .{node.id});
    if (node.href.len > 0) {
        const attribute = if (node.element == .image) "src" else "href";
        try writer.print(" {s}=\"", .{attribute});
        if (options.base.len > 0 and node.href[0] == '/' and
            !std.mem.startsWith(u8, node.href, "//"))
        {
            try write_escaped_attribute(writer, options.base);
        }
        try write_escaped_attribute(writer, node.href);
        try writer.writeAll("\"");
    }
    if (node.element == .image) {
        try writer.writeAll(" alt=\"");
        try write_escaped_attribute(writer, node.text);
        try writer.writeAll("\"");
    }
    try writer.writeAll(">");

    if (node.element.is_void()) return;
    if (node.element != .image and node.text.len > 0) {
        try write_escaped(writer, node.text);
    }
    var child = node.first_child;
    while (child != none) {
        try write_semantic(writer, tree, child, options);
        child = tree.at(child).next_sibling;
    }
    try writer.print("</{s}>", .{tag});
}

fn write_escaped(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        else => try writer.writeByte(byte),
    };
}

fn write_escaped_attribute(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        else => try writer.writeByte(byte),
    };
}
