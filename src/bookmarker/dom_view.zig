const std = @import("std");
const markix = @import("markix");
const layout = markix.layout;
const dom = markix.dom;
const widgets = markix.widgets;
const theme = @import("../theme.zig");
const ui = @import("../ui/tokens.zig");
const ui_pane = @import("../ui/pane.zig");
const command_center = @import("../ui/command_center.zig");
const ui_header = @import("../ui/header.zig");
const ui_status = @import("../ui/status.zig");
const ui_help = @import("../ui/help.zig");
const command_policy = @import("../command.zig");
const keymap = @import("../keymap.zig");

const Rect = layout.Rect;
const LayoutElement = layout.LayoutElement;
const NodeIndex = dom.DomTree.NodeIndex;
const Track = layout.flex.Track;
const text_measure = layout.text_measure;

/// Upper bound on rows mounted for one list. Rows are only ever mounted for
/// the visible window, so this tracks terminal height rather than collection
/// size -- a 512 bookmark store still mounts at most a screenful of nodes.
pub const rows_max: u16 = 64;

pub const PaneKind = enum { scopes, bookmarks, preview };

pub const pane_chrome = ui.pane_chrome;
pub const header_chrome = ui.header_chrome;
pub const overlay_chrome = ui.overlay_chrome;
pub const form_chrome = ui.form_chrome;
pub const bookmark_list_visual = ui.item_list_visual;
pub const scope_list_visual = ui.row_list_visual;
pub const command_list_visual = ui.command_list_visual;
const status_visual = ui.status_visual;

const hint = ui_status.hint;

const browse_hints = [_]widgets.StatusHint{
    hint.help,
    hint.focus,
    hint.move,
    hint.activate,
    hint.search,
    hint.command,
    hint.zen,
    hint.add,
};

const help_hints = [_]widgets.StatusHint{hint.close};
const search_hints = ui_status.search_hints;
const command_hints = ui_status.prompt_hints;

const add_hints = [_]widgets.StatusHint{
    hint.field,
    hint.save,
    hint.cancel,
};

const finder_hints = [_]widgets.StatusHint{
    hint.fuzzy,
    hint.category,
    hint.step,
    hint.apply,
    hint.clear,
};

const focus_hints = [_]widgets.StatusHint{
    hint.move,
    hint.find,
    hint.activate,
    hint.command,
    .{ .key = "f", .label = "favourite" },
    .{ .key = "z", .label = "workspace" },
};

const form_fields = [_]widgets.SegmentItem{
    .{ .label = "Title" },
    .{ .label = "URL" },
    .{ .label = "Tags" },
    .{ .label = "Note" },
};

const browser_tabs = [_]widgets.SegmentItem{
    .{ .label = "Browse" },
    .{ .label = "Bookmarks" },
    .{ .label = "Preview" },
};

const form_labels = [_][]const u8{ "TITLE", "URL", "TAGS", "NOTE" };

const link_label = " LINK ";
const tags_label = " TAGS ";
const note_label = " NOTE ";
const summary_label = "SUMMARY";
const focus_label = " ZEN ";

/// What the frame's middle band holds. The mode picks it, and a change means a
/// different tree rather than different props.
const ContentKind = enum { workspace, add, focus };

/// What the header's second row holds.
const HeaderKind = enum { breadcrumb, search, focus };

/// Identity of the mounted tree. The tree is rebuilt only when this changes;
/// otherwise nodes are updated in place so a single edited row stays the only
/// dirty node.
const Shape = struct {
    width: u16 = 0,
    height: u16 = 0,
    content: ContentKind = .workspace,
    header: HeaderKind = .breadcrumb,
    /// Columns the scope name occupies. Header nodes are placed around it, so
    /// a longer name is a different layout rather than different text.
    scope_length: u16 = 0,
    pane_count: u8 = 0,
    panes: [3]PaneKind = .{ .scopes, .bookmarks, .preview },
    scope_rows: u16 = 0,
    bookmark_rows: u16 = 0,
    /// The preview slot shows the command deck instead of the preview.
    deck: bool = false,
    deck_rows: u16 = 0,
    focus_rows: u16 = 0,
    finder: bool = false,
    finder_rows: u16 = 0,
    finder_rect: Rect = Rect.init(0, 0, 0, 0),
    form_rect: Rect = Rect.init(0, 0, 0, 0),
    help: ui_help.Layout = .{},
    help_rect: Rect = Rect.init(0, 0, 0, 0),
    preview: PreviewShape = .{},

    fn equals(self: Shape, other: Shape) bool {
        return std.meta.eql(self, other);
    }
};

/// Which rows the preview pane spends on what. A bookmark without tags does
/// not leave a blank line where they would have been, so the pane's structure
/// follows the bookmark and a selection that changes it rebuilds the pane.
const PreviewShape = struct {
    width: u16 = 0,
    height: u16 = 0,
    selection: bool = false,
    tags: bool = false,
    notes: bool = false,
    /// Rows the description wraps to, or zero when there is none.
    summary_rows: u16 = 0,
    fetched: bool = false,
};

/// Row offsets the preview's nodes are placed at, derived from its shape so
/// building and measuring cannot disagree.
const PreviewRows = struct {
    link: u16,
    tags: u16,
    notes: u16,
    summary: u16,
    summary_text: u16,
    content: u16,
    content_text: u16,
    content_height: u16,
};

fn preview_rows(shape: PreviewShape) PreviewRows {
    var row: u16 = 1;
    const link = row;
    row += 1;
    const tags = row;
    if (shape.tags) row += 1;
    const notes = row;
    if (shape.notes) row += 1;
    // A blank row separates the heading block from the sections below it.
    row += 1;
    const summary = row;
    var summary_text = row;
    if (shape.summary_rows > 0) {
        summary_text = row + 1;
        row = summary_text +| shape.summary_rows +| 1;
    }
    const content = row;
    const content_text = row +| 1;
    return .{
        .link = link,
        .tags = tags,
        .notes = notes,
        .summary = summary,
        .summary_text = summary_text,
        .content = content,
        .content_text = content_text,
        .content_height = shape.height -| content_text,
    };
}

const ListSlot = ui_pane.Slot;

const HeaderSlot = ui_header.Slot;

const PreviewSlot = struct {
    mounted: bool = false,
    panel: NodeIndex = 0,
    empty: NodeIndex = 0,
    title: NodeIndex = 0,
    link: NodeIndex = 0,
    link_value: NodeIndex = 0,
    tags: NodeIndex = 0,
    tags_value: NodeIndex = 0,
    notes: NodeIndex = 0,
    notes_value: NodeIndex = 0,
    summary: NodeIndex = 0,
    summary_text: NodeIndex = 0,
    content: NodeIndex = 0,
    progress: NodeIndex = 0,
    content_text: NodeIndex = 0,
    inner: Rect = Rect.init(0, 0, 0, 0),
};

