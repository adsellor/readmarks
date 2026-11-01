const std = @import("std");
const box = @import("box.zig");
const dom = @import("element.zig");
const tree_mod = @import("tree.zig");
const style_mod = @import("style.zig");

pub const Style = style_mod.Style;
pub const Element = dom.Element;

pub fn Node(comptime Children: type) type {
    return struct {
        pub const markix_node = true;
        pub const ChildList = Children;

        node: tree_mod.Node,
        children: Children,
        hidden: bool = false,
    };
}

pub const Options = struct {
    style: Style = .{},
    width: box.Sizing = .{ .fit = .{} },
    height: box.Sizing = .{ .fit = .{} },
    padding: box.Edges = .{},
    gap: i32 = 0,
    alignment: box.Alignment = .{},
    element: ?Element = null,
    display: ?dom.Display = null,
    href: []const u8 = "",
    external: bool = false,
    id: []const u8 = "",
    level: u8 = 0,
    wrap: bool = true,
    line_units: u8 = 1,
    clip: bool = false,
    hidden: bool = false,
};

fn resolve_display(element: Element) dom.Display {
    return if (element.is_inline()) .inline_ else .block;
}

fn make(
    element: Element,
    direction: box.Direction,
    content: []const u8,
    options: Options,
    children: anytype,
) Node(@TypeOf(children)) {
    std.debug.assert(options.level <= 6);
    std.debug.assert(options.gap >= 0);
    std.debug.assert(options.line_units >= 1);
    return .{
        .node = .{
            .layout = .{
                .width = options.width,
                .height = options.height,
                .padding = options.padding,
                .gap = options.gap,
                .direction = direction,
                .alignment = options.alignment,
            },
            .style = options.style,
            .element = options.element orelse element,
            .display = options.display orelse resolve_display(options.element orelse element),
            .text = content,
            .href = options.href,
            .external = options.external,
            .id = options.id,
            .level = options.level,
            .wrap = options.wrap,
            .line_units = options.line_units,
            .clip = options.clip,
        },
        .children = children,
        .hidden = options.hidden,
    };
}

pub fn column(options: Options, children: anytype) Node(@TypeOf(children)) {
    return make(.box, .column, "", options, children);
}

pub fn row(options: Options, children: anytype) Node(@TypeOf(children)) {
    return make(.box, .row, "", options, children);
}

pub fn text(value: []const u8, options: Options) Node(@TypeOf(.{})) {
    return make(.label, .row, value, options, .{});
}

pub fn run(value: []const u8, options: Options) Node(@TypeOf(.{})) {
    return make(.text_run, .row, value, options, .{});
}

pub fn paragraph(value: []const u8, options: Options) Node(@TypeOf(.{})) {
    return make(.paragraph, .row, value, options, .{});
}

pub fn rich(options: Options, children: anytype) Node(@TypeOf(children)) {
    return make(.paragraph, .row, "", options, children);
}

pub fn heading(level: u8, value: []const u8, options: Options) Node(@TypeOf(.{})) {
    var settings = options;
    settings.level = level;
    return make(.heading, .row, value, settings, .{});
}

pub fn link(value: []const u8, href: []const u8, options: Options) Node(@TypeOf(.{})) {
    var settings = options;
    settings.href = href;
    return make(.link, .row, value, settings, .{});
}

pub fn strong(value: []const u8, options: Options) Node(@TypeOf(.{})) {
    return make(.strong, .row, value, options, .{});
}

pub fn emphasis(value: []const u8, options: Options) Node(@TypeOf(.{})) {
    return make(.emphasis, .row, value, options, .{});
}

pub fn code_span(value: []const u8, options: Options) Node(@TypeOf(.{})) {
    return make(.code_span, .row, value, options, .{});
}

pub fn code_block(value: []const u8, options: Options) Node(@TypeOf(.{})) {
    var settings = options;
    settings.wrap = false;
    return make(.code_block, .column, value, settings, .{});
}

pub fn image(href: []const u8, alt: []const u8, options: Options) Node(@TypeOf(.{})) {
    var settings = options;
    settings.href = href;
    return make(.image, .row, alt, settings, .{});
}

pub fn rule(options: Options) Node(@TypeOf(.{})) {
    return make(.rule, .row, "", options, .{});
}

pub fn list(options: Options, children: anytype) Node(@TypeOf(children)) {
    return make(.list, .column, "", options, children);
}

pub fn item(options: Options, children: anytype) Node(@TypeOf(children)) {
    return make(.list_item, .column, "", options, children);
}

pub fn spacer(options: Options) Node(@TypeOf(.{})) {
    var settings = options;
    settings.width = .{ .grow = .{} };
    settings.height = .{ .grow = .{} };
    return make(.box, .row, "", settings, .{});
}

pub fn mount(tree: *tree_mod.Tree, description: anytype) !void {
    _ = try attach(tree, tree_mod.none, description);
}

pub fn mount_under(
    tree: *tree_mod.Tree,
    parent: tree_mod.Index,
    description: anytype,
) !tree_mod.Index {
    return attach(tree, parent, description);
}

fn attach(
    tree: *tree_mod.Tree,
    parent: tree_mod.Index,
    description: anytype,
) !tree_mod.Index {
    const Description = @TypeOf(description);
    comptime {
        if (!@hasDecl(Description, "markix_node")) {
            @compileError(
                "markix: expected a node from the dsl, found " ++
                    @typeName(Description) ++
                    ". Children must be built with the dsl's own helpers.",
            );
        }
    }
    std.debug.assert(parent == tree_mod.none or parent < tree.len);
    if (description.hidden) return tree_mod.none;

    const index = try tree.append(parent, description.node);
    std.debug.assert(index < tree.len);
    inline for (comptime std.meta.fieldNames(Description.ChildList)) |name| {
        _ = try attach(tree, index, @field(description.children, name));
    }
    return index;
}
