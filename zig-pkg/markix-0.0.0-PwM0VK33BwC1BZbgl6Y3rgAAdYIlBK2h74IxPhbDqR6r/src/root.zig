/// The whole public surface, flat at the top so one import is enough to
/// build an application.

// Value types.
pub const Color = @import("style/color.zig").Color;
pub const Rect = @import("layout/rect.zig").Rect;
pub const Style = @import("style/style.zig").Style;
pub const TextSelectionStyle = @import("style/style.zig").TextSelectionStyle;
pub const TextStyle = @import("style/text_style.zig").TextStyle;
pub const Attributes = @import("style/text_style.zig").Attributes;

// Input, shared by the terminal and web backends.
pub const Key = @import("utils/input.zig").Key;
pub const Pointer = @import("utils/input.zig").Pointer;
pub const PointerAction = @import("utils/input.zig").PointerAction;
pub const PointerButton = @import("utils/input.zig").PointerButton;

// The event loop an application runs.
pub const Event = @import("backend/terminal/event.zig").Event;
pub const LoopAction = @import("backend/terminal/event.zig").LoopAction;
pub const LoopOptions = @import("backend/terminal/event.zig").LoopOptions;
pub const run_event_loop = @import("backend/terminal/event.zig").run_event_loop;

// Widgets: the vocabulary of a screen.
pub const widgets = @import("widgets.zig");

// Domains, each self-contained.
pub const layout = @import("layout.zig");
pub const terminal = @import("backend/terminal.zig");
pub const web = @import("backend/web.zig");
pub const theme = @import("theme.zig");
pub const dom = @import("dom.zig");
pub const render = @import("render.zig");

// Parsers.
pub const document = @import("parser/document.zig");
pub const readable = @import("parser/readable.zig");
pub const xml = @import("parser/xml.zig");
