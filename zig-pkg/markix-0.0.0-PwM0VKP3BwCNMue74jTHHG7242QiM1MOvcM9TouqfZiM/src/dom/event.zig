const std = @import("std");
const Rect = @import("../layout/rect.zig").Rect;
const Pointer = @import("../utils/input.zig").Pointer;
const Key = @import("../utils/input.zig").Key;
const Tree = @import("tree.zig").Tree;
const DomNode = @import("node.zig").DomNode;
const NodeKind = @import("node.zig").NodeKind;

pub const Action = enum {
    none,
    redraw,
    activate,
    stop,
};

pub const DomEvent = union(enum) {
    click: Pointer,
    key_press: Key,
    focus: Tree.NodeIndex,
    blur: void,
    hover: Pointer,
    text_input: u8,
    scroll: i16,
};

pub const EventResult = struct {
    action: Action = .none,
    activated_node: ?Tree.NodeIndex = null,
};

pub fn dispatch(
    tree: *Tree,
    target: Tree.NodeIndex,
    event: DomEvent,
) EventResult {
    std.debug.assert(tree.node_count <= @import("tree.zig").dom_nodes_max);
    if (target >= tree.node_count) return .{};
    std.debug.assert(tree.root != null);
    const node = &tree.nodes[target].element;
    // Exhaustive on purpose: a new NodeKind must state its event behaviour
    // rather than silently inheriting an inert default.
    return switch (node.kind) {
        .button => handle_button(tree, target, event),
        .label => handle_label(tree, target, event),
        .badge => handle_badge(tree, target, event),
        .list => handle_list(tree, target, event),
        .text_input => handle_text_input(tree, target, event),
        // Rows are painted units, not event targets: a click lands on the
        // owning list, which resolves it to a row index.
        .container,
        .list_item,
        .panel,
        .segmented,
        .status_line,
        .image,
        .heading,
        .rule,
        .code_block,
        => .{},
    };
}

fn handle_button(
    tree: *Tree,
    target: Tree.NodeIndex,
    event: DomEvent,
) EventResult {
    std.debug.assert(target < tree.node_count);
    const node = &tree.nodes[target].element;
    std.debug.assert(node.kind == .button);
    switch (event) {
        .click => |pointer| {
            if (pointer.action == .press and node.interactable) {
                tree.set_focused(target, true);
                return .{ .action = .activate, .activated_node = target };
            }
        },
        .key_press => |key| {
            if (node.focused and is_activate_key(key)) {
                return .{ .action = .activate, .activated_node = target };
            }
        },
        .hover => |pointer| {
            const inside = rect_contains(node.rect(), pointer);
            tree.set_hovered(target, inside);
            return .{ .action = if (node.hovered) .redraw else .none };
        },
        .focus => {
            tree.set_focused(target, true);
            return .{ .action = .redraw };
        },
        .blur => {
            tree.set_focused(target, false);
            return .{ .action = .redraw };
        },
        else => {},
    }
    return .{};
}

fn handle_label(
    _: *Tree,
    _: Tree.NodeIndex,
    _: DomEvent,
) EventResult {
    return .{};
}

fn handle_badge(
    _: *Tree,
    _: Tree.NodeIndex,
    _: DomEvent,
) EventResult {
    return .{};
}

fn handle_list(
    tree: *Tree,
    target: Tree.NodeIndex,
    event: DomEvent,
) EventResult {
    std.debug.assert(target < tree.node_count);
    const node = &tree.nodes[target].element;
    std.debug.assert(node.kind == .list);
    switch (event) {
        .key_press => |key| {
            if (!node.focused) return .{};
            return switch (key) {
                .up => move_selection(tree, target, -1),
                .down => move_selection(tree, target, 1),
                .home => set_selection(tree, target, 0),
                .end => set_selection(tree, target, last_index(node)),
                .enter => .{ .action = .activate, .activated_node = target },
                else => .{},
            };
        },
        .scroll => |delta| return scroll_by(tree, target, delta),
        .click => |pointer| {
            if (pointer.action != .press or !node.interactable) return .{};
            if (!rect_contains(node.rect(), pointer)) return .{};
            tree.set_focused(target, true);
            const row = row_at(node, pointer.y);
            _ = set_selection(tree, target, row);
            return .{ .action = .activate, .activated_node = target };
        },
        .hover => |pointer| {
            const was_hovered = node.hovered;
            tree.set_hovered(target, rect_contains(node.rect(), pointer));
            const changed = node.hovered != was_hovered;
            return .{ .action = if (changed) .redraw else .none };
        },
        .focus => {
            tree.set_focused(target, true);
            return .{ .action = .redraw };
        },
        .blur => {
            tree.set_focused(target, false);
            return .{ .action = .redraw };
        },
        else => {},
    }
    return .{};
}

