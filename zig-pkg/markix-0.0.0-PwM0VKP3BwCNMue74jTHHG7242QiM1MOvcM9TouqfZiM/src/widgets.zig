/// The vocabulary of a screen. Each widget is a draw call over a Surface or
/// the DOM node it is mounted as; state lives with the DOM, never the widget.
pub const Badge = @import("widgets/badge.zig").Badge;
pub const BadgeStyle = @import("widgets/badge.zig").BadgeStyle;
pub const FuzzyText = @import("widgets/fuzzy_text.zig").FuzzyText;
pub const Label = @import("widgets/label.zig").Label;
pub const Inline = @import("widgets/inline.zig").Inline;
pub const Image = @import("widgets/image.zig").Image;
pub const Span = @import("widgets/inline.zig").Span;
pub const List = @import("widgets/list.zig").List;
pub const ListItem = @import("widgets/list.zig").Item;
pub const ListVisual = @import("widgets/list.zig").Visual;
pub const Heading = @import("widgets/heading.zig").Heading;
pub const HeadingVisual = @import("widgets/heading.zig").Visual;
pub const Rule = @import("widgets/rule.zig").Rule;
pub const RuleVisual = @import("widgets/rule.zig").Visual;
pub const CodeBlock = @import("widgets/code_block.zig").CodeBlock;
pub const CodeVisual = @import("widgets/code_block.zig").Visual;
pub const Panel = @import("widgets/panel.zig").Panel;
pub const PanelChrome = @import("widgets/panel.zig").Chrome;
/// Inner box a panel paints into; the DOM lays panel children out here.
pub const panel_content_rect = @import("widgets/panel.zig").content_rect;
pub const Scrollbar = @import("widgets/scrollbar.zig").Scrollbar;
pub const ScrollbarStyle = @import("widgets/scrollbar.zig").ScrollbarStyle;
pub const Segmented = @import("widgets/segmented.zig").Segmented;
pub const SegmentItem = @import("widgets/segmented.zig").Item;
pub const StatusHint = @import("widgets/status_line.zig").Hint;
pub const StatusLine = @import("widgets/status_line.zig").StatusLine;
pub const StatusVisual = @import("widgets/status_line.zig").Visual;
pub const TextInput = @import("widgets/text_input.zig").TextInput;
pub const TextInputAction = @import("widgets/text_input.zig").Action;
pub const TextInputOptions = @import("widgets/text_input.zig").Options;
pub const draw_text_input = @import("widgets/text_input.zig").draw;
