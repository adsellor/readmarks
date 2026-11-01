const std = @import("std");
const theme = @import("../theme.zig");
const tokens = @import("tokens.zig");
const node = @import("node.zig");
const pane = @import("pane.zig");
const field = @import("field.zig");

const Tree = node.Tree;
const Index = node.Index;
const Color = node.Color;
const Style = node.Style;

pub const Kind = enum { breadcrumb, search, scope };

pub const Segment = struct {
    label: []const u8,
};

pub const Breadcrumb = struct {
    scope: []const u8,
    tabs: []const Segment,
    selected: u16,
    accent: Color,
};

pub const Search = struct {
    prompt: []const u8,
    placeholder: []const u8,
    value: []const u8,
    cursor: u16,
};

pub const Scope = struct {
    badge: []const u8,
    name: []const u8,
    detail: []const u8,
    accent: Color,
};

pub const Body = union(Kind) {
    breadcrumb: Breadcrumb,
    search: Search,
    scope: Scope,
};

pub const Config = struct {
    title: []const u8,
    meta: []const u8,
    body: Body,
};

pub fn build(tree: *Tree, parent: Index, config: Config, width: i32) !void {
    std.debug.assert(width >= 0);
    std.debug.assert(parent != node.none);
    const palette = theme.palette;
    const frame = try pane.panel(tree, parent, .{
        .chrome = tokens.header_chrome,
        .title = config.title,
        .meta = config.meta,
        .rail = palette.line,
        .title_color = palette.muted,
        .ground = palette.panel,
        .height = node.fixed(2),
    });
    switch (config.body) {
        .search => |search| _ = try field.field(tree, frame.body, .{
            .prompt = search.prompt,
            .placeholder = search.placeholder,
            .value = search.value,
            .cursor = search.cursor,
            .look = field.focused_look(),
        }, width),
        .scope => |scope| {
            const strip = try node.line(tree, frame.body, .{});
            const chip = theme.chip(palette.inverse_foreground, scope.accent);
            try node.run(tree, strip, scope.badge, chip);
            try node.run(tree, strip, "  ", .{});
            try node.run(tree, strip, scope.name, theme.ink(palette.foreground_strong));
            try node.run(tree, strip, "  ", .{});
            try node.run(tree, strip, scope.detail, theme.ink(palette.muted));
        },
        .breadcrumb => |crumb| {
            const strip = try node.line(tree, frame.body, .{});
            const chip = theme.chip(palette.foreground_strong, palette.panel_alt);
            try badge(tree, strip, crumb.scope, chip);
            try node.run(tree, strip, "  ", .{});
            try segments(tree, strip, crumb.tabs, crumb.selected, .{
                .foreground = crumb.accent,
                .background = palette.background,
                .bold = true,
            }, .{ .foreground = palette.muted, .background = palette.panel, .dim = true });
        },
    }
}

pub fn badge(tree: *Tree, strip: Index, text: []const u8, style: Style) !void {
    try node.run(tree, strip, " ", style);
    try node.run(tree, strip, text, style);
    try node.run(tree, strip, " ", style);
}

pub fn segments(
    tree: *Tree,
    strip: Index,
    items: []const Segment,
    selected: u16,
    active: Style,
    idle: Style,
) !void {
    std.debug.assert(items.len <= std.math.maxInt(u16));
    std.debug.assert(strip != node.none);
    for (items, 0..) |segment, index| {
        if (index > 0) try node.run(tree, strip, " ", .{});
        try badge(tree, strip, segment.label, if (index == selected) active else idle);
    }
}

const testing = std.testing;

test "a breadcrumb names the scope before the tabs" {
    var nodes: [64]node.Node = undefined;
    var tree = Tree.init(&nodes);
    const root = try node.box(&tree, node.none, .{});
    const tabs = [_]Segment{ .{ .label = "Feeds" }, .{ .label = "Articles" } };
    try build(&tree, root, .{
        .title = "READER",
        .meta = "2 UNREAD",
        .body = .{ .breadcrumb = .{
            .scope = "All articles",
            .tabs = &tabs,
            .selected = 1,
            .accent = theme.palette.accent_warm,
        } },
    }, 80);
    node.resolve(&tree, 80, 2);
    var found_scope = false;
    var found_tab = false;
    for (tree.nodes[0..tree.len]) |entry| {
        if (std.mem.eql(u8, entry.text, "All articles")) found_scope = true;
        if (std.mem.eql(u8, entry.text, "Articles") and entry.style.bold) found_tab = true;
    }
    try testing.expect(found_scope);
    try testing.expect(found_tab);
}
