const Color = @import("color.zig").Color;

pub const Style = struct {
    foreground: Color,
    background: Color,
    muted: Color,
    accent: Color,
    border: Color,
    selected_foreground: Color,
    selected_background: Color,

    pub fn monochrome(foreground: Color, background: Color) Style {
        return .{
            .foreground = foreground,
            .background = background,
            .muted = foreground,
            .accent = foreground,
            .border = foreground,
            .selected_foreground = background,
            .selected_background = foreground,
        };
    }

    /// Theme-neutral style usable as a field default. DOM props are compared
    /// with std.meta.eql and painted as-is, so they cannot default to undefined.
    pub fn plain() Style {
        return monochrome(
            Color.terminal_foreground(),
            Color.terminal_background(),
        );
    }
};

pub const TextSelectionStyle = struct {
    foreground: Color,
    background: Color,
    active_background: Color,
    anchor_background: Color,
    cursor_foreground: Color,
    cursor_background: Color,
};
