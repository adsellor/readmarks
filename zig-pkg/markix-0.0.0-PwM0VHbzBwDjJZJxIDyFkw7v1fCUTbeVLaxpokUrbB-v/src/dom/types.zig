const std = @import("std");
const Color = @import("../style/color.zig").Color;
const Style = @import("../style/style.zig").Style;
const Attributes = @import("../style/text_style.zig").Attributes;
const badge = @import("../widgets/badge.zig");
const list = @import("../widgets/list.zig");
const panel = @import("../widgets/panel.zig");
const heading = @import("../widgets/heading.zig");
const rule = @import("../widgets/rule.zig");
const code_block = @import("../widgets/code_block.zig");
const segmented = @import("../widgets/segmented.zig");
const status_line = @import("../widgets/status_line.zig");
const text_input = @import("../widgets/text_input.zig");

pub const BadgeStyle = badge.BadgeStyle;
pub const ListItem = list.Item;
pub const ListVisual = list.Visual;
pub const PanelChrome = panel.Chrome;
pub const HeadingVisual = heading.Visual;
pub const RuleVisual = rule.Visual;
pub const CodeVisual = code_block.Visual;
pub const SegmentItem = segmented.Item;
pub const StatusHint = status_line.Hint;
pub const StatusVisual = status_line.Visual;

/// What a node *means*, as opposed to how it is drawn.
///
/// Kept separate from NodeKind because the two are genuinely orthogonal: the
/// same `.label` is a heading in one place and a byline in another, and a
/// `.list` may be navigation or prose. Backends that emit a document rather
/// than a grid -- the web renderer -- use this to pick real elements, so
/// markix never has to know what an application's content is.
pub const Semantic = enum(u8) {
    none,
    article,
    section,
    nav,
    header,
    footer,
    aside,
    main_content,
    heading,
    paragraph,
    link,
    list,
    list_item,
    code,
    quote,
    emphasis,
    strong,
    time,
    /// `href` carries the source; the node's text is the alternative text.
    image,
};

pub const SemanticInfo = struct {
    tag: Semantic = .none,
    /// Heading depth, 1-6. Ignored unless `tag` is `.heading`.
    level: u8 = 0,
    /// Target for `.link`; empty otherwise.
    href: []const u8 = "",
    /// What this node can be referred to as, from anywhere.
    ///
    /// A link needs something to point at, and the thing it points at has to
    /// be nameable without knowing where in the tree it ended up -- a contents
    /// entry names a heading, not "the fourth child of the article". The name
    /// travels with the node, so it survives being laid out again at a
    /// different measure, and both backends resolve it: a document emits it as
    /// an `id`, a terminal finds the node by it and scrolls there.
    id: []const u8 = "",
};

/// Longest anchor name a node may carry.
///
/// Bounded because a name is copied into a fixed frame record and compared on
/// every lookup; a name longer than this is a caller's bug rather than
/// something to truncate silently.
pub const semantic_id_bytes_max: u16 = 128;

pub const NodeKind = enum(u8) {
    container,
    label,
    heading,
    rule,
    code_block,
    badge,
    button,
    list,
    list_item,
    panel,
    text_input,
    segmented,
    status_line,
    image,
};

/// Props carry every input a widget's draw call needs, so the renderer can
/// paint a node from `props`, its rect, and its DOM flags alone. State the DOM
/// owns -- `focused` and `hovered` -- deliberately does not appear here; the
/// renderer feeds the node flags into the widget instead. Slices point at
/// caller-owned storage and must outlive the frame.
pub const LabelProps = struct {
    text: []const u8 = "",
    style: Style = Style.plain(),
    muted: bool = false,
    /// Whether the text flows across rows. Drives both how tall the measure
    /// pass makes the node and how the renderer paints it, so the two cannot
    /// disagree. Off by default: a label is one line unless it says otherwise.
    wrap: bool = false,
};

pub const HeadingProps = struct {
    text: []const u8 = "",
    /// 1 is the most significant; 6 the least.
    level: u8 = 1,
    style: Style = Style.plain(),
    visual: HeadingVisual = .{},
};

pub const RuleProps = struct {
    style: Style = Style.plain(),
    visual: RuleVisual = .{},
};

