const std = @import("std");
const commands = @import("commands.zig");
const TerminalCanvas = @import("../terminal/canvas.zig").TerminalCanvas;
const TextEntry = @import("../terminal/text_entry.zig").TextEntry;
const Color = @import("../../style/color.zig").Color;
const theme = @import("../../theme.zig");

// Serializes a terminal canvas into the shared binary frame format
// (see commands.zig). Pure: no io, no allocation.

pub fn serialize_frame(canvas: *const TerminalCanvas, output: []u8) !usize {
    const positions = commands.layout(
        canvas.web_rect_count,
        canvas.text_entries.items.len,
        canvas.selection.region_count(),
        if (canvas.image_placement != null) 1 else 0,
    );
    if (output.len < positions.total) return error.BufferTooSmall;
    std.debug.assert(positions.total > 0);

    var writer = commands.Writer{ .bytes = output };
    try writer.write_u32(commands.magic);
    try writer.write_u32(commands.version);
    try writer.write_u32(canvas.width);
    try writer.write_u32(canvas.height);
    try writer.write_u32(canvas.height / 2);
    const fill = color_to_rgba(canvas.background_color);
    try writer.write_rgba(fill.r, fill.g, fill.b, fill.a);
    try writer.write_u32(positions.rect_offset);
    try writer.write_u32(canvas.web_rect_count);
    try writer.write_u32(positions.text_offset);
    try writer.write_u32(@intCast(canvas.text_entries.items.len));
    try writer.write_u32(positions.selection_offset);
    try writer.write_u32(canvas.selection.region_count());
    try writer.write_u32(positions.image_offset);
    try writer.write_u32(if (canvas.image_placement != null) 1 else 0);
    try writer.write_u32(@intCast(positions.total));

    try write_rects(&writer, canvas);
    for (canvas.text_entries.items) |entry| {
        try write_text_entry(&writer, &entry);
    }
    try write_selection(&writer, canvas);
    try write_image(&writer, canvas);
    std.debug.assert(writer.index == positions.total);
    return writer.index;
}

fn write_rects(writer: *commands.Writer, canvas: *const TerminalCanvas) !void {
    std.debug.assert(canvas.web_rect_count <= canvas.web_rects.len);
    for (canvas.web_rects[0..canvas.web_rect_count]) |rect| {
        const rgba = color_to_rgba(rect.color);
        try writer.write_u16(rect.x);
        try writer.write_u16(rect.y);
        try writer.write_u16(rect.width);
        try writer.write_u16(rect.height);
        try writer.write_rgba(rgba.r, rgba.g, rgba.b, rgba.a);
    }
}

fn write_selection(writer: *commands.Writer, canvas: *const TerminalCanvas) !void {
    const region_count = canvas.selection.region_count();
    std.debug.assert(region_count <= std.math.maxInt(u8));
    const active = canvas.selection.active();
    var index: u8 = 0;
    while (index < region_count) : (index += 1) {
        const rect = canvas.selection.region_rect(index);
        const style = canvas.selection.region_style(index);
        const background = if (active) style.active_background else style.background;
        const fill = color_to_rgba(background);
        const ink = color_to_rgba(style.foreground);
        try writer.write_u16(rect.x);
        try writer.write_u16(rect.y);
        try writer.write_u16(rect.width);
        try writer.write_u16(rect.height);
        try writer.write_rgba(fill.r, fill.g, fill.b, fill.a);
        try writer.write_rgba(ink.r, ink.g, ink.b, ink.a);
        try writer.write_u32(0);
        try writer.write_u32(0);
    }
    std.debug.assert(index == region_count);
}