fn last_index(node: *const DomNode) u16 {
    const count = node.props.list.item_count;
    if (count == 0) return 0;
    return count - 1;
}

/// Rows the list can show at once, honouring the configured row height.
fn list_capacity(node: *const DomNode) u16 {
    const row_height = node.props.list.visual.row_height;
    if (row_height == 0) return 0;
    return @divFloor(node.rect().height, row_height);
}

fn row_at(node: *const DomNode, y: u16) u16 {
    const row_height = node.props.list.visual.row_height;
    if (row_height == 0) return node.props.list.selected;
    const offset = @divFloor(y -| node.rect().y, row_height);
    const index = @as(u32, node.props.list.scroll) + offset;
    return @intCast(@min(index, last_index(node)));
}

fn move_selection(tree: *Tree, target: Tree.NodeIndex, delta: i2) EventResult {
    const node = &tree.nodes[target].element;
    const current = node.props.list.selected;
    const next = if (delta < 0)
        current -| 1
    else
        @min(current +| 1, last_index(node));
    return set_selection(tree, target, next);
}

fn set_selection(tree: *Tree, target: Tree.NodeIndex, next: u16) EventResult {
    std.debug.assert(target < tree.node_count);
    const node = &tree.nodes[target].element;
    std.debug.assert(node.kind == .list);
    if (node.props.list.item_count == 0) return .{};
    const clamped = @min(next, last_index(node));
    std.debug.assert(clamped < node.props.list.item_count);
    const scrolled = reveal(node, clamped);
    if (clamped == node.props.list.selected and !scrolled) return .{};
    // Through the tree, so the row that is now selected knows it. The renderer
    // paints a row from the row's own flag, so a selection written only to the
    // list moves nothing a reader can see -- and dirtying the list to cover
    // that repaints every row for a move that touched two.
    if (!tree.select_row(target, clamped)) {
        // No row is mounted for it: a list whose rows are drawn from a slice
        // rather than mounted as nodes has none, and it repaints as a whole.
        node.props.list.selected = clamped;
        tree.mark_dirty(target);
    }
    // Scrolling moves every row, which is the one case where the whole list
    // does have to be repainted.
    if (scrolled) tree.mark_dirty(target);
    return .{ .action = .redraw };
}

/// Keeps `selected` inside the visible window, returning whether scroll moved.
fn reveal(node: *DomNode, selected: u16) bool {
    const capacity = list_capacity(node);
    if (capacity == 0) return false;
    const scroll = node.props.list.scroll;
    if (selected < scroll) {
        node.props.list.scroll = selected;
        return true;
    }
    if (selected >= scroll +| capacity) {
        node.props.list.scroll = selected - capacity + 1;
        return true;
    }
    return false;
}

fn scroll_by(tree: *Tree, target: Tree.NodeIndex, delta: i16) EventResult {
    std.debug.assert(target < tree.node_count);
    const node = &tree.nodes[target].element;
    std.debug.assert(node.kind == .list);
    const count = node.props.list.item_count;
    if (count == 0) return .{};
    const capacity = list_capacity(node);
    const maximum: u16 = if (count > capacity)
        @intCast(count - capacity)
    else
        0;
    const current = node.props.list.scroll;
    const next = if (delta < 0)
        current -| @as(u16, @intCast(-delta))
    else
        @min(current +| @as(u16, @intCast(delta)), maximum);
    if (next == current) return .{};
    node.props.list.scroll = next;
    tree.mark_dirty(target);
    return .{ .action = .redraw };
}