const DeckSlot = command_center.Slot;
const FinderSlot = command_center.Slot;

const FormSlot = struct {
    mounted: bool = false,
    panel: NodeIndex = 0,
    tabs: NodeIndex = 0,
    grid: NodeIndex = 0,
    /// Label and input alternate, so the input for field `n` is cell `n * 2 + 1`.
    cells: [8]NodeIndex = @splat(0),
};

/// A scope the finder offers as a filter, and where it was drawn.
pub const CategoryRegion = struct {
    rect: Rect = Rect.init(0, 0, 0, 0),
    scope_index: u16 = 0,
};

/// Where this frame put the things a pointer can hit. Filled from node rects
/// once layout has run, so hit boxes and paint can never drift apart.
pub const Regions = struct {
    scopes: ?Rect = null,
    bookmarks: ?Rect = null,
    preview: ?Rect = null,
    command_results: ?Rect = null,
    focus: ?Rect = null,
    focus_modal: ?Rect = null,
    finder_results: ?Rect = null,
    categories: [3]CategoryRegion = @splat(.{}),
    category_count: u8 = 0,
    fields: [4]Rect = @splat(Rect.init(0, 0, 0, 0)),
    field_count: u8 = 0,
};

/// Formatted text referenced by node props, which must outlive the frame.
const Text = struct {
    bytes: [48]u8 = undefined,
    length: u8 = 0,

    fn set(self: *Text, comptime format: []const u8, args: anytype) []const u8 {
        const written = std.fmt.bufPrint(&self.bytes, format, args) catch
            self.bytes[0..0];
        self.length = @intCast(written.len);
        return self.value();
    }

    fn value(self: *const Text) []const u8 {
        return self.bytes[0..self.length];
    }
};

/// Persistent view state. Lives on the Application so the tree -- and with it
/// every node's dirty flag -- survives across frames.
pub const View = struct {
    tree: dom.DomTree = dom.DomTree.init(),
    shape: Shape = .{},
    built: bool = false,

    header: NodeIndex = 0,
    content: NodeIndex = 0,
    workspace: NodeIndex = 0,
    status: NodeIndex = 0,

    header_slot: HeaderSlot = .{},
    scopes: ListSlot = .{},
    bookmarks: ListSlot = .{},
    preview: PreviewSlot = .{},
    deck: DeckSlot = .{},
    focus: ListSlot = .{},
    finder: FinderSlot = .{},
    form: FormSlot = .{},
    help: ui_help.Slot = .{},
    regions: Regions = .{},

    /// Nodes repainted by the last frame. Instrumentation: a row edit should
    /// leave this at one.
    last_painted: u16 = 0,

    /// Set when the store was edited in place. Row props hold slices into
    /// store text, so overwriting a title of the same length changes the
    /// node's old and new value together and no comparison can see it. The
    /// mutating code says so instead.
    stale: bool = false,

    /// Set when the surface no longer holds what this tree last painted --
    /// the reader experience draws over the whole canvas, and dirty flags
    /// only track the tree against its own last paint.
    surface_lost: bool = true,

    /// Canvas size this tree last painted against, in pixels. A resize wipes
    /// the canvas, and rounding pixels to rows can hide that from the shape:
    /// 41 and 42 pixels are both 21 rows.
    canvas_width: u16 = 0,
    canvas_height: u16 = 0,

    /// Text held for the frame's props. Slices into these outlive the frame
    /// because the view does.
    scope_counts: [rows_max]Text = @splat(.{}),
    /// Held for the status line's props, which point into it.
    hint_buffer: [16]widgets.StatusHint = undefined,
    header_meta: Text = .{},
    header_count: Text = .{},
    scopes_meta: Text = .{},
    bookmarks_meta: Text = .{},
    focus_meta: Text = .{},
    deck_meta: Text = .{},
    progress: Text = .{},

    /// The finder's filter categories, held because the segmented node's props
    /// point at them.
    categories: [3]widgets.SegmentItem = @splat(.{ .label = "" }),
    category_scopes: [3]u16 = @splat(0),
    category_count: u8 = 0,

    pub fn node_rect(self: *View, index: NodeIndex) Rect {
        const node = self.tree.get(index) orelse return Rect.init(0, 0, 0, 0);
        return node.rect();
    }

    fn content_rect(self: *View, index: NodeIndex) Rect {
        const node = self.tree.get(index) orelse return Rect.init(0, 0, 0, 0);
        return node.content_rect();
    }

    /// Call after mutating bookmark text behind a mounted row.
    pub fn invalidate(self: *View) void {
        self.stale = true;
    }

    /// Call when something else painted over the canvas, so the next frame
    /// redraws in full rather than trusting the previous one.
    pub fn invalidate_surface(self: *View) void {
        self.surface_lost = true;
    }

    /// Notices a resize, which resets the canvas out from under the tree.
    pub fn observe_canvas(self: *View, width: u16, height: u16) void {
        if (self.canvas_width == width and self.canvas_height == height) return;
        self.canvas_width = width;
        self.canvas_height = height;
        self.surface_lost = true;
    }
};

/// Recomputes the shape and rebuilds the tree when it differs. Returns whether
/// a rebuild happened, which forces a full repaint for that frame.
pub fn sync(view: *View, application: anytype, bounds: Rect) !bool {
    const shape = measure(application, bounds);
    const rebuilt = !view.built or !view.shape.equals(shape);
    if (rebuilt) {
        try build(view, shape);
        view.shape = shape;
        view.built = true;
    }

    // Layout runs before props are written. Nothing in the layout depends on
    // per-frame props, and the pane rects decide how many rows fit -- which
    // can move the selection. Writing props first would paint the frame from
    // a scroll position the very same frame is about to correct.
    try view.tree.evaluate(bounds);
    capture_rects(view);
    apply_viewport(view, application);

    if (view.stale) {
        mark_rows_dirty(view, &view.scopes);
        mark_rows_dirty(view, &view.bookmarks);
        mark_rows_dirty(view, &view.focus);
        mark_rows_dirty(view, &view.finder.results);
        view.stale = false;
    }
    const full = rebuilt or view.surface_lost;
    if (view.surface_lost) {
        view.tree.mark_all_dirty();
        view.surface_lost = false;
    }
    try update(view, application);
    capture_regions(view);
    return full;
}

// Measuring. The shape is derived before the tree exists, so row counts and
// placements are known to whoever builds it.

fn measure(application: anytype, bounds: Rect) Shape {
    var shape = Shape{
        .width = bounds.width,
        .height = bounds.height,
        .content = content_kind(application),
        .header = header_kind(application),
        .scope_length = @intCast(scope_name(application).len),
    };
    const rows = frame_rows(bounds);
    const content = rows[1];
    switch (shape.content) {
        .workspace => measure_workspace(&shape, application, content),
        .add => shape.form_rect = form_rect(content),
        .focus => measure_focus(&shape, application, content),
    }
    // The sheet floats over whatever the mode was already showing, so it is
    // measured on top rather than instead of it.
    if (application.help_open) {
        shape.help_rect = ui_help.rect_for(content);
        shape.help = ui_help.layout_for(
            shape.help_rect,
            keymap.row_count(&keymap.bookmarker),
        );
    }
    return shape;
}

