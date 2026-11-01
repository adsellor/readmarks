const std = @import("std");
const Surface = @import("surface.zig").Surface;
const Color = @import("../style/color.zig").Color;
const Rect = @import("../layout/rect.zig").Rect;
const Style = @import("../style/style.zig").Style;
const Attributes = @import("../style/text_style.zig").Attributes;
const FuzzyText = @import("fuzzy_text.zig").FuzzyText;
const text_width = @import("../backend/terminal/text_width.zig");

pub const Item = struct {
    title: []const u8,
    detail: []const u8 = "",
    subtitle: []const u8 = "",
    marker: u8 = ' ',
    /// Columns of hierarchy, added to the title column.
    indent: u8 = 0,
};

pub const Visual = struct {
    row_height: u8 = 1,
    selected_marker: u8 = '>',
    title_attributes: Attributes = .{},
    selected_attributes: Attributes = .{ .bold = true },
    subtitle_attributes: Attributes = .{ .dim = true },
    match_attributes: Attributes = .{ .bold = true, .underline = true },
    detail_width_divisor: u8 = 3,
    /// Column a row's title starts at, leaving room for the selection marker
    /// and the row's own. Named rather than a literal because a backend that
    /// places a row's content itself -- a document, where the title is an
    /// anchor -- has to start it in the same column the terminal would.
    title_column: u8 = 3,
};

pub const List = struct {
    style: Style,
    empty_text: []const u8 = "No items",
    highlight_query: []const u8 = "",
    match_foreground: ?Color = null,
    focused: bool = false,
    visual: Visual = .{},

    pub fn capacity(self: List, height: u16) u16 {
        std.debug.assert(self.visual.row_height > 0);
        return @divFloor(height, self.visual.row_height);
    }

    pub fn draw(
        self: List,
        surface: Surface,
        rect: Rect,
        items: []const Item,
        selected: u16,
        scroll: u16,
    ) !void {
        std.debug.assert(items.len <= std.math.maxInt(u16));
        std.debug.assert(scroll == 0 or scroll < items.len);
        surface.fill(rect, self.style.background);
        if (rect.width == 0 or rect.height == 0) return;
        if (items.len == 0) {
            try surface.text_in(rect, 0, self.empty_text, self.style.muted, self.style.background);
            return;
        }
        if (self.visual.row_height == 0) return error.InvalidListRowHeight;
        var visible_index: u16 = 0;
        while (visible_index < self.capacity(rect.height)) : (visible_index += 1) {
            const item_index = @as(u32, scroll) + visible_index;
            if (item_index >= items.len) break;
            try self.draw_item(
                surface,
                Rect.init(
                    rect.x,
                    rect.y + visible_index * self.visual.row_height,
                    rect.width,
                    self.visual.row_height,
                ),
                items[item_index],
                item_index == selected,
            );
        }
    }

    /// Paints a single row standalone, background included.
    ///
    /// `draw` fills the whole list before drawing rows; a row repainted on its
    /// own must lay down its own background or the frame beneath shows through.
    pub fn draw_row(
        self: List,
        surface: Surface,
        rect: Rect,
        item: Item,
        selected: bool,
    ) !void {
        if (rect.width == 0 or rect.height == 0) return;
        surface.fill(rect, self.style.background);
        try self.draw_item(surface, rect, item, selected);
    }

    fn draw_item(
        self: List,
        surface: Surface,
        rect: Rect,
        item: Item,
        selected: bool,
    ) !void {
        std.debug.assert(self.visual.title_column > 0);
        if (rect.width == 0) return;
        std.debug.assert(rect.height > 0);
        const gutter: u16 = @as(u16, self.visual.title_column) + item.indent;
        const title_x = rect.x + @min(rect.width, gutter);
        const detail_width = item_detail_width(
            rect.width,
            item.detail.len,
            self.visual.detail_width_divisor,
        );
        const detail_x = rect.right() - detail_width;
        const title_width = detail_x -| title_x -| @intFromBool(detail_width > 0);
        const foreground = if (selected)
            self.style.selected_foreground
        else
            self.style.foreground;
        const background = if (selected)
            if (self.focused)
                self.style.selected_background
            else
                self.style.border
        else
            self.style.background;
        try self.draw_markers(surface, rect, item.marker, selected);
        try self.draw_title(
            surface,
            title_x,
            rect.y,
            title_width,
            item.title,
            foreground,
            background,
            if (selected)
                self.visual.selected_attributes
            else
                self.visual.title_attributes,
        );
        if (detail_width > 0) {
            try draw_clipped(
                surface,
                detail_x,
                rect.y,
                detail_width,
                item.detail,
                if (selected) self.style.accent else self.style.muted,
                if (selected) background else null,
                .{ .dim = !selected },
            );
        }
        if (rect.height > 1 and item.subtitle.len > 0) {
            try draw_clipped(
                surface,
                title_x,
                rect.y + 1,
                rect.right() -| title_x,
                item.subtitle,
                self.style.muted,
                null,
                self.visual.subtitle_attributes,
            );
        }
    }

    fn draw_title(
        self: List,
        surface: Surface,
        x: u16,
        y: u16,
        width: u16,
        value: []const u8,
        foreground: Color,
        background: ?Color,
        attributes: Attributes,
    ) !void {
        std.debug.assert(width <= std.math.maxInt(u16));
        std.debug.assert(value.len <= std.math.maxInt(u16));
        if (width == 0 or value.len == 0) return;
        try (FuzzyText{
            .query = self.highlight_query,
            .style = .{
                .foreground = foreground,
                .background = background,
                .attributes = attributes,
            },
            .match_style = .{
                .foreground = self.match_foreground orelse self.style.accent,
                .background = background,
                .attributes = self.visual.match_attributes,
            },
        }).draw(surface, Rect.init(x, y, width, 1), value);
    }

    fn draw_markers(
        self: List,
        surface: Surface,
        rect: Rect,
        marker: u8,
        selected: bool,
    ) !void {
        std.debug.assert(rect.height > 0);
        std.debug.assert(self.visual.title_column > 0);
        if (selected) {
            try surface.text(
                rect.x,
                rect.y,
                &.{self.visual.selected_marker},
                if (self.focused) self.style.accent else self.style.muted,
                null,
            );
        }
        if (marker != ' ' and rect.width > 1) {
            try surface.text(
                rect.x + 1,
                rect.y,
                &.{marker},
                self.style.accent,
                null,
            );
        }
    }
};