/// The DOM does not own the text buffer, so this moves the cursor and reports
/// submit/cancel; inserting and deleting stays with whoever owns the storage.
fn handle_text_input(
    tree: *Tree,
    target: Tree.NodeIndex,
    event: DomEvent,
) EventResult {
    std.debug.assert(target < tree.node_count);
    const node = &tree.nodes[target].element;
    std.debug.assert(node.kind == .text_input);
    switch (event) {
        .key_press => |key| {
            if (!node.focused) return .{};
            return switch (key) {
                .left => move_cursor(tree, target, -1),
                .right => move_cursor(tree, target, 1),
                .home => set_cursor(tree, target, 0),
                .end => set_cursor(tree, target, value_length(node)),
                .enter => .{ .action = .activate, .activated_node = target },
                .escape => .{ .action = .stop },
                else => .{},
            };
        },
        .click => |pointer| {
            if (pointer.action != .press or !node.interactable) return .{};
            if (!rect_contains(node.rect(), pointer)) return .{};
            tree.set_focused(target, true);
            return .{ .action = .redraw };
        },
        .hover => |pointer| {
            const was_hovered = node.hovered;
            tree.set_hovered(target, rect_contains(node.rect(), pointer));
            const changed = node.hovered != was_hovered;
            return .{ .action = if (changed) .redraw else .none };
        },
        .focus => {
            tree.set_focused(target, true);
            return .{ .action = .redraw };
        },
        .blur => {
            tree.set_focused(target, false);
            return .{ .action = .redraw };
        },
        else => {},
    }
    return .{};
}

fn value_length(node: *const DomNode) u16 {
    return @intCast(@min(node.props.text_input.value.len, 65535));
}

fn move_cursor(tree: *Tree, target: Tree.NodeIndex, delta: i2) EventResult {
    const node = &tree.nodes[target].element;
    const current = node.props.text_input.cursor;
    const next = if (delta < 0)
        current -| 1
    else
        @min(current +| 1, value_length(node));
    return set_cursor(tree, target, next);
}

fn set_cursor(tree: *Tree, target: Tree.NodeIndex, next: u16) EventResult {
    const node = &tree.nodes[target].element;
    const clamped = @min(next, value_length(node));
    if (clamped == node.props.text_input.cursor) return .{};
    node.props.text_input.cursor = clamped;
    tree.mark_dirty(target);
    return .{ .action = .redraw };
}

fn is_activate_key(key: Key) bool {
    return switch (key) {
        .enter => true,
        .character => |c| c == ' ',
        else => false,
    };
}

fn rect_contains(rect: Rect, pointer: Pointer) bool {
    return pointer.x >= rect.x and
        pointer.x < rect.x + rect.width and
        pointer.y >= rect.y and
        pointer.y < rect.y + rect.height;
}

pub fn hit_test(
    tree: *const Tree,
    pointer: Pointer,
) ?Tree.NodeIndex {
    std.debug.assert(tree.node_count <= @import("tree.zig").dom_nodes_max);
    var best: ?Tree.NodeIndex = null;
    var index: Tree.NodeIndex = 0;
    while (index < tree.node_count) : (index += 1) {
        const node = &tree.nodes[index].element;
        if (!node.interactable) continue;
        if (rect_contains(node.rect(), pointer)) {
            // The last match wins: children hold a higher index than their
            // parent, so this is the innermost node under the pointer.
            best = index;
        }
    }
    std.debug.assert(best == null or best.? < tree.node_count);
    return best;
}

pub fn find_focused(tree: *const Tree) ?Tree.NodeIndex {
    var index: Tree.NodeIndex = 0;
    while (index < tree.node_count) : (index += 1) {
        if (tree.nodes[index].element.focused) return index;
    }
    return null;
}

test "dispatch button click activates" {
    var tree = Tree.init();
    const button = try tree.set_root(.{
        .kind = .button,
        .props = .{ .button = .{ .text = "OK" } },
        .layout = .{ .kind = .{ .leaf = {} }, .rect = Rect.init(0, 0, 10, 1) },
        .interactable = true,
    });
    const result = dispatch(&tree, button, .{
        .click = .{ .x = 2, .y = 0, .action = .press, .button = .primary },
    });
    try std.testing.expectEqual(Action.activate, result.action);
    try std.testing.expectEqual(button, result.activated_node.?);
}