fn measure_workspace(shape: *Shape, application: anytype, content: Rect) void {
    shape.pane_count = workspace_panes(application, content.width, &shape.panes);
    shape.deck = application.mode == .command;
    var pane_rects: [3]Rect = @splat(Rect.init(0, 0, 0, 0));
    var tracks: [3]Track = undefined;
    const used = workspace_tracks(shape.pane_count, &tracks);
    layout.flex.layout(content, .row, 1, used, pane_rects[0..shape.pane_count]) catch
        return;
    for (shape.panes[0..shape.pane_count], 0..) |kind, index| {
        const pane = pane_rects[index];
        switch (kind) {
            .scopes => shape.scope_rows = visible_rows(
                pane,
                scope_list_visual.row_height,
            ),
            .bookmarks => shape.bookmark_rows = visible_rows(
                pane,
                bookmark_list_visual.row_height,
            ),
            .preview => if (shape.deck) {
                shape.deck_rows = deck_rows(pane);
            } else {
                shape.preview = measure_preview(application, pane);
            },
        }
    }
}

fn measure_focus(shape: *Shape, application: anytype, content: Rect) void {
    shape.focus_rows = visible_rows(content, bookmark_list_visual.row_height);
    if (!application.focus_search_open) return;
    const rect = focus_finder_rect(content);
    // A band too small to hold a dialog holds the library alone.
    if (rect.width == 0 or rect.height == 0) return;
    shape.finder = true;
    shape.finder_rect = rect;
    const inner = widgets.panel_content_rect(overlay_chrome, rect);
    shape.finder_rows = @min(
        @divFloor(inner.height -| finder_results_row, bookmark_list_visual.row_height),
        rows_max,
    );
}

fn measure_preview(application: anytype, pane: Rect) PreviewShape {
    const inner = widgets.panel_content_rect(pane_chrome, pane);
    var shape = PreviewShape{ .width = inner.width, .height = inner.height };
    const bookmark = application.selected_bookmark() orelse return shape;
    shape.selection = true;
    shape.tags = !bookmark.tags.is_empty();
    shape.notes = !bookmark.notes.is_empty();
    shape.fetched = !bookmark.preview.is_empty();
    if (!bookmark.description.is_empty()) {
        shape.summary_rows = @min(
            text_measure.wrapped_rows(bookmark.description.bytes(), inner.width),
            inner.height,
        );
    }
    return shape;
}

/// The rows the frame divides into: a two row header, the content band, and a
/// status line. Measured with the same maths the tree lays itself out by.
fn frame_rows(bounds: Rect) [3]Rect {
    var tracks = [_]Track{
        .{ .cells = 2 },
        .{ .fraction = 1 },
        .{ .cells = 1 },
    };
    var rows: [3]Rect = @splat(Rect.init(0, 0, 0, 0));
    layout.flex.layout(bounds, .column, 0, tracks[0..], rows[0..]) catch return rows;
    return rows;
}

fn content_kind(application: anytype) ContentKind {
    return switch (application.mode) {
        .add => .add,
        .focus => .focus,
        else => .workspace,
    };
}

fn header_kind(application: anytype) HeaderKind {
    return switch (application.mode) {
        .search => .search,
        .focus => .focus,
        else => .breadcrumb,
    };
}

fn workspace_panes(application: anytype, width: u16, out: *[3]PaneKind) u8 {
    if (width >= 110) {
        out[0] = .scopes;
        out[1] = .bookmarks;
        out[2] = .preview;
        return 3;
    }
    if (width >= 76) {
        out[0] = if (application.browser_focus == .scopes) .scopes else .bookmarks;
        out[1] = .preview;
        out[2] = .preview;
        return 2;
    }
    out[0] = narrow_pane(application);
    out[1] = .preview;
    out[2] = .preview;
    return 1;
}

fn narrow_pane(application: anytype) PaneKind {
    if (application.mode == .command) return .preview;
    return switch (application.browser_focus) {
        .scopes => .scopes,
        .bookmarks => if (application.narrow_preview) .preview else .bookmarks,
        .preview => .preview,
    };
}

fn workspace_tracks(pane_count: u8, tracks: *[3]Track) []Track {
    switch (pane_count) {
        3 => {
            tracks[0] = .{ .cells = 20 };
            tracks[1] = .{ .fraction = 2 };
            tracks[2] = .{ .fraction = 3 };
        },
        2 => {
            tracks[0] = .{ .fraction = 2 };
            tracks[1] = .{ .fraction = 3 };
        },
        else => tracks[0] = .{ .fraction = 1 },
    }
    return tracks[0..pane_count];
}

/// Rows a pane can show, derived from the panel's content box so it matches
/// what the renderer will actually lay out.
fn visible_rows(pane: Rect, row_height: u8) u16 {
    if (row_height == 0) return 0;
    const inner = widgets.panel_content_rect(pane_chrome, pane);
    return @min(@divFloor(inner.height, row_height), rows_max);
}

fn deck_rows(pane: Rect) u16 {
    const inner = widgets.panel_content_rect(overlay_chrome, pane);
    const results = inner.height -| deck_results_row;
    return @min(@max(@divFloor(results, command_list_visual.row_height), 1), rows_max);
}

pub fn focus_finder_rect(bounds: Rect) Rect {
    return ui.overlay_rect(bounds, 84, 17);
}

fn form_rect(content: Rect) Rect {
    const width = @min(content.width, 78);
    const height = @min(content.height, 12);
    return Rect.init(
        content.x + (content.width - width) / 2,
        content.y + (content.height - height) / 2,
        width,
        height,
    );
}

// Building. Runs only when the shape changed, so everything here may assume it
// is starting from an empty tree.

/// Row the command deck's results start on, below the input and a blank row.
const deck_results_row: u16 = 2;
/// Row the finder's results start on, below the input, a blank row, the
/// category filters and another blank row.
const finder_results_row: u16 = 4;
const finder_filter_row: u16 = 2;

