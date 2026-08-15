//! The two-row header: the application's name and counts, and beneath them the
//! controls of whatever mode is running.

const std = @import("std");
const markix = @import("markix");
const dom = markix.dom;
const layout = markix.layout;
const widgets = markix.widgets;
const theme = @import("../theme.zig");
const tokens = @import("tokens.zig");

const NodeIndex = dom.DomTree.NodeIndex;
const LayoutElement = layout.LayoutElement;

/// What the second row holds.
pub const Kind = enum { breadcrumb, search, scope };

pub const Slot = struct {
    kind: Kind = .breadcrumb,
    panel: NodeIndex = 0,
    input: NodeIndex = 0,
    badge: NodeIndex = 0,
    tabs: NodeIndex = 0,
    scope: NodeIndex = 0,
    count: NodeIndex = 0,
};

/// A row of tabs naming the panes, with the focused one lit in its own accent.
pub const Breadcrumb = struct {
    scope: []const u8,
    tabs: []const widgets.SegmentItem,
    selected: u16,
    accent: markix.Color,
};

pub const Search = struct {
    prompt: []const u8,
    placeholder: []const u8,
    value: []const u8,
    cursor: u16,
};

/// A badge, the scope it names, and a count beside it. Zen mode's header.
pub const Scope = struct {
    badge: []const u8,
    name: []const u8,
    detail: []const u8,
    accent: markix.Color,
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

/// Mounting depends on the kind and on how wide the scope name is, because the
/// nodes are placed around it. Both belong to the shape, so a longer name is a
/// different layout rather than different text.
pub fn mount(
    tree: *dom.DomTree,
    parent: NodeIndex,
    kind: Kind,
    width: u16,
    scope_length: u16,
    badge_length: u16,
) !Slot {
    var slot = Slot{ .kind = kind };
    slot.panel = try tree.append_child(parent, .{
        .kind = .panel,
        .props = .{ .panel = .{
            .chrome = tokens.header_chrome,
            .style = theme.panel_style,
        } },
        .layout = LayoutElement.free(),
    });
    const row = try tree.append_child(slot.panel, .{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.placed_free(0, 0, width, 1),
    });
    switch (kind) {
        .search => slot.input = try tree.append_child(row, .{
            .kind = .text_input,
            .props = .{ .text_input = .{} },
            .layout = LayoutElement.placed(0, 0, width, 1),
        }),
        .scope => {
            const scope_x = badge_length + 2;
            const count_x = scope_x + scope_length + 2;
            slot.badge = try place_badge(tree, row, 0, badge_length);
            slot.scope = try place_label(tree, row, scope_x, scope_length);
            slot.count = try place_label(tree, row, count_x, width -| count_x);
        },
        .breadcrumb => {
            const badge_width = scope_length + 2;
            slot.badge = try place_badge(tree, row, 0, badge_width);
            slot.tabs = try tree.append_child(row, .{
                .kind = .segmented,
                .props = .{ .segmented = .{} },
                .layout = LayoutElement.placed(
                    badge_width + 2,
                    0,
                    width -| (badge_width + 2),
                    1,
                ),
            });
        },
    }
    return slot;
}

pub fn update(tree: *dom.DomTree, slot: *const Slot, config: Config) void {
    tree.set_props(slot.panel, .{ .panel = .{
        .style = theme.panel_style,
        .chrome = tokens.header_chrome,
        .title = config.title,
        .meta = config.meta,
    } });
    switch (config.body) {
        .search => |search| {
            tree.set_focused(slot.input, true);
            tree.set_props(slot.input, .{ .text_input = .{
                .style = theme.focused_field,
                .prompt = search.prompt,
                .placeholder = search.placeholder,
                .value = search.value,
                .cursor = search.cursor,
            } });
        },
        .scope => |scope| {
            tree.set_props(slot.badge, .{ .badge = .{
                .text = scope.badge,
                .style = .{
                    .foreground = theme.inverse_foreground,
                    .background = scope.accent,
                    .attributes = .{ .bold = true },
                    .padding = 0,
                },
            } });
            tree.set_props(slot.scope, .{ .label = .{
                .text = scope.name,
                .style = strong_style(),
            } });
            tree.set_props(slot.count, .{ .label = .{
                .text = scope.detail,
                .style = theme.panel_style,
                .muted = true,
            } });
        },
        .breadcrumb => |breadcrumb| {
            tree.set_props(slot.badge, .{ .badge = .{
                .text = breadcrumb.scope,
                .style = .{
                    .foreground = theme.foreground_strong,
                    .background = theme.panel_alt,
                    .attributes = .{ .bold = true },
                },
            } });
            tree.set_props(slot.tabs, .{ .segmented = .{
                .active_style = .{
                    .foreground = breadcrumb.accent,
                    .background = theme.background,
                    .attributes = .{ .bold = true },
                },
                .idle_style = .{
                    .foreground = theme.muted,
                    .background = theme.panel,
                    .attributes = .{ .dim = true },
                },
                .gap = 1,
                .items = breadcrumb.tabs,
                .selected = breadcrumb.selected,
            } });
        },
    }
}

fn place_label(
    tree: *dom.DomTree,
    parent: NodeIndex,
    x: u16,
    width: u16,
) !NodeIndex {
    return tree.append_child(parent, .{
        .kind = .label,
        .props = .{ .label = .{} },
        .layout = LayoutElement.placed(x, 0, width, 1),
    });
}

fn place_badge(
    tree: *dom.DomTree,
    parent: NodeIndex,
    x: u16,
    width: u16,
) !NodeIndex {
    return tree.append_child(parent, .{
        .kind = .badge,
        .props = .{ .badge = .{} },
        .layout = LayoutElement.placed(x, 0, width, 1),
    });
}

fn strong_style() markix.Style {
    var style = theme.panel_style;
    style.foreground = theme.foreground_strong;
    return style;
}