test "dispatch button hover toggles state" {
    var tree = Tree.init();
    const button = try tree.set_root(.{
        .kind = .button,
        .props = .{ .button = .{ .text = "OK" } },
        .layout = .{ .kind = .{ .leaf = {} }, .rect = Rect.init(0, 0, 10, 1) },
        .interactable = true,
        .dirty = false,
    });
    const result = dispatch(&tree, button, .{
        .hover = .{ .x = 5, .y = 0, .action = .drag, .button = .none },
    });
    try std.testing.expect(tree.nodes[button].element.hovered);
    try std.testing.expectEqual(Action.redraw, result.action);
}

test "dispatch button key enter activates" {
    var tree = Tree.init();
    const button = try tree.set_root(.{
        .kind = .button,
        .props = .{ .button = .{ .text = "OK" } },
        .layout = .{ .kind = .{ .leaf = {} }, .rect = Rect.init(0, 0, 10, 1) },
        .interactable = true,
        .focused = true,
    });
    const result = dispatch(&tree, button, .{ .key_press = .enter });
    try std.testing.expectEqual(Action.activate, result.action);
}

test "hit test finds interactable node" {
    var tree = Tree.init();
    _ = try tree.set_root(.{
        .kind = .button,
        .props = .{ .button = .{ .text = "A" } },
        .layout = .{ .kind = .{ .leaf = {} }, .rect = Rect.init(0, 0, 5, 1) },
        .interactable = true,
    });
    _ = try tree.append_child(0, .{
        .kind = .button,
        .props = .{ .button = .{ .text = "B" } },
        .layout = .{ .kind = .{ .leaf = {} }, .rect = Rect.init(10, 0, 5, 1) },
        .interactable = true,
    });
    const hit = hit_test(&tree, .{
        .x = 12,
        .y = 0,
        .action = .press,
        .button = .primary,
    });
    try std.testing.expectEqual(@as(Tree.NodeIndex, 1), hit.?);
}

test "find focused returns focused node" {
    var tree = Tree.init();
    _ = try tree.set_root(.{
        .kind = .button,
        .props = .{ .button = .{} },
        .layout = LayoutElement.leaf(),
        .interactable = true,
    });
    _ = try tree.append_child(0, .{
        .kind = .button,
        .props = .{ .button = .{} },
        .layout = LayoutElement.leaf(),
        .interactable = true,
        .focused = true,
    });
    try std.testing.expectEqual(@as(Tree.NodeIndex, 1), find_focused(&tree).?);
}

const LayoutElement = @import("../layout/tree.zig").LayoutElement;
const ListItem = @import("types.zig").ListItem;

const test_item_count: u16 = 4;

fn list_tree(rect: Rect) Tree {
    var tree = Tree.init();
    _ = tree.set_root(.{
        .kind = .list,
        .props = .{ .list = .{ .item_count = test_item_count } },
        .layout = .{ .kind = .{ .leaf = {} }, .rect = rect },
        .interactable = true,
        .focused = true,
        .dirty = false,
    }) catch unreachable;
    return tree;
}

test "list arrow keys move selection and mark dirty" {
    var tree = list_tree(Rect.init(0, 0, 20, 4));
    try std.testing.expectEqual(Action.redraw, dispatch(&tree, 0, .{ .key_press = .down }).action);
    try std.testing.expectEqual(@as(u16, 1), tree.nodes[0].element.props.list.selected);
    try std.testing.expect(tree.is_dirty(0));
    _ = dispatch(&tree, 0, .{ .key_press = .up });
    try std.testing.expectEqual(@as(u16, 0), tree.nodes[0].element.props.list.selected);
}

test "the row a key press selects is the row that lights up" {
    // The renderer paints a row from the row's own flag. Selection that only
    // moved the list's index moved something nothing draws: the list reported
    // row one, and row one did not know.
    var tree = mounted_list(4, Rect.init(0, 0, 20, 4));
    _ = dispatch(&tree, 0, .{ .key_press = .down });
    try std.testing.expectEqual(@as(u16, 1), tree.nodes[0].element.props.list.selected);
    try std.testing.expect(tree.nodes[2].element.props.list_item.selected);
    try std.testing.expect(!tree.nodes[1].element.props.list_item.selected);

    _ = dispatch(&tree, 0, .{ .key_press = .down });
    try std.testing.expect(tree.nodes[3].element.props.list_item.selected);
    // And the row it left goes back to being an ordinary row.
    try std.testing.expect(!tree.nodes[2].element.props.list_item.selected);
}