pub const CodeBlockProps = struct {
    text: []const u8 = "",
    language: []const u8 = "",
    style: Style = Style.plain(),
    visual: CodeVisual = .{},
};

pub const BadgeProps = struct {
    text: []const u8 = "",
    style: BadgeStyle = BadgeStyle.plain(),
};

pub const ButtonProps = struct {
    text: []const u8 = "",
    foreground: Color = Color.from_rgb(230, 230, 230),
    background: Color = Color.from_rgb(40, 44, 52),
    focus_foreground: Color = Color.from_rgb(0, 0, 0),
    focus_background: Color = Color.from_rgb(97, 175, 239),
    hover_background: Color = Color.from_rgb(60, 64, 72),
    attributes: Attributes = .{ .bold = true },
    padding: u8 = 1,
    action_id: u16 = 0,
};

/// A list owns presentation and selection state; its rows are `list_item`
/// child nodes rather than an items slice. Changing one row's text dirties
/// that row alone, so a repaint costs one row instead of the whole viewport.
pub const ListProps = struct {
    style: Style = Style.plain(),
    empty_text: []const u8 = "No items",
    highlight_query: []const u8 = "",
    match_foreground: ?Color = null,
    visual: ListVisual = .{},
    /// Total items in the backing collection, which may exceed the rows
    /// currently mounted as children. Drives selection and scroll bounds.
    item_count: u16 = 0,
    selected: u16 = 0,
    scroll: u16 = 0,
};

/// One mounted row. Styling is read from the parent list at paint time so a
/// presentation change lives in exactly one place.
pub const ListItemProps = struct {
    title: []const u8 = "",
    detail: []const u8 = "",
    subtitle: []const u8 = "",
    marker: u8 = ' ',
    selected: bool = false,
    /// Columns this row is shifted by, for a list whose rows form a hierarchy
    /// -- a table of contents, a file tree. Depth is presentation, so it lives
    /// with the row rather than being encoded into its title by the caller.
    indent: u8 = 0,

    pub fn item(self: ListItemProps) ListItem {
        return .{
            .title = self.title,
            .detail = self.detail,
            .subtitle = self.subtitle,
            .marker = self.marker,
            .indent = self.indent,
        };
    }
};

pub const PanelProps = struct {
    style: Style = Style.plain(),
    chrome: PanelChrome = .{},
    title: []const u8 = "",
    meta: []const u8 = "",
};

pub const TextInputProps = struct {
    style: Style = Style.plain(),
    prompt: []const u8 = "",
    placeholder: []const u8 = "",
    /// Rendered text. The DOM does not own the buffer: dispatch moves `cursor`
    /// but leaves content edits to whoever owns the backing TextInput.
    value: []const u8 = "",
    cursor: u16 = 0,
    prompt_attributes: Attributes = .{ .bold = true },
    value_attributes: Attributes = .{},
    placeholder_attributes: Attributes = .{ .dim = true },
    cursor_attributes: Attributes = .{ .bold = true },

    /// Adapts props to the duck-typed reader `text_input.draw` expects.
    pub fn view(self: *const TextInputProps) TextInputView {
        return .{ .text = self.value, .cursor = self.cursor };
    }

    pub fn options(self: TextInputProps, focused: bool) text_input.Options {
        return .{
            .prompt = self.prompt,
            .placeholder = self.placeholder,
            .style = self.style,
            .focused = focused,
            .prompt_attributes = self.prompt_attributes,
            .value_attributes = self.value_attributes,
            .placeholder_attributes = self.placeholder_attributes,
            .cursor_attributes = self.cursor_attributes,
        };
    }
};

/// Read-only stand-in matching the `.value()` / `.cursor` shape that
/// `text_input.draw` accepts, so a DOM node reuses the widget unchanged.
pub const TextInputView = struct {
    text: []const u8,
    cursor: u16,

    pub fn value(self: *const TextInputView) []const u8 {
        return self.text;
    }
};

pub const SegmentedProps = struct {
    active_style: BadgeStyle = BadgeStyle.plain(),
    idle_style: BadgeStyle = BadgeStyle.plain(),
    gap: u8 = 1,
    items: []const SegmentItem = &.{},
    selected: u16 = 0,
};