fn build(view: *View, shape: Shape) !void {
    view.tree.reset();
    view.header_slot = .{};
    view.scopes = .{};
    view.bookmarks = .{};
    view.preview = .{};
    view.deck = .{};
    view.focus = .{};
    view.finder = .{};
    view.form = .{};
    view.help = .{};

    const root = try view.tree.set_root(.{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = try LayoutElement.flex(.column, 0, &.{
            .{ .cells = 2 },
            .{ .fraction = 1 },
            .{ .cells = 1 },
        }),
    });
    view.header_slot = try ui_header.mount(
        &view.tree,
        root,
        header_slot_kind(shape.header),
        shape.width,
        shape.scope_length,
        label_width(focus_label),
    );
    view.header = view.header_slot.panel;
    // The content band is always a free container so anything floating over it
    // -- the finder, the help sheet -- is a sibling of what it covers. The
    // workspace's own flex row is nested inside rather than being the band.
    view.content = try view.tree.append_child(root, .{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = LayoutElement.free(),
    });
    view.status = try ui_status.mount(&view.tree, root);

    if (shape.help.rows > 0) {
        try build_help(view, shape);
        return;
    }
    switch (shape.content) {
        .workspace => try build_workspace(view, shape),
        .add => try build_form(view, shape),
        .focus => try build_focus(view, shape),
    }
}

fn workspace_layout(shape: Shape) !LayoutElement {
    var tracks: [3]Track = undefined;
    var element = try LayoutElement.flex(
        .row,
        1,
        workspace_tracks(shape.pane_count, &tracks),
    );
    const band = content_band(shape);
    element.placement = .{
        .x = 0,
        .y = 0,
        .width = band.width,
        .height = band.height,
    };
    return element;
}

fn header_slot_kind(kind: HeaderKind) ui_header.Kind {
    return switch (kind) {
        .breadcrumb => .breadcrumb,
        .search => .search,
        .focus => .scope,
    };
}

fn build_workspace(view: *View, shape: Shape) !void {
    view.workspace = try view.tree.append_child(view.content, .{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = try workspace_layout(shape),
    });
    for (shape.panes[0..shape.pane_count]) |kind| {
        switch (kind) {
            .scopes => try mount_list(
                view,
                view.workspace,
                &view.scopes,
                shape.scope_rows,
                scope_list_visual,
            ),
            .bookmarks => try mount_list(
                view,
                view.workspace,
                &view.bookmarks,
                shape.bookmark_rows,
                bookmark_list_visual,
            ),
            .preview => if (shape.deck)
                try build_deck(view, shape)
            else
                try build_preview(view, shape),
        }
    }
}

fn build_preview(view: *View, shape: Shape) !void {
    const panel = try view.tree.append_child(view.workspace, .{
        .kind = .panel,
        .props = .{ .panel = .{ .chrome = pane_chrome, .style = theme.panel_style } },
        .layout = LayoutElement.free(),
    });
    view.preview = .{ .mounted = true, .panel = panel };
    const measured = shape.preview;
    if (!measured.selection) {
        view.preview.empty = try place_badge(view, panel, 0, 0, no_selection_width);
        return;
    }
    const rows = preview_rows(measured);
    view.preview.title = try place_label(view, panel, 0, 0, measured.width);
    view.preview.link = try place_badge(view, panel, 0, rows.link, label_width(link_label));
    view.preview.link_value = try place_label(
        view,
        panel,
        label_width(link_label) + 1,
        rows.link,
        measured.width -| (label_width(link_label) + 1),
    );
    if (measured.tags) {
        view.preview.tags = try place_badge(
            view,
            panel,
            0,
            rows.tags,
            label_width(tags_label),
        );
        view.preview.tags_value = try place_label(
            view,
            panel,
            label_width(tags_label) + 1,
            rows.tags,
            measured.width -| (label_width(tags_label) + 1),
        );
    }
    if (measured.notes) {
        view.preview.notes = try place_badge(
            view,
            panel,
            0,
            rows.notes,
            label_width(note_label),
        );
        view.preview.notes_value = try place_label(
            view,
            panel,
            label_width(note_label) + 1,
            rows.notes,
            measured.width -| (label_width(note_label) + 1),
        );
    }
    if (measured.summary_rows > 0) {
        view.preview.summary = try place_badge(
            view,
            panel,
            0,
            rows.summary,
            label_width(summary_label),
        );
        view.preview.summary_text = try place_wrapped(
            view,
            panel,
            0,
            rows.summary_text,
            measured.width,
            measured.summary_rows,
        );
    }
    view.preview.content = try place_badge(
        view,
        panel,
        0,
        rows.content,
        label_width(if (measured.fetched) "CONTENT" else "NOT FETCHED"),
    );
    view.preview.progress = try place_label(
        view,
        panel,
        measured.width -| progress_width,
        rows.content,
        progress_width,
    );
    view.preview.content_text = try place_wrapped(
        view,
        panel,
        0,
        rows.content_text,
        measured.width,
        @max(rows.content_height, 1),
    );
}

fn build_deck(view: *View, shape: Shape) !void {
    view.deck = try command_center.mount(&view.tree, view.workspace, .{
        .width = shape.width,
        .rows = shape.deck_rows,
    });
}

fn build_focus(view: *View, shape: Shape) !void {
    const content = content_band(shape);
    if (content.width == 0 or content.height == 0) return;
    // The band is a free container, so the library states the box it fills
    // before it divides that box up for its list.
    var element = try LayoutElement.flex(.column, 0, &.{.{ .fraction = 1 }});
    element.placement = .{
        .x = 0,
        .y = 0,
        .width = content.width,
        .height = content.height,
    };
    const panel = try view.tree.append_child(view.content, .{
        .kind = .panel,
        .props = .{ .panel = .{ .chrome = pane_chrome, .style = theme.panel_style } },
        .layout = element,
        .focused = true,
    });
    view.focus.panel = panel;
    view.focus.list = try view.tree.append_child(panel, .{
        .kind = .list,
        .props = .{ .list = .{
            .style = theme.panel_style,
            .visual = bookmark_list_visual,
        } },
        .layout = LayoutElement.leaf(),
    });
    view.focus.mounted = true;
    try mount_rows(view, &view.focus, shape.focus_rows);
    if (!shape.finder) return;
    try build_finder(view, shape);
}

fn build_finder(view: *View, shape: Shape) !void {
    const content = content_band(shape);
    const rect = shape.finder_rect;
    const inner = widgets.panel_content_rect(overlay_chrome, rect);
    view.finder = try command_center.mount(&view.tree, view.content, .{
        .width = inner.width,
        .rows = shape.finder_rows,
        .filters = true,
        .placement = Rect.init(
            rect.x -| content.x,
            rect.y -| content.y,
            rect.width,
            rect.height,
        ),
    });
}

fn build_help(view: *View, shape: Shape) !void {
    const content = content_band(shape);
    const rect = shape.help_rect;
    view.help = try ui_help.mount(
        &view.tree,
        view.content,
        Rect.init(
            rect.x -| content.x,
            rect.y -| content.y,
            rect.width,
            rect.height,
        ),
        shape.help,
    );
}