test "moving through a list costs the rows that changed" {
    // The reason rows are nodes at all. A list marked dirty spreads to every
    // row, so a one-row move repainted the whole viewport.
    var tree = mounted_list(64, Rect.init(0, 0, 20, 64));
    // The first move lands on a row and leaves none, because a freshly mounted
    // list has an index but no row carrying it yet.
    _ = dispatch(&tree, 0, .{ .key_press = .down });
    tree.clear_dirty();
    _ = dispatch(&tree, 0, .{ .key_press = .down });
    tree.propagate_dirty();
    try std.testing.expectEqual(@as(u16, 2), tree.dirty_count);
    try std.testing.expect(!tree.is_dirty(0));
    try std.testing.expect(tree.is_dirty(2));
    try std.testing.expect(tree.is_dirty(3));
}

test "a click selects the row under the pointer, and that row knows it" {
    var tree = mounted_list(4, Rect.init(0, 0, 20, 4));
    _ = dispatch(&tree, 0, .{
        .click = .{ .x = 3, .y = 2, .action = .press, .button = .primary },
    });
    try std.testing.expectEqual(@as(u16, 2), tree.nodes[0].element.props.list.selected);
    try std.testing.expect(tree.nodes[3].element.props.list_item.selected);
}

test "a list with no rows mounted still selects, and repaints whole" {
    // Rows may be drawn from a slice by the widget rather than mounted as
    // nodes. There is nothing finer to repaint then, so the list repaints.
    var tree = list_tree(Rect.init(0, 0, 20, 4));
    _ = dispatch(&tree, 0, .{ .key_press = .down });
    try std.testing.expectEqual(@as(u16, 1), tree.nodes[0].element.props.list.selected);
    try std.testing.expect(tree.is_dirty(0));
}

test "selecting past the bottom edge scrolls the rows that are shown" {
    // `reveal` moves the window; the layout has to honour it, or the selection
    // scrolls to a row sitting exactly where it was.
    var tree = mounted_list(6, Rect.init(0, 0, 20, 2));
    _ = dispatch(&tree, 0, .{ .key_press = .end });
    try std.testing.expectEqual(@as(u16, 5), tree.nodes[0].element.props.list.selected);
    try std.testing.expectEqual(@as(u16, 4), tree.nodes[0].element.props.list.scroll);
    try tree.evaluate(Rect.init(0, 0, 20, 2));
    // The first four rows are outside the window and take no room.
    try std.testing.expectEqual(@as(u16, 0), tree.get(1).?.rect().height);
    try std.testing.expectEqual(@as(u16, 0), tree.get(4).?.rect().height);
    // The last two are the window, at the top of the list and under it.
    try std.testing.expectEqual(Rect.init(0, 0, 20, 1), tree.get(5).?.rect());
    try std.testing.expectEqual(Rect.init(0, 1, 20, 1), tree.get(6).?.rect());
}

/// A list whose rows are mounted as nodes, which is how a list that wants
/// per-row repaint is built.
fn mounted_list(rows: u16, rect: Rect) Tree {
    std.debug.assert(rows > 0);
    std.debug.assert(rect.width > 0);
    var tree = Tree.init();
    const list = tree.set_root(.{
        .kind = .list,
        .props = .{ .list = .{ .item_count = rows } },
        .layout = .{ .kind = .{ .leaf = {} }, .rect = rect },
        .interactable = true,
        .focused = true,
        .dirty = false,
    }) catch unreachable;
    var index: u16 = 0;
    while (index < rows) : (index += 1) {
        _ = tree.append_child(list, .{
            .kind = .list_item,
            .props = .{ .list_item = .{ .title = "row" } },
            .layout = LayoutElement.sized(1),
            .dirty = false,
        }) catch unreachable;
    }
    return tree;
}

test "list selection clamps at both ends" {
    var tree = list_tree(Rect.init(0, 0, 20, 4));
    _ = dispatch(&tree, 0, .{ .key_press = .up });
    try std.testing.expectEqual(@as(u16, 0), tree.nodes[0].element.props.list.selected);
    _ = dispatch(&tree, 0, .{ .key_press = .end });
    try std.testing.expectEqual(@as(u16, 3), tree.nodes[0].element.props.list.selected);
    _ = dispatch(&tree, 0, .{ .key_press = .down });
    try std.testing.expectEqual(@as(u16, 3), tree.nodes[0].element.props.list.selected);
}