fn write_image(writer: *commands.Writer, canvas: *const TerminalCanvas) !void {
    const placement = canvas.image_placement orelse return;
    std.debug.assert(placement.path_length <= placement.path.len);
    std.debug.assert(placement.path_length <= std.math.maxInt(u16));
    try writer.write_u16(placement.x);
    try writer.write_u16(placement.y);
    try writer.write_u16(placement.width);
    try writer.write_u16(placement.height);
    try writer.write_u16(placement.crop_top_rows);
    try writer.write_u16(placement.full_height_rows);
    try writer.write_u16(@intCast(placement.path_length));
    try writer.write_u16(0);
    try writer.write_u32(placement.id);
    try writer.write_bytes(placement.path[0..placement.path_length]);
}

fn write_text_entry(writer: *commands.Writer, entry: *const TextEntry) !void {
    std.debug.assert(entry.text_length <= entry.text.len);
    std.debug.assert(writer.index < writer.bytes.len);
    try writer.write_u16(entry.x);
    try writer.write_u16(entry.y);
    try writer.write_u16(entry.text_length);
    try writer.write_u16(0);
    const foreground = color_to_rgba(entry.foreground_color);
    try writer.write_rgba(foreground.r, foreground.g, foreground.b, foreground.a);
    if (entry.background_color) |background_color| {
        const background = color_to_rgba(background_color);
        try writer.write_rgba(background.r, background.g, background.b, background.a);
    } else {
        try writer.write_rgba(0, 0, 0, 0);
    }
    var attributes: u8 = 0;
    if (entry.attributes.bold) attributes |= commands.attrs_bold;
    if (entry.attributes.dim) attributes |= commands.attrs_dim;
    if (entry.attributes.underline) attributes |= commands.attrs_underline;
    try writer.write_u8(attributes);
    try writer.write_u8(0);
    try writer.write_u16(0);
    try writer.write_bytes(entry.text[0..entry.text_length]);
}

pub const Rgba = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

const ansi_palette = [_][3]u8{
    .{ 0, 0, 0 },
    .{ 205, 49, 49 },
    .{ 13, 188, 121 },
    .{ 229, 229, 16 },
    .{ 36, 114, 200 },
    .{ 188, 63, 188 },
    .{ 17, 168, 205 },
    .{ 229, 229, 229 },
    .{ 102, 117, 127 },
    .{ 241, 76, 76 },
    .{ 35, 209, 139 },
    .{ 245, 245, 67 },
    .{ 59, 142, 234 },
    .{ 214, 112, 214 },
    .{ 41, 184, 219 },
    .{ 229, 229, 229 },
};

/// Resolves a colour to concrete channels.
///
/// The two terminal-relative kinds stand for whatever the theme says the
/// terminal's own ink and paper are, so they are substituted first and the
/// result resolved once. Written as a substitution rather than as a call back
/// into this function: a theme whose foreground was itself
/// `.terminal_foreground` would then resolve forever, which is a stack
/// overflow reached through nothing worse than a plausible theme.
pub fn color_to_rgba(color: Color) Rgba {
    const resolved = switch (color.kind) {
        .terminal_foreground => theme.foreground,
        .terminal_background => theme.background,
        else => color,
    };
    std.debug.assert(resolved.kind != .terminal_foreground);
    std.debug.assert(resolved.kind != .terminal_background);
    return switch (resolved.kind) {
        .rgb => .{ .r = resolved.r, .g = resolved.g, .b = resolved.b, .a = resolved.a },
        .ansi => blk: {
            const channel = ansi_palette[resolved.r];
            break :blk .{ .r = channel[0], .g = channel[1], .b = channel[2], .a = 255 };
        },
        .transparent => .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        // Substituted above, and asserted gone.
        .terminal_foreground, .terminal_background => unreachable,
    };
}

test "ansi palette resolves to rgb" {
    const rgba = color_to_rgba(Color.ansi(1));
    try std.testing.expectEqual(@as(u8, 205), rgba.r);
    try std.testing.expectEqual(@as(u8, 49), rgba.g);
    try std.testing.expectEqual(@as(u8, 49), rgba.b);
    try std.testing.expectEqual(@as(u8, 255), rgba.a);
}