fn item_detail_width(width: u16, detail_length: usize, divisor: u8) u16 {
    if (width <= 8 or detail_length == 0) return 0;
    if (divisor == 0) return 0;
    const maximum = @min(@divFloor(width, divisor), width - 5);
    return @intCast(@min(detail_length, maximum));
}

fn draw_clipped(
    surface: Surface,
    x: u16,
    y: u16,
    width: u16,
    value: []const u8,
    foreground: Color,
    background: ?Color,
    attributes: Attributes,
) !void {
    std.debug.assert(width <= std.math.maxInt(u16));
    std.debug.assert(value.len <= std.math.maxInt(u16));
    if (width == 0 or value.len == 0) return;
    try surface.styled_text(x, y, text_width.clip(value, width), .{
        .foreground = foreground,
        .background = background,
        .attributes = attributes,
    });
}

test "list selection background covers text instead of row pixels" {
    const Canvas = @import("../backend/terminal/canvas.zig").TerminalCanvas;
    var canvas = try Canvas.init(std.testing.allocator, 20, 8);
    defer canvas.deinit();
    const color = Color.from_rgb(200, 200, 200);
    const list = List{
        .style = Style.monochrome(color, Color.from_rgb(0, 0, 0)),
        .focused = true,
    };
    try list.draw(
        .{ .canvas = &canvas },
        Rect.init(0, 0, 20, 4),
        &.{ .{ .title = "one" }, .{ .title = "two" } },
        1,
        0,
    );
    var selected_title_found = false;
    for (canvas.text_entries.items) |*entry| {
        if (!std.mem.eql(u8, entry.bytes(), "two")) continue;
        try std.testing.expect(entry.background_color.?.equals(color));
        selected_title_found = true;
    }
    try std.testing.expect(selected_title_found);
    try std.testing.expect(canvas.get_pixel(19, 2).?.equals(Color.from_rgb(0, 0, 0)));
}

test "an indented row starts further in, by exactly its indent" {
    // A contents rail is a list whose rows form a hierarchy, and depth is the
    // only thing distinguishing a subsection from a section.
    const Canvas = @import("../backend/terminal/canvas.zig").TerminalCanvas;
    var canvas = try Canvas.init(std.testing.allocator, 30, 4);
    defer canvas.deinit();
    const list = List{ .style = Style.monochrome(
        Color.from_rgb(200, 200, 200),
        Color.from_rgb(0, 0, 0),
    ) };
    try list.draw(
        .{ .canvas = &canvas },
        Rect.init(0, 0, 30, 2),
        &.{ .{ .title = "section" }, .{ .title = "under", .indent = 2 } },
        0,
        0,
    );
    var flush: ?u16 = null;
    var nested: ?u16 = null;
    for (canvas.text_entries.items) |*entry| {
        if (std.mem.eql(u8, entry.bytes(), "section")) flush = entry.x;
        if (std.mem.eql(u8, entry.bytes(), "under")) nested = entry.x;
    }
    try std.testing.expectEqual(@as(u16, list.visual.title_column), flush.?);
    try std.testing.expectEqual(flush.? + 2, nested.?);
}

test "focused selected detail keeps text and background distinct" {
    const Canvas = @import("../backend/terminal/canvas.zig").TerminalCanvas;
    var canvas = try Canvas.init(std.testing.allocator, 24, 4);
    defer canvas.deinit();
    const background = Color.from_rgb(20, 22, 24);
    const accent = Color.from_rgb(245, 176, 91);
    const selected_background = Color.from_rgb(38, 70, 66);
    var style = Style.monochrome(Color.from_rgb(230, 230, 230), background);
    style.accent = accent;
    style.border = accent;
    style.selected_background = selected_background;
    try (List{ .style = style, .focused = true }).draw(
        .{ .canvas = &canvas },
        Rect.init(0, 0, 24, 2),
        &.{.{ .title = "Bookmark", .detail = "systems" }},
        0,
        0,
    );
    for (canvas.text_entries.items) |entry| {
        if (!std.mem.eql(u8, entry.bytes(), "systems")) continue;
        const detail_background = entry.background_color orelse
            return error.MissingSelectedBackground;
        try std.testing.expect(detail_background.equals(selected_background));
        try std.testing.expect(!entry.foreground_color.equals(detail_background));
        return;
    }
    return error.MissingDetailEntry;
}
