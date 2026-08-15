const std = @import("std");
const Rect = @import("../layout/rect.zig").Rect;
const LayoutElement = @import("../layout/tree.zig").LayoutElement;
const types = @import("types.zig");

pub const NodeKind = types.NodeKind;
pub const Props = types.Props;
pub const LabelProps = types.LabelProps;
pub const BadgeProps = types.BadgeProps;
pub const ButtonProps = types.ButtonProps;
pub const ListProps = types.ListProps;
pub const ListItemProps = types.ListItemProps;
pub const PanelProps = types.PanelProps;
pub const TextInputProps = types.TextInputProps;
pub const SegmentedProps = types.SegmentedProps;
pub const StatusLineProps = types.StatusLineProps;
pub const ImageProps = types.ImageProps;

pub const BadgeStyle = types.BadgeStyle;
pub const ListItem = types.ListItem;
pub const ListVisual = types.ListVisual;
pub const PanelChrome = types.PanelChrome;
pub const SegmentItem = types.SegmentItem;
pub const StatusHint = types.StatusHint;
pub const StatusVisual = types.StatusVisual;
pub const TextInputView = types.TextInputView;
pub const Semantic = types.Semantic;
pub const SemanticInfo = types.SemanticInfo;

const panel_widget = @import("../widgets/panel.zig");

pub const DomNode = struct {
    kind: NodeKind,
    props: Props,
    layout: LayoutElement,
    dirty: bool = true,
    focused: bool = false,
    hovered: bool = false,
    interactable: bool = false,
    /// Meaning rather than appearance. Structural, so it is set when a node is
    /// mounted rather than updated per frame like props.
    semantic: SemanticInfo = .{},

    pub fn rect(self: DomNode) Rect {
        return self.layout.rect;
    }

    /// Box this node's children occupy. Only chrome-bearing kinds inset it;
    /// for everything else children fill the node's own rect.
    pub fn content_rect(self: DomNode) Rect {
        return switch (self.kind) {
            .panel => panel_widget.content_rect(self.props.panel.chrome, self.layout.rect),
            else => self.layout.rect,
        };
    }

    pub fn mark_dirty(self: *DomNode) void {
        self.dirty = true;
    }

    pub fn clear_dirty(self: *DomNode) void {
        self.dirty = false;
    }

    /// For a standalone node. A node inside a tree must be changed through
    /// `Tree.set_focused`, which also keeps the tree's dirty_count in step.
    pub fn set_focused(self: *DomNode, value: bool) void {
        if (self.focused != value) {
            self.focused = value;
            self.dirty = true;
        }
    }

    /// For a standalone node; see `set_focused`.
    pub fn set_hovered(self: *DomNode, value: bool) void {
        if (self.hovered != value) {
            self.hovered = value;
            self.dirty = true;
        }
    }
};

test "node dirty flag transitions" {
    var node = DomNode{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.leaf(),
    };
    try std.testing.expect(node.dirty);
    node.clear_dirty();
    try std.testing.expect(!node.dirty);
    node.mark_dirty();
    try std.testing.expect(node.dirty);
}

test "node focus change marks dirty" {
    var node = DomNode{
        .kind = .button,
        .props = .{ .button = .{} },
        .layout = LayoutElement.leaf(),
        .dirty = false,
        .interactable = true,
    };
    node.set_focused(true);
    try std.testing.expect(node.dirty);
    try std.testing.expect(node.focused);
}

test "node hover change marks dirty" {
    var node = DomNode{
        .kind = .button,
        .props = .{ .button = .{} },
        .layout = LayoutElement.leaf(),
        .dirty = false,
        .interactable = true,
    };
    node.set_hovered(true);
    try std.testing.expect(node.dirty);
    try std.testing.expect(node.hovered);
}

test "node focus same value does not mark dirty" {
    var node = DomNode{
        .kind = .button,
        .props = .{ .button = .{} },
        .layout = LayoutElement.leaf(),
        .dirty = false,
    };
    node.set_focused(false);
    try std.testing.expect(!node.dirty);
}
