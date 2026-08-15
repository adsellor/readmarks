const std = @import("std");
const Color = @import("style/color.zig").Color;
const Style = @import("style/style.zig").Style;
const TextSelectionStyle = @import("style/style.zig").TextSelectionStyle;

pub const Mode = enum { markix, terminal };

const Palette = struct {
    background: Color,
    panel: Color,
    panel_alt: Color,
    line: Color,
    selection: Color,
    foreground: Color,
    foreground_strong: Color,
    inverse_foreground: Color,
    muted: Color,
    accent: Color,
    accent_warm: Color,
    accent_cool: Color,
    danger: Color,
    command: Color,
    shadow: Color,
    base: Style,
    panel_style: Style,
    focused_field: Style,
    focused_panel: Style,
    warning: Style,
    command_panel: Style,
    command_field: Style,
    selection_browse: TextSelectionStyle,
    selection_bookmarks: TextSelectionStyle,
    selection_preview: TextSelectionStyle,
    selection_command: TextSelectionStyle,
};

const markix_palette = make_markix_palette();
const terminal_palette = make_terminal_palette();

pub var mode: Mode = .markix;
pub var background = markix_palette.background;
pub var panel = markix_palette.panel;
pub var panel_alt = markix_palette.panel_alt;
pub var line = markix_palette.line;
pub var selection = markix_palette.selection;
pub var foreground = markix_palette.foreground;
pub var foreground_strong = markix_palette.foreground_strong;
pub var inverse_foreground = markix_palette.inverse_foreground;
pub var muted = markix_palette.muted;
pub var accent = markix_palette.accent;
pub var accent_warm = markix_palette.accent_warm;
pub var accent_cool = markix_palette.accent_cool;
pub var danger = markix_palette.danger;
pub var command = markix_palette.command;
pub var shadow = markix_palette.shadow;
pub var base = markix_palette.base;
pub var panel_style = markix_palette.panel_style;
pub var focused_field = markix_palette.focused_field;
pub var focused_panel = markix_palette.focused_panel;
pub var warning = markix_palette.warning;
pub var command_panel = markix_palette.command_panel;
pub var command_field = markix_palette.command_field;
pub var selection_browse = markix_palette.selection_browse;
pub var selection_bookmarks = markix_palette.selection_bookmarks;
pub var selection_preview = markix_palette.selection_preview;
pub var selection_command = markix_palette.selection_command;

pub fn configure(value: ?[]const u8) void {
    const name = value orelse return;
    if (std.ascii.eqlIgnoreCase(name, "terminal") or
        std.ascii.eqlIgnoreCase(name, "inherit"))
    {
        apply(.terminal);
    } else {
        apply(.markix);
    }
}

pub fn apply(next_mode: Mode) void {
    const palette = switch (next_mode) {
        .markix => markix_palette,
        .terminal => terminal_palette,
    };
    mode = next_mode;
    apply_colors(&palette);
    apply_styles(&palette);
    apply_selections(&palette);
}

fn apply_colors(palette: *const Palette) void {
    std.debug.assert(!palette.background.equals(palette.foreground));
    std.debug.assert(!palette.background.equals(palette.accent));
    background = palette.background;
    panel = palette.panel;
    panel_alt = palette.panel_alt;
    line = palette.line;
    selection = palette.selection;
    foreground = palette.foreground;
    foreground_strong = palette.foreground_strong;
    inverse_foreground = palette.inverse_foreground;
    muted = palette.muted;
    accent = palette.accent;
    accent_warm = palette.accent_warm;
    accent_cool = palette.accent_cool;
    danger = palette.danger;
    command = palette.command;
    shadow = palette.shadow;
}

fn apply_styles(palette: *const Palette) void {
    base = palette.base;
    panel_style = palette.panel_style;
    focused_field = palette.focused_field;
    focused_panel = palette.focused_panel;
    warning = palette.warning;
    command_panel = palette.command_panel;
    command_field = palette.command_field;
}

fn apply_selections(palette: *const Palette) void {
    selection_browse = palette.selection_browse;
    selection_bookmarks = palette.selection_bookmarks;
    selection_preview = palette.selection_preview;
    selection_command = palette.selection_command;
}

pub fn pane_style(accent_color: Color, focused: bool) Style {
    var style = panel_style;
    style.accent = accent_color;
    if (focused) style.border = accent_color;
    return style;
}

fn make_markix_palette() Palette {
    const background_color = Color.from_rgb(13, 15, 18);
    const panel_color = Color.from_rgb(22, 25, 29);
    const panel_alt_color = Color.from_rgb(31, 35, 40);
    const line_color = Color.from_rgb(52, 59, 67);
    const selection_color = Color.from_rgb(38, 70, 66);
    const foreground_color = Color.from_rgb(236, 239, 242);
    const foreground_strong_color = Color.from_rgb(250, 252, 253);
    std.debug.assert(!background_color.equals(foreground_color));
    std.debug.assert(!panel_color.equals(panel_alt_color));
    const muted_color = Color.from_rgb(139, 149, 159);
    const accent_color = Color.from_rgb(78, 211, 174);
    const accent_warm_color = Color.from_rgb(245, 176, 91);
    const accent_cool_color = Color.from_rgb(105, 169, 255);
    const danger_color = Color.from_rgb(240, 105, 115);
    const command_color = Color.from_rgb(255, 122, 156);
    const shadow_color = Color.from_rgb(5, 6, 8);
    return make_palette(.{
        .background = background_color,
        .panel = panel_color,
        .panel_alt = panel_alt_color,
        .line = line_color,
        .selection = selection_color,
        .foreground = foreground_color,
        .foreground_strong = foreground_strong_color,
        .inverse_foreground = background_color,
        .muted = muted_color,
        .accent = accent_color,
        .accent_warm = accent_warm_color,
        .accent_cool = accent_cool_color,
        .danger = danger_color,
        .command = command_color,
        .shadow = shadow_color,
    });
}