fn build_form(view: *View, shape: Shape) !void {
    const content = content_band(shape);
    const rect = shape.form_rect;
    if (rect.width == 0 or rect.height == 0) return;
    const panel = try view.tree.append_child(view.content, .{
        .kind = .panel,
        .props = .{ .panel = .{ .chrome = form_chrome, .style = theme.focused_panel } },
        .layout = LayoutElement.placed_free(
            rect.x -| content.x,
            rect.y -| content.y,
            rect.width,
            rect.height,
        ),
        .focused = true,
    });
    const inner = widgets.panel_content_rect(form_chrome, rect);
    view.form = .{ .mounted = true, .panel = panel };
    view.form.tabs = try view.tree.append_child(panel, .{
        .kind = .segmented,
        .props = .{ .segmented = .{} },
        .layout = LayoutElement.placed(0, 0, inner.width, 1),
    });
    if (inner.height <= 2) return;
    view.form.grid = try view.tree.append_child(panel, .{
        .kind = .container,
        .props = .{ .container = {} },
        .layout = grid_layout(inner.width, inner.height - 2),
    });
    for (0..8) |cell| {
        view.form.cells[cell] = try view.tree.append_child(view.form.grid, .{
            .kind = if (cell % 2 == 0) .label else .text_input,
            .props = if (cell % 2 == 0)
                .{ .label = .{} }
            else
                .{ .text_input = .{} },
            .layout = LayoutElement.leaf(),
        });
    }
}

/// A label column and a field column, one row per field. Placed by hand: the
/// grid divides a rect up, so it needs one of its own inside the free panel.
fn grid_layout(width: u16, height: u16) LayoutElement {
    std.debug.assert(height > 0);
    var element = LayoutElement.grid(
        1,
        1,
        &.{ .{ .cells = 8 }, .{ .fraction = 1 } },
        &.{
            .{ .cells = 1 },
            .{ .cells = 1 },
            .{ .cells = 1 },
            .{ .cells = 1 },
        },
    ) catch unreachable;
    element.placement = .{ .x = 0, .y = 2, .width = width, .height = height };
    return element;
}

const progress_width: u16 = 12;
const filter_badge_width: u16 = 8;
const no_selection_width: u16 = 14;

/// The middle band of the frame, where content lives. Placements inside it are
/// relative to it, so its origin is what turns an absolute rect into one.
fn content_band(shape: Shape) Rect {
    return frame_rows(Rect.init(0, 0, shape.width, shape.height))[1];
}

fn label_width(text: []const u8) u16 {
    return @intCast(text.len);
}

fn place_label(
    view: *View,
    parent: NodeIndex,
    x: u16,
    y: u16,
    width: u16,
) !NodeIndex {
    return view.tree.append_child(parent, .{
        .kind = .label,
        .props = .{ .label = .{} },
        .layout = LayoutElement.placed(x, y, width, 1),
    });
}

fn place_wrapped(
    view: *View,
    parent: NodeIndex,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
) !NodeIndex {
    return view.tree.append_child(parent, .{
        .kind = .label,
        .props = .{ .label = .{ .wrap = true } },
        .layout = LayoutElement.placed(x, y, width, height),
    });
}

fn place_badge(
    view: *View,
    parent: NodeIndex,
    x: u16,
    y: u16,
    width: u16,
) !NodeIndex {
    return view.tree.append_child(parent, .{
        .kind = .badge,
        .props = .{ .badge = .{} },
        .layout = LayoutElement.placed(x, y, width, 1),
    });
}

fn mount_list(
    view: *View,
    parent: NodeIndex,
    slot: *ListSlot,
    rows: u16,
    visual: widgets.ListVisual,
) !void {
    slot.panel = try view.tree.append_child(parent, .{
        .kind = .panel,
        .props = .{ .panel = .{ .chrome = pane_chrome, .style = theme.panel_style } },
        .layout = try LayoutElement.flex(.column, 0, &.{.{ .fraction = 1 }}),
    });
    slot.list = try view.tree.append_child(slot.panel, .{
        .kind = .list,
        .props = .{ .list = .{ .style = theme.panel_style, .visual = visual } },
        .layout = LayoutElement.leaf(),
    });
    slot.mounted = true;
    try mount_rows(view, slot, rows);
}

fn mount_rows(view: *View, slot: *ListSlot, rows: u16) !void {
    std.debug.assert(slot.mounted);
    std.debug.assert(rows <= rows_max);
    slot.first_row = view.tree.node_count;
    var index: u16 = 0;
    while (index < rows) : (index += 1) {
        _ = try view.tree.append_child(slot.list, .{
            .kind = .list_item,
            .props = .{ .list_item = .{} },
            .layout = LayoutElement.leaf(),
        });
    }
    slot.row_count = rows;
}

fn shadow_style() markix.Style {
    var style = theme.panel_style;
    style.background = theme.shadow;
    return style;
}

// Updating. Runs every frame; anything written here is compared against what
// the node already holds, so only what actually changed repaints.

fn update(view: *View, application: anytype) !void {
    update_header(view, application);
    update_status(view, application);
    if (view.scopes.mounted) update_scopes(view, application);
    if (view.bookmarks.mounted) update_bookmarks(view, application);
    if (view.preview.mounted) update_preview(view, application);
    if (view.deck.mounted) update_deck(view, application);
    if (view.focus.mounted) update_focus(view, application);
    if (view.finder.mounted) update_finder(view, application);
    if (view.form.mounted) update_form(view, application);
    if (view.help.mounted) {
        ui_help.update(&view.tree, &view.help, &keymap.bookmarker, "KEYBOARD HELP");
    }
}

fn update_header(view: *View, application: anytype) void {
    const meta = view.header_meta.set(
        "{d} SAVED  {d} SHOWN",
        .{ application.store.count, application.filtered_count },
    );
    const body: ui_header.Body = switch (view.shape.header) {
        .search => .{ .search = .{
            .prompt = " SEARCH ",
            .placeholder = "title, URL, tag, note, or page text",
            .value = application.search.value(),
            .cursor = application.search.cursor,
        } },
        .focus => .{ .scope = .{
            .badge = focus_label,
            .name = scope_name(application),
            .detail = view.header_count.set(
                "/  {d} MATCHES",
                .{application.filtered_count},
            ),
            .accent = theme.accent_warm,
        } },
        .breadcrumb => .{ .breadcrumb = .{
            .scope = scope_name(application),
            .tabs = &browser_tabs,
            .selected = focus_index(application.browser_focus),
            .accent = focus_accent(application.browser_focus),
        } },
    };
    ui_header.update(&view.tree, &view.header_slot, .{
        .title = "BOOKMARKS",
        .meta = meta,
        .body = body,
    });
}

fn update_status(view: *View, application: anytype) void {
    // An overlay names itself in its own title bar, so the status line does not
    // repeat it; it keeps showing what the application last had to say.
    const message = application.message.bytes();
    const own: []const widgets.StatusHint = if (application.help_open)
        &help_hints
    else switch (application.mode) {
        .browse, .confirm_delete => &browse_hints,
        .search => &search_hints,
        .add => &add_hints,
        .command => &command_hints,
        .focus => if (application.focus_search_open) &finder_hints else &focus_hints,
    };
    ui_status.update(&view.tree, view.status, .{
        .message = message,
        .hints = ui_status.with_trailer(&view.hint_buffer, own),
        .warning = application.mode == .confirm_delete,
    });
}