test "list scrolls to keep the selection visible" {
    // Two visible rows, so selecting the fourth item must scroll the window.
    var tree = list_tree(Rect.init(0, 0, 20, 2));
    _ = dispatch(&tree, 0, .{ .key_press = .end });
    const props = tree.nodes[0].element.props.list;
    try std.testing.expectEqual(@as(u16, 3), props.selected);
    try std.testing.expectEqual(@as(u16, 2), props.scroll);
}

test "list scroll event is bounded by item count" {
    var tree = list_tree(Rect.init(0, 0, 20, 2));
    _ = dispatch(&tree, 0, .{ .scroll = 10 });
    try std.testing.expectEqual(@as(u16, 2), tree.nodes[0].element.props.list.scroll);
    _ = dispatch(&tree, 0, .{ .scroll = -10 });
    try std.testing.expectEqual(@as(u16, 0), tree.nodes[0].element.props.list.scroll);
}

test "list click selects the row under the pointer" {
    var tree = list_tree(Rect.init(0, 0, 20, 4));
    const result = dispatch(&tree, 0, .{
        .click = .{ .x = 3, .y = 2, .action = .press, .button = .primary },
    });
    try std.testing.expectEqual(Action.activate, result.action);
    try std.testing.expectEqual(@as(u16, 2), tree.nodes[0].element.props.list.selected);
}

test "list ignores keys when not focused" {
    var tree = list_tree(Rect.init(0, 0, 20, 4));
    tree.nodes[0].element.focused = false;
    try std.testing.expectEqual(Action.none, dispatch(&tree, 0, .{ .key_press = .down }).action);
    try std.testing.expectEqual(@as(u16, 0), tree.nodes[0].element.props.list.selected);
}

test "empty list selection stays put" {
    var tree = Tree.init();
    _ = try tree.set_root(.{
        .kind = .list,
        .props = .{ .list = .{} },
        .layout = .{ .kind = .{ .leaf = {} }, .rect = Rect.init(0, 0, 20, 4) },
        .focused = true,
    });
    try std.testing.expectEqual(Action.none, dispatch(&tree, 0, .{ .key_press = .down }).action);
    try std.testing.expectEqual(@as(u16, 0), tree.nodes[0].element.props.list.selected);
}

fn text_input_tree(value: []const u8, cursor: u16) Tree {
    var tree = Tree.init();
    _ = tree.set_root(.{
        .kind = .text_input,
        .props = .{ .text_input = .{ .value = value, .cursor = cursor } },
        .layout = .{ .kind = .{ .leaf = {} }, .rect = Rect.init(0, 0, 20, 1) },
        .interactable = true,
        .focused = true,
        .dirty = false,
    }) catch unreachable;
    return tree;
}

test "text input cursor moves within the value" {
    var tree = text_input_tree("hello", 2);
    _ = dispatch(&tree, 0, .{ .key_press = .left });
    try std.testing.expectEqual(@as(u16, 1), tree.nodes[0].element.props.text_input.cursor);
    _ = dispatch(&tree, 0, .{ .key_press = .end });
    try std.testing.expectEqual(@as(u16, 5), tree.nodes[0].element.props.text_input.cursor);
    _ = dispatch(&tree, 0, .{ .key_press = .right });
    try std.testing.expectEqual(@as(u16, 5), tree.nodes[0].element.props.text_input.cursor);
    _ = dispatch(&tree, 0, .{ .key_press = .home });
    try std.testing.expectEqual(@as(u16, 0), tree.nodes[0].element.props.text_input.cursor);
}

test "text input reports submit and cancel" {
    var tree = text_input_tree("hello", 0);
    const submitted = dispatch(&tree, 0, .{ .key_press = .enter });
    try std.testing.expectEqual(Action.activate, submitted.action);
    try std.testing.expectEqual(@as(Tree.NodeIndex, 0), submitted.activated_node.?);
    try std.testing.expectEqual(Action.stop, dispatch(&tree, 0, .{ .key_press = .escape }).action);
}

test "text input cursor clamps to a shorter value" {
    var tree = text_input_tree("hi", 9);
    _ = dispatch(&tree, 0, .{ .key_press = .right });
    try std.testing.expectEqual(@as(u16, 2), tree.nodes[0].element.props.text_input.cursor);
}