fn make_terminal_palette() Palette {
    const background_color = Color.terminal_background();
    const foreground_color = Color.terminal_foreground();
    std.debug.assert(background_color.kind == .terminal_background);
    std.debug.assert(foreground_color.kind == .terminal_foreground);
    return make_palette(.{
        .background = background_color,
        .panel = background_color,
        .panel_alt = background_color,
        .line = Color.ansi(8),
        .selection = Color.ansi(6),
        .foreground = foreground_color,
        .foreground_strong = foreground_color,
        .inverse_foreground = Color.ansi(0),
        .muted = Color.ansi(8),
        .accent = Color.ansi(6),
        .accent_warm = Color.ansi(3),
        .accent_cool = Color.ansi(4),
        .danger = Color.ansi(1),
        .command = Color.ansi(5),
        .shadow = background_color,
    });
}

const PaletteColors = struct {
    background: Color,
    panel: Color,
    panel_alt: Color,
    line: Color,
    selection: Color,
    foreground: Color,
    foreground_strong: Color,
    inverse_foreground: Color,
    muted: Color,
    accent: Color,
    accent_warm: Color,
    accent_cool: Color,
    danger: Color,
    command: Color,
    shadow: Color,
};

fn make_palette(colors: PaletteColors) Palette {
    std.debug.assert(!colors.background.equals(colors.foreground));
    std.debug.assert(!colors.foreground.equals(colors.accent));
    return .{
        .background = colors.background,
        .panel = colors.panel,
        .panel_alt = colors.panel_alt,
        .line = colors.line,
        .selection = colors.selection,
        .foreground = colors.foreground,
        .foreground_strong = colors.foreground_strong,
        .inverse_foreground = colors.inverse_foreground,
        .muted = colors.muted,
        .accent = colors.accent,
        .accent_warm = colors.accent_warm,
        .accent_cool = colors.accent_cool,
        .danger = colors.danger,
        .command = colors.command,
        .shadow = colors.shadow,
        .base = base_style(colors),
        .panel_style = panel_style_value(colors),
        .focused_field = focused_field_style(colors),
        .focused_panel = focused_panel_style(colors),
        .warning = warning_style(colors),
        .command_panel = command_panel_style(colors),
        .command_field = command_field_style(colors),
        .selection_browse = browse_selection(colors),
        .selection_bookmarks = bookmark_selection(colors),
        .selection_preview = preview_selection(colors),
        .selection_command = command_selection(colors),
    };
}

fn base_style(colors: PaletteColors) Style {
    return .{
        .foreground = colors.foreground,
        .background = colors.background,
        .muted = colors.muted,
        .accent = colors.accent,
        .border = colors.line,
        .selected_foreground = colors.foreground_strong,
        .selected_background = colors.panel_alt,
    };
}

fn panel_style_value(colors: PaletteColors) Style {
    return .{
        .foreground = colors.foreground,
        .background = colors.panel,
        .muted = colors.muted,
        .accent = colors.accent,
        .border = colors.line,
        .selected_foreground = colors.foreground_strong,
        .selected_background = colors.selection,
    };
}

fn focused_field_style(colors: PaletteColors) Style {
    return .{
        .foreground = colors.foreground_strong,
        .background = colors.panel_alt,
        .muted = colors.muted,
        .accent = colors.accent_warm,
        .border = colors.accent,
        .selected_foreground = colors.inverse_foreground,
        .selected_background = colors.accent_warm,
    };
}

fn focused_panel_style(colors: PaletteColors) Style {
    var style = panel_style_value(colors);
    style.accent = colors.accent_warm;
    style.border = colors.accent_warm;
    return style;
}

fn warning_style(colors: PaletteColors) Style {
    var style = base_style(colors);
    style.background = colors.danger;
    style.muted = colors.foreground;
    style.accent = colors.danger;
    style.border = colors.danger;
    style.selected_foreground = colors.inverse_foreground;
    style.selected_background = colors.danger;
    return style;
}

fn command_panel_style(colors: PaletteColors) Style {
    var style = panel_style_value(colors);
    style.accent = colors.command;
    style.border = colors.command;
    style.selected_background = colors.command;
    return style;
}

fn command_field_style(colors: PaletteColors) Style {
    var style = focused_field_style(colors);
    style.accent = colors.command;
    style.border = colors.command;
    style.selected_background = colors.command;
    return style;
}

fn browse_selection(colors: PaletteColors) TextSelectionStyle {
    return selection_style(colors, colors.accent_cool);
}

fn bookmark_selection(colors: PaletteColors) TextSelectionStyle {
    return selection_style(colors, colors.accent_warm);
}

fn preview_selection(colors: PaletteColors) TextSelectionStyle {
    return selection_style(colors, colors.accent);
}

fn command_selection(colors: PaletteColors) TextSelectionStyle {
    return selection_style(colors, colors.command);
}

fn selection_style(colors: PaletteColors, selected: Color) TextSelectionStyle {
    return .{
        .foreground = colors.foreground_strong,
        .background = selected,
        .active_background = selected,
        .anchor_background = colors.line,
        .cursor_foreground = colors.inverse_foreground,
        .cursor_background = selected,
    };
}

test "terminal palette uses terminal defaults and ANSI accents" {
    apply(.terminal);
    defer apply(.markix);
    try std.testing.expectEqual(Mode.terminal, mode);
    try std.testing.expectEqual(Color.Kind.terminal_background, background.kind);
    try std.testing.expectEqual(Color.Kind.terminal_foreground, foreground.kind);
    try std.testing.expectEqual(Color.Kind.ansi, accent.kind);
}