fn update_scopes(view: *View, application: anytype) void {
    const focused = application.browser_focus == .scopes;
    const style = theme.pane_style(theme.accent_cool, focused);
    const count = scope_item_count(application);
    const meta = view.scopes_meta.set("{d} VIEWS", .{count});
    view.tree.set_focused(view.scopes.panel, focused);
    view.tree.set_focused(view.scopes.list, focused);
    view.tree.set_props(view.scopes.panel, .{ .panel = .{
        .style = style,
        .chrome = pane_chrome,
        .title = "BROWSE",
        .meta = meta,
    } });
    view.tree.set_props(view.scopes.list, .{ .list = .{
        .style = style,
        .empty_text = "No views",
        .visual = scope_list_visual,
        .item_count = count,
        .selected = application.scope_cursor -| application.scope_scroll,
    } });
    var row: u16 = 0;
    while (row < view.scopes.row_count) : (row += 1) {
        const item_index = application.scope_scroll + row;
        const node = view.scopes.first_row + row;
        if (item_index >= count) {
            view.tree.set_props(node, .{ .list_item = .{} });
            continue;
        }
        view.tree.set_props(node, .{ .list_item = .{
            .title = scope_item_name(application, item_index),
            .detail = view.scope_counts[row].set(
                "{d}",
                .{scope_bookmark_count(application, item_index)},
            ),
            .marker = if (item_index < 2) ' ' else '#',
            .selected = item_index == application.scope_cursor,
        } });
    }
}

fn update_bookmarks(view: *View, application: anytype) void {
    const focused = application.browser_focus == .bookmarks;
    const style = theme.pane_style(theme.accent_warm, focused);
    const position = if (application.filtered_count == 0) 0 else application.selected + 1;
    const meta = view.bookmarks_meta.set(
        "{d}/{d}",
        .{ position, application.filtered_count },
    );
    view.tree.set_focused(view.bookmarks.panel, focused);
    view.tree.set_focused(view.bookmarks.list, focused);
    view.tree.set_props(view.bookmarks.panel, .{ .panel = .{
        .style = style,
        .chrome = pane_chrome,
        .title = "BOOKMARKS",
        .meta = meta,
    } });
    update_bookmark_list(view, application, &view.bookmarks, style, "");
}

fn update_focus(view: *View, application: anytype) void {
    const style = theme.pane_style(theme.accent_warm, true);
    const position = if (application.filtered_count == 0) 0 else application.selected + 1;
    const meta = view.focus_meta.set(
        "{d}/{d}",
        .{ position, application.filtered_count },
    );
    view.tree.set_focused(view.focus.panel, true);
    view.tree.set_focused(view.focus.list, true);
    view.tree.set_props(view.focus.panel, .{ .panel = .{
        .style = style,
        .chrome = pane_chrome,
        .title = "ZEN LIBRARY",
        .meta = meta,
    } });
    update_bookmark_list(view, application, &view.focus, style, application.search.value());
}

/// Writes a window of bookmarks into a list's mounted rows.
///
/// The rows are the window, not the collection, so the list's own scroll stays
/// at zero: it is the row props that move. `selected` is the window-relative
/// index for the same reason.
fn update_bookmark_list(
    view: *View,
    application: anytype,
    slot: *ListSlot,
    style: markix.Style,
    highlight: []const u8,
) void {
    var safe = highlight;
    if (safe.len > 0) {
        var scan = application.scroll;
        while (scan < application.filtered_count) : (scan += 1) {
            const item = &application.store.items[application.filtered[scan]];
            if (!ui_pane.is_ascii(item.title.bytes())) {
                safe = "";
                break;
            }
        }
    }
    view.tree.set_props(slot.list, .{ .list = .{
        .style = style,
        .empty_text = empty_bookmark_text(application),
        .highlight_query = safe,
        .match_foreground = if (safe.len > 0) theme.command else null,
        .visual = bookmark_list_visual,
        .item_count = application.filtered_count,
        .selected = application.selected -| application.scroll,
    } });
    var row: u16 = 0;
    while (row < slot.row_count) : (row += 1) {
        const item_index = application.scroll + row;
        const node = slot.first_row + row;
        if (item_index >= application.filtered_count) {
            view.tree.set_props(node, .{ .list_item = .{} });
            continue;
        }
        const bookmark = &application.store.items[application.filtered[item_index]];
        const host = bookmark.host();
        view.tree.set_props(node, .{ .list_item = .{
            .title = bookmark.title.bytes(),
            .detail = if (std.ascii.eqlIgnoreCase(bookmark.title.bytes(), host))
                ""
            else
                host,
            .subtitle = if (!bookmark.tags.is_empty())
                bookmark.tags.bytes()
            else
                bookmark.notes.bytes(),
            .marker = if (bookmark.favorite) '*' else ' ',
            .selected = item_index == application.selected,
        } });
    }
}

fn update_preview(view: *View, application: anytype) void {
    const focused = application.browser_focus == .preview;
    const style = theme.pane_style(theme.accent, focused);
    view.tree.set_focused(view.preview.panel, focused);
    view.tree.set_props(view.preview.panel, .{ .panel = .{
        .style = style,
        .chrome = pane_chrome,
        .title = "PREVIEW",
    } });
    if (!view.shape.preview.selection) {
        view.tree.set_props(view.preview.empty, .{ .badge = .{
            .text = " NO SELECTION ",
            .style = .{
                .foreground = theme.muted,
                .background = theme.panel_alt,
                .attributes = .{},
                .padding = 0,
            },
        } });
        return;
    }
    // The shape was measured from this same selection, so the nodes the pane
    // holds are the ones this bookmark needs.
    const bookmark = application.selected_bookmark() orelse return;
    view.tree.set_props(view.preview.title, .{ .label = .{
        .text = bookmark.title.bytes(),
        .style = strong_style(),
    } });
    set_field(view, view.preview.link, view.preview.link_value, .{
        .label = link_label,
        .label_color = theme.accent_cool,
        .value = bookmark.url.bytes(),
        .value_color = theme.muted,
        .attributes = .{ .underline = true },
    });
    if (view.shape.preview.tags) {
        set_field(view, view.preview.tags, view.preview.tags_value, .{
            .label = tags_label,
            .label_color = theme.accent_warm,
            .value = bookmark.tags.bytes(),
            .value_color = theme.accent_warm,
            .attributes = .{ .bold = true },
        });
    }
    if (view.shape.preview.notes) {
        set_field(view, view.preview.notes, view.preview.notes_value, .{
            .label = note_label,
            .label_color = theme.accent,
            .value = bookmark.notes.bytes(),
            .value_color = theme.foreground,
            .attributes = .{},
        });
    }
    if (view.shape.preview.summary_rows > 0) {
        view.tree.set_props(view.preview.summary, .{ .badge = .{
            .text = summary_label,
            .style = section_badge(),
        } });
        view.tree.set_props(view.preview.summary_text, .{ .label = .{
            .text = bookmark.description.bytes(),
            .style = theme.panel_style,
            .wrap = true,
        } });
    }
    update_preview_content(view, application, bookmark);
}