pub const StatusLineProps = struct {
    style: Style = Style.plain(),
    visual: StatusVisual = .{},
    message: []const u8 = "",
    hints: []const StatusHint = &.{},
};

pub const ImageProps = struct {
    path: []const u8 = "",
    id: u32 = 1,
    crop_top_rows: u16 = 0,
    full_height_rows: u16 = 0,
};

pub const Props = union(NodeKind) {
    container: void,
    label: LabelProps,
    heading: HeadingProps,
    rule: RuleProps,
    code_block: CodeBlockProps,
    badge: BadgeProps,
    button: ButtonProps,
    list: ListProps,
    list_item: ListItemProps,
    panel: PanelProps,
    text_input: TextInputProps,
    segmented: SegmentedProps,
    status_line: StatusLineProps,
    image: ImageProps,
};

/// Props equality used for dirty detection.
///
/// std.meta.eql compares a slice by pointer and length, so text rewritten into
/// a reused buffer would compare equal and the node would never repaint.
/// Byte slices are therefore compared by content; everything else falls back
/// to structural comparison.
pub fn props_equal(a: Props, b: Props) bool {
    if (@as(NodeKind, a) != @as(NodeKind, b)) return false;
    return switch (a) {
        inline else => |value, tag| value_equal(
            @TypeOf(value),
            value,
            @field(b, @tagName(tag)),
        ),
    };
}

fn value_equal(comptime T: type, a: T, b: T) bool {
    std.debug.assert(@sizeOf(T) > 0 or T == void);
    std.debug.assert(@typeInfo(T) != .@"opaque");
    if (T == []const u8) return std.mem.eql(u8, a, b);
    return switch (@typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.field_names, info.field_types) |name, Field| {
                if (!value_equal(Field, @field(a, name), @field(b, name))) {
                    return false;
                }
            }
            return true;
        },
        .optional => |info| {
            if (a == null or b == null) return (a == null) == (b == null);
            return value_equal(info.child, a.?, b.?);
        },
        .pointer => |info| switch (info.size) {
            .slice => slice_equal(info.child, a, b),
            else => a == b,
        },
        else => std.meta.eql(a, b),
    };
}

fn slice_equal(comptime Child: type, a: []const Child, b: []const Child) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!value_equal(Child, left, right)) return false;
    }
    return true;
}

test "props union covers all node kinds" {
    @setEvalBranchQuota(10000);
    const kinds = std.enums.values(NodeKind);
    inline for (kinds) |kind| {
        _ = std.meta.fieldInfo(Props, kind);
    }
}

test "every props default is comparable without touching undefined" {
    @setEvalBranchQuota(10000);
    inline for (std.enums.values(NodeKind)) |kind| {
        const field = std.meta.fieldInfo(Props, kind);
        const a = @unionInit(Props, @tagName(kind), default_of(field.type));
        const b = @unionInit(Props, @tagName(kind), default_of(field.type));
        try std.testing.expect(std.meta.eql(a, b));
    }
}

fn default_of(comptime T: type) T {
    if (T == void) return {};
    return T{};
}

test "props carry the inputs their widget draw calls require" {
    // Each widget's draw signature needs data beyond styling; if a field here
    // disappears the corresponding renderer branch can no longer paint.
    const list_props = ListProps{};
    try std.testing.expectEqual(@as(u16, 0), list_props.item_count);
    try std.testing.expectEqual(@as(u16, 0), list_props.selected);
    try std.testing.expectEqual(@as(u16, 0), list_props.scroll);

    const status_props = StatusLineProps{};
    try std.testing.expectEqual(@as(usize, 0), status_props.hints.len);

    const segment_props = SegmentedProps{};
    try std.testing.expectEqual(@as(usize, 0), segment_props.items.len);

    const image_props = ImageProps{};
    try std.testing.expectEqual(@as(u16, 0), image_props.full_height_rows);
}

test "text input props adapt to the widget reader interface" {
    const props = TextInputProps{ .value = "hello", .cursor = 2 };
    const view = props.view();
    try std.testing.expectEqualStrings("hello", view.value());
    try std.testing.expectEqual(@as(u16, 2), view.cursor);
    try std.testing.expect(props.options(true).focused);
    try std.testing.expect(!props.options(false).focused);
}
