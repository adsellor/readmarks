const std = @import("std");
const markix = @import("markix");
const Color = markix.Color;
const Style = markix.Style;

pub const Mode = enum { readmarks, terminal };

pub const Palette = struct {
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
    command_row: Color,
    shadow: Color,
};

const readmarks_palette = Palette{
    .background = Color.rgb(0x0d0f12),
    .panel = Color.rgb(0x16191d),
    .panel_alt = Color.rgb(0x1f2328),
    .line = Color.rgb(0x343b43),
    .selection = Color.rgb(0x264642),
    .foreground = Color.rgb(0xeceff2),
    .foreground_strong = Color.rgb(0xfafcfd),
    .inverse_foreground = Color.rgb(0x0d0f12),
    .muted = Color.rgb(0x8b959f),
    .accent = Color.rgb(0x4ed3ae),
    .accent_warm = Color.rgb(0xf5b05b),
    .accent_cool = Color.rgb(0x69a9ff),
    .danger = Color.rgb(0xf06973),
    .command = Color.rgb(0xff7a9c),
    .command_row = Color.rgb(0x482130),
    .shadow = Color.rgb(0x050608),
};

const terminal_palette = Palette{
    .background = Color.default(),
    .panel = Color.default(),
    .panel_alt = Color.default(),
    .line = Color.ansi(8),
    .selection = Color.ansi(6),
    .foreground = Color.default(),
    .foreground_strong = Color.default(),
    .inverse_foreground = Color.ansi(0),
    .muted = Color.ansi(8),
    .accent = Color.ansi(6),
    .accent_warm = Color.ansi(3),
    .accent_cool = Color.ansi(4),
    .danger = Color.ansi(1),
    .command = Color.ansi(5),
    .command_row = Color.ansi(8),
    .shadow = .{},
};

comptime {
    std.debug.assert(!readmarks_palette.background.eql(readmarks_palette.foreground));
    std.debug.assert(!readmarks_palette.panel.eql(readmarks_palette.panel_alt));
    std.debug.assert(!readmarks_palette.command.eql(readmarks_palette.command_row));
    std.debug.assert(!terminal_palette.command.eql(terminal_palette.command_row));
}

pub var mode: Mode = .readmarks;
pub var palette: Palette = readmarks_palette;

pub fn configure(value: ?[]const u8) void {
    const name = value orelse return;
    if (std.ascii.eqlIgnoreCase(name, "terminal") or std.ascii.eqlIgnoreCase(name, "inherit")) {
        apply(.terminal);
    } else {
        apply(.readmarks);
    }
}

pub fn apply(next: Mode) void {
    mode = next;
    palette = switch (next) {
        .readmarks => readmarks_palette,
        .terminal => terminal_palette,
    };
}

pub fn base() Style {
    return .{ .foreground = palette.foreground, .background = palette.background };
}

pub fn panel() Style {
    return .{ .foreground = palette.foreground, .background = palette.panel };
}

pub fn ink(foreground: Color) Style {
    return .{ .foreground = foreground };
}

pub fn strong(foreground: Color) Style {
    return .{ .foreground = foreground, .bold = true };
}

pub fn faint(foreground: Color) Style {
    return .{ .foreground = foreground, .dim = true };
}

pub fn chip(foreground: Color, background: Color) Style {
    return .{ .foreground = foreground, .background = background, .bold = true };
}

test "the terminal palette leaves grounds to the terminal and accents to ANSI" {
    apply(.terminal);
    defer apply(.readmarks);
    try std.testing.expectEqual(Mode.terminal, mode);
    try std.testing.expectEqual(Color.Kind.default, palette.background.kind);
    try std.testing.expectEqual(Color.Kind.default, palette.foreground.kind);
    try std.testing.expectEqual(Color.Kind.ansi, palette.accent.kind);
}