fn update_preview_content(view: *View, application: anytype, bookmark: anytype) void {
    const text = bookmark.preview.bytes();
    const width = view.shape.preview.width;
    const rows = preview_rows(view.shape.preview);
    const line_count = wrapped_line_count(text, width);
    application.set_preview_metrics(line_count, rows.content_height);
    view.tree.set_props(view.preview.content, .{ .badge = .{
        .text = if (view.shape.preview.fetched) "CONTENT" else "NOT FETCHED",
        .style = section_badge(),
    } });
    // Right aligned by padding rather than by placement: where the label sits
    // is layout, and layout may not depend on how many digits a count has.
    var counter: [24]u8 = undefined;
    const position = std.fmt.bufPrint(&counter, "{d}/{d}", .{
        @min(application.preview_scroll +| 1, line_count),
        line_count,
    }) catch "";
    const progress = if (line_count == 0)
        ""
    else
        view.progress.set("{s: >11} ", .{position});
    view.tree.set_props(view.preview.progress, .{ .label = .{
        .text = progress,
        .style = progress_style(),
    } });
    view.tree.set_props(view.preview.content_text, .{ .label = .{
        .text = preview_window(text, width, application.preview_scroll),
        .style = theme.panel_style,
        .wrap = true,
    } });
}

fn update_deck(view: *View, application: anytype) void {
    if (application.active_argument()) |argument| {
        command_center.update_surface(
            &view.tree,
            &view.deck,
            command_policy.argument_config(
                application.active_label(),
                argument.placeholder,
            ),
            application.command.query(),
            application.command.input.cursor,
        );
        ui_pane.update_list(&view.tree, &view.deck.results, .{
            .role = .command,
            .focused = true,
            .empty_text = "",
            .visual = ui.command_list_visual,
        });
        ui_pane.clear_rows_from(&view.tree, &view.deck.results, 0);
        return;
    }
    const meta = view.deck_meta.set("{d} RESULTS", .{application.command.count});
    command_center.update(
        &view.tree,
        &view.deck,
        &application.command,
        application,
        command_policy.deck_config(meta, application.command.query()),
    );
}

/// The finder is the command centre's surface over the bookmark list itself:
/// it narrows the collection in place rather than gathering results of its
/// own, so the surface is shared but the rows underneath stay the library's.
fn update_finder(view: *View, application: anytype) void {
    const selected = update_categories(view, application);
    command_center.update_surface(
        &view.tree,
        &view.finder,
        command_policy.finder_config(
            "FIND BOOKMARKS",
            scope_name(application),
            "Fuzzy search titles, URLs, tags, notes, and page text",
            .{
                .items = view.categories[0..view.category_count],
                .selected = selected,
                .label = command_policy.finder.filter_label,
            },
        ),
        application.search.value(),
        application.search.cursor,
    );
    update_bookmark_list(
        view,
        application,
        &view.finder.results,
        theme.command_panel,
        application.search.value(),
    );
}

/// The three scopes the finder offers: the one before the cursor, the cursor's
/// own, and the one after. With only the two built in scopes there is nothing
/// to rotate through, so both are shown as they are.
fn update_categories(view: *View, application: anytype) u16 {
    const scope_count = scope_item_count(application);
    if (scope_count == 2) {
        view.categories[0] = .{ .label = scope_item_name(application, 0) };
        view.categories[1] = .{ .label = scope_item_name(application, 1) };
        view.category_scopes[0] = 0;
        view.category_scopes[1] = 1;
        view.category_count = 2;
        return application.scope_cursor;
    }
    const cursor = application.scope_cursor;
    const previous = if (cursor == 0) scope_count - 1 else cursor - 1;
    const next = if (cursor + 1 == scope_count) 0 else cursor + 1;
    view.categories[0] = .{ .label = scope_item_name(application, previous) };
    view.categories[1] = .{ .label = scope_item_name(application, cursor) };
    view.categories[2] = .{ .label = scope_item_name(application, next) };
    view.category_scopes[0] = previous;
    view.category_scopes[1] = cursor;
    view.category_scopes[2] = next;
    view.category_count = 3;
    return 1;
}

fn update_form(view: *View, application: anytype) void {
    view.tree.set_props(view.form.panel, .{ .panel = .{
        .style = theme.focused_panel,
        .chrome = form_chrome,
        .title = "NEW BOOKMARK",
    } });
    view.tree.set_props(view.form.tabs, .{ .segmented = .{
        .active_style = .{
            .foreground = theme.inverse_foreground,
            .background = theme.accent_warm,
            .attributes = .{ .bold = true },
        },
        .idle_style = .{
            .foreground = theme.muted,
            .background = theme.panel_alt,
            .attributes = .{ .dim = true },
        },
        .gap = 1,
        .items = &form_fields,
        .selected = field_index(application.field),
    } });
    if (view.form.grid == 0) return;
    inline for (.{ "title", "url", "tags", "notes" }, 0..) |name, index| {
        const focused = field_index(application.field) == index;
        view.tree.set_props(view.form.cells[index * 2], .{ .label = .{
            .text = form_labels[index],
            .style = theme.panel_style,
            .muted = true,
        } });
        view.tree.set_focused(view.form.cells[index * 2 + 1], focused);
        view.tree.set_props(view.form.cells[index * 2 + 1], .{ .text_input = .{
            .style = if (focused) theme.focused_field else theme.panel_style,
            .placeholder = form_placeholders[index],
            .value = @field(application, name).value(),
            .cursor = @field(application, name).cursor,
        } });
    }
}

const form_placeholders = [_][]const u8{
    "Page title",
    "https://",
    "design, systems, reading",
    "Why this is worth keeping",
};

const FieldRow = struct {
    label: []const u8,
    label_color: markix.Color,
    value: []const u8,
    value_color: markix.Color,
    attributes: markix.Attributes,
};

fn set_field(view: *View, label: NodeIndex, value: NodeIndex, row: FieldRow) void {
    view.tree.set_props(label, .{ .badge = .{
        .text = row.label,
        .style = .{
            .foreground = theme.inverse_foreground,
            .background = row.label_color,
            .attributes = .{},
            .padding = 0,
        },
    } });
    var style = theme.panel_style;
    style.foreground = row.value_color;
    view.tree.set_props(value, .{ .label = .{ .text = row.value, .style = style } });
}

fn section_badge() widgets.BadgeStyle {
    return .{
        .foreground = theme.muted,
        .background = theme.panel_alt,
        .attributes = .{},
        .padding = 0,
    };
}

