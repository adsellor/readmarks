const std = @import("std");
const DomTree = @import("../dom/tree.zig").Tree;
const DomNode = @import("../dom/node.zig").DomNode;
const Color = @import("../style/color.zig").Color;
const Style = @import("../style/style.zig").Style;
const Attributes = @import("../style/text_style.zig").Attributes;

// What colour a widget is, decided once.
//
// Both web backends ask this: the generator, which writes the answer into a
// stylesheet-free document, and the serializer, which sends it to a page laying
// itself out. They used to decide separately, and disagreed -- the serializer
// gave every node its style's background, while the generator gave one only to
// the widgets that actually paint a surface. The same tree then looked like two
// different documents depending on which backend drew it.
//
// A widget that paints nothing leaves both fields null: it sits on whatever its
// parent already painted, which is how the terminal renderer resolves it too.

pub const Paint = struct {
    foreground: ?Color = null,
    background: ?Color = null,
    attributes: Attributes = .{},
};

/// The colours a node paints, given where it sits in the tree.
pub fn of(tree: *const DomTree, index: DomTree.NodeIndex) Paint {
    std.debug.assert(index < tree.node_count);
    const node = &tree.nodes[index].element;
    if (node.kind == .list_item) return list_item(tree, index, node);
    return of_node(node);
}

/// The colours a node paints from its own props alone.
pub fn of_node(node: *const DomNode) Paint {
    return switch (node.kind) {
        .label => label(node.props.label),
        .heading => .{
            .foreground = node.props.heading.style.foreground,
            .attributes = node.props.heading.visual.attributes,
        },
        .rule => .{ .background = node.props.rule.style.border },
        .code_block => .{
            .foreground = node.props.code_block.style.foreground,
            .background = node.props.code_block.style.background,
        },
        .badge => .{
            .foreground = node.props.badge.style.foreground,
            .background = node.props.badge.style.background,
            .attributes = node.props.badge.style.attributes,
        },
        .panel => .{ .background = node.props.panel.style.background },
        .list => .{ .background = node.props.list.style.background },
        // A row sits on the list, which has already painted underneath it.
        .list_item => .{},
        .status_line => .{
            .foreground = node.props.status_line.style.foreground,
            .background = node.props.status_line.style.background,
        },
        .button => .{
            .foreground = node.props.button.foreground,
            .background = node.props.button.background,
        },
        .text_input, .segmented, .container, .image => .{},
    };
}

fn label(props: @import("../dom/types.zig").LabelProps) Paint {
    const foreground = if (props.muted) props.style.muted else props.style.foreground;
    return .{ .foreground = foreground };
}

/// A selected row is the one thing a row paints for itself, and it takes the
/// colours from the list it is mounted in rather than carrying its own.
fn list_item(
    tree: *const DomTree,
    index: DomTree.NodeIndex,
    node: *const DomNode,
) Paint {
    std.debug.assert(index < tree.node_count);
    std.debug.assert(node.kind == .list_item);
    if (!node.props.list_item.selected) return .{};
    const parent = tree.parent_index(index) orelse return .{};
    const owner = &tree.nodes[parent].element;
    if (owner.kind != .list) return .{};
    const style: Style = owner.props.list.style;
    return .{
        .foreground = style.selected_foreground,
        .background = style.selected_background,
    };
}

test "a widget that paints no surface leaves the background alone" {
    // The divergence this exists to prevent: a label given its style's
    // background paints a box behind every line of prose, which the generator
    // never drew and the terminal never drew either.
    const LayoutElement = @import("../layout/tree.zig").LayoutElement;
    var tree = DomTree.init();
    _ = try tree.set_root(.{
        .kind = .label,
        .props = .{ .label = .{ .text = "prose", .style = Style.plain() } },
        .layout = LayoutElement.sized(1),
    });
    const result = of(&tree, 0);
    try std.testing.expect(result.background == null);
    try std.testing.expect(result.foreground != null);
}

test "a panel paints its surface" {
    const LayoutElement = @import("../layout/tree.zig").LayoutElement;
    var tree = DomTree.init();
    _ = try tree.set_root(.{
        .kind = .panel,
        .props = .{ .panel = .{ .style = Style.plain() } },
        .layout = LayoutElement.sized(4),
    });
    try std.testing.expect(of(&tree, 0).background != null);
}

test "a row takes the list's selection colours, and otherwise paints nothing" {
    const LayoutElement = @import("../layout/tree.zig").LayoutElement;
    var tree = DomTree.init();
    const list = try tree.set_root(.{
        .kind = .list,
        .props = .{ .list = .{ .style = Style.plain() } },
        .layout = LayoutElement.sized(4),
    });
    const quiet = try tree.append_child(list, .{
        .kind = .list_item,
        .props = .{ .list_item = .{ .title = "one" } },
        .layout = LayoutElement.sized(1),
    });
    const chosen = try tree.append_child(list, .{
        .kind = .list_item,
        .props = .{ .list_item = .{ .title = "two", .selected = true } },
        .layout = LayoutElement.sized(1),
    });
    try std.testing.expect(of(&tree, quiet).background == null);
    try std.testing.expect(of(&tree, chosen).background != null);
}