fn progress_style() markix.Style {
    var style = theme.panel_style;
    style.foreground = theme.accent;
    style.background = theme.panel_alt;
    return style;
}

fn strong_style() markix.Style {
    var style = theme.panel_style;
    style.foreground = theme.foreground_strong;
    return style;
}

/// Tells the application how many rows each pane can show. Both setters clamp
/// scroll to keep the selection visible, so this must happen before props are
/// read out of the application.
fn apply_viewport(view: *View, application: anytype) void {
    if (view.scopes.mounted) {
        application.set_scope_viewport_rows(view.scopes.inner.height);
    }
    if (view.bookmarks.mounted) {
        application.set_viewport_rows(
            @divFloor(view.bookmarks.inner.height, bookmark_list_visual.row_height),
        );
    }
    if (view.focus.mounted) {
        application.set_viewport_rows(
            @divFloor(view.focus.inner.height, bookmark_list_visual.row_height),
        );
    }
    // The finder owns the selection while it is open, so its window is the one
    // that decides where the selection may sit.
    if (view.finder.mounted) {
        application.set_viewport_rows(
            @divFloor(view.finder.results.inner.height, bookmark_list_visual.row_height),
        );
    }
    if (view.deck.mounted) {
        application.set_command_viewport_rows(
            @max(@divFloor(view.deck.results.inner.height, command_list_visual.row_height), 1),
        );
    }
}

fn mark_rows_dirty(view: *View, slot: *const ListSlot) void {
    if (!slot.mounted) return;
    var row: u16 = 0;
    while (row < slot.row_count) : (row += 1) {
        view.tree.mark_dirty(slot.first_row + row);
    }
}

fn capture_rects(view: *View) void {
    capture_list_rects(view, &view.scopes);
    capture_list_rects(view, &view.bookmarks);
    capture_list_rects(view, &view.focus);
    capture_list_rects(view, &view.deck.results);
    capture_list_rects(view, &view.finder.results);
    if (view.preview.mounted) {
        view.preview.inner = view.content_rect(view.preview.panel);
    }
    command_center.capture_rects(&view.tree, &view.finder);
    command_center.capture_rects(&view.tree, &view.deck);
}

fn capture_list_rects(view: *View, slot: *ListSlot) void {
    if (!slot.mounted) return;
    if (slot.panel != 0) slot.rect = view.node_rect(slot.panel);
    slot.inner = view.node_rect(slot.list);
}

/// Records where a pointer may hit what this frame drew. Read out of node
/// rects rather than recomputed, so a hit box cannot drift from the pane it
/// belongs to.
fn capture_regions(view: *View) void {
    view.regions = .{};
    if (view.scopes.mounted) view.regions.scopes = view.scopes.inner;
    if (view.bookmarks.mounted) view.regions.bookmarks = view.bookmarks.inner;
    if (view.preview.mounted) view.regions.preview = view.preview.inner;
    if (view.deck.mounted) view.regions.command_results = view.deck.results.inner;
    if (view.focus.mounted) view.regions.focus = view.focus.inner;
    if (view.finder.mounted) {
        view.regions.focus_modal = view.finder.rect;
        view.regions.finder_results = view.finder.results.inner;
        capture_categories(view);
    }
    if (view.form.mounted and view.form.grid != 0) {
        var field: u8 = 0;
        while (field < 4) : (field += 1) {
            view.regions.fields[field] = view.node_rect(view.form.cells[field * 2 + 1]);
        }
        view.regions.field_count = 4;
    }
}

/// Walks the segmented widget's own maths so each category's hit box is the
/// badge the user sees.
fn capture_categories(view: *View) void {
    const rect = view.finder.filters_rect;
    var column: u16 = 0;
    var index: u8 = 0;
    while (index < view.category_count) : (index += 1) {
        if (column >= rect.width) break;
        const available = rect.width - column;
        const width = @min(
            @as(u16, @intCast(view.categories[index].label.len + 2)),
            available,
        );
        view.regions.categories[index] = .{
            .rect = Rect.init(rect.x + column, rect.y, width, 1),
            .scope_index = view.category_scopes[index],
        };
        view.regions.category_count += 1;
        column += width;
        if (column < rect.width) column += 1;
    }
}

// Content the props are read from.

fn scope_item_count(application: anytype) u16 {
    return application.tag_count + 2;
}

fn scope_item_name(application: anytype, index: u16) []const u8 {
    if (index == 0) return "All";
    if (index == 1) return "Favorites";
    return application.tags_available[index - 2].bytes();
}

fn scope_bookmark_count(application: anytype, scope_index: u16) u16 {
    if (scope_index == 0) return application.store.count;
    var count: u16 = 0;
    var index: u16 = 0;
    while (index < application.store.count) : (index += 1) {
        const bookmark = &application.store.items[index];
        const matches = if (scope_index == 1)
            bookmark.favorite
        else
            bookmark.has_tag(application.tags_available[scope_index - 2].bytes());
        if (matches) count += 1;
    }
    return count;
}

fn scope_name(application: anytype) []const u8 {
    return switch (application.scope_kind) {
        .all => "All bookmarks",
        .favorites => "Favorites",
        .tag => application.active_tag.bytes(),
    };
}

fn empty_bookmark_text(application: anytype) []const u8 {
    if (application.search.value().len > 0) return "No search results";
    if (application.scope_kind == .favorites) return "No favorites in this library";
    if (application.scope_kind == .tag) return "No bookmarks with this tag";
    return "Press a to add a bookmark";
}

fn command_result_marker(result: anytype) u8 {
    return switch (result) {
        .action => 'D',
        .bookmark => 'B',
        .tag => '#',
    };
}

fn focus_accent(focus: anytype) markix.Color {
    return switch (focus) {
        .scopes => theme.accent_cool,
        .bookmarks => theme.accent_warm,
        .preview => theme.accent,
    };
}

fn focus_index(focus: anytype) u16 {
    return switch (focus) {
        .scopes => 0,
        .bookmarks => 1,
        .preview => 2,
    };
}

fn field_index(field: anytype) u16 {
    return switch (field) {
        .title => 0,
        .url => 1,
        .tags => 2,
        .notes => 3,
    };
}

/// Rows the preview text wraps to, counted with the same code that paints it.
fn wrapped_line_count(text: []const u8, width: u16) u16 {
    if (text.len == 0 or width == 0) return 0;
    return text_measure.wrapped_rows(text, width);
}

/// The tail of `text` that starts `skip` wrapped rows in, so a scrolled
/// preview is the same wrap the unscrolled one would have produced.
fn preview_window(text: []const u8, width: u16, skip: u16) []const u8 {
    if (width == 0) return text[text.len..];
    var offset: usize = 0;
    var row: u16 = 0;
    while (row < skip and offset < text.len) : (row += 1) {
        const line = text_measure.next_line(text, offset, width);
        if (line.next <= offset) break;
        offset = line.next;
    }
    return text[offset..];
}
