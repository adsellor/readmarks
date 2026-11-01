const std = @import("std");
const box = @import("box.zig");
const tree_mod = @import("tree.zig");
const rect_mod = @import("rect.zig");

const Tree = tree_mod.Tree;
const Node = tree_mod.Node;
const Rect = rect_mod.Rect;
const Index = tree_mod.Index;
const none = tree_mod.none;

pub const unbounded: i32 = std.math.maxInt(i32);

pub const Size = struct { width: i32 = 0, height: i32 = 0 };

pub const TextIterator = struct {
    tree: *const Tree,
    root: Index,
    cursor: Index,
    emitted_root: bool = false,

    pub fn init(tree: *const Tree, root: Index) TextIterator {
        return .{ .tree = tree, .root = root, .cursor = root };
    }

    pub fn next(self: *TextIterator) ?[]const u8 {
        if (!self.emitted_root) {
            self.emitted_root = true;
            const text = self.tree.at(self.root).text;
            self.advance();
            if (text.len > 0) return text;
            return self.pump();
        }
        return self.pump();
    }

    fn pump(self: *TextIterator) ?[]const u8 {
        while (self.cursor != none) {
            const text = self.tree.at(self.cursor).text;
            self.advance();
            if (text.len > 0) return text;
        }
        return null;
    }

    fn advance(self: *TextIterator) void {
        std.debug.assert(self.cursor != none);
        std.debug.assert(self.root < self.tree.len);
        const node = self.tree.at(self.cursor);
        const child = node.first_child;
        if (child != none and self.tree.at(child).is_inline()) {
            self.cursor = child;
            return;
        }
        var walker = self.cursor;
        while (walker != self.root and walker != none) {
            const current = self.tree.at(walker);
            const sibling = current.next_sibling;
            if (sibling != none and self.tree.at(sibling).is_inline()) {
                self.cursor = sibling;
                return;
            }
            walker = current.parent;
        }
        self.cursor = none;
    }
};

pub const Measure = *const fn (
    runs: *TextIterator,
    wrap: bool,
    available: i32,
    context: ?*anyopaque,
) Size;

pub const Options = struct {
    measure: Measure,
    context: ?*anyopaque = null,
};

const Axis = enum(u1) { x, y };

fn sizing_for(layout: box.Layout, axis: Axis) box.Sizing {
    return if (axis == .x) layout.width else layout.height;
}

fn padding_along(layout: box.Layout, axis: Axis) i32 {
    return if (axis == .x) layout.padding.horizontal() else layout.padding.vertical();
}

fn extent(r: Rect, axis: Axis) i32 {
    return if (axis == .x) r.width else r.height;
}

fn set_extent(r: *Rect, axis: Axis, value: i32) void {
    if (axis == .x) r.width = value else r.height = value;
}

fn axis_of(direction: box.Direction) Axis {
    return if (direction == .row) .x else .y;
}

fn holds_text(tree: *const Tree, index: Index) bool {
    const node = tree.at(index);
    if (node.text.len > 0) return true;
    const child = node.first_child;
    return child != none and tree.at(child).is_inline();
}

pub fn resolve(tree: *Tree, available: Size, options: Options) void {
    if (tree.len == 0) return;
    std.debug.assert(available.width >= 0);
    std.debug.assert(available.height >= 0);
    fit(tree, .x, options);
    grow(tree, .x, available.width);
    flow(tree, options);
    fit(tree, .y, options);
    grow(tree, .y, available.height);
    place(tree);
}

fn fit(tree: *Tree, axis: Axis, options: Options) void {
    std.debug.assert(tree.len > 0);
    std.debug.assert(tree.len <= tree.nodes.len);
    var cursor: Index = tree.len;
    while (cursor > 0) {
        cursor -= 1;
        const node = tree.at(cursor);
        if (node.is_inline()) continue;

        const sizing = sizing_for(node.layout, axis);
        var content: i32 = 0;

        if (holds_text(tree, cursor)) {
            if (axis == .x) {
                var runs = TextIterator.init(tree, cursor);
                content = options.measure(&runs, node.wrap, unbounded, options.context).width;
            } else {
                content = node.measured.height;
            }
        } else {
            const main = axis_of(node.layout.direction);
            var child = node.first_child;
            var total: i32 = 0;
            var largest: i32 = 0;
            var count: i32 = 0;
            while (child != none) {
                const kid = tree.at(child);
                const kid_extent = extent(kid.rect, axis);
                total += kid_extent;
                largest = @max(largest, kid_extent);
                count += 1;
                child = kid.next_sibling;
            }
            content = if (axis == main)
                total + node.layout.gap * @max(0, count - 1)
            else
                largest;
        }

        std.debug.assert(content >= 0);
        const requested = switch (sizing) {
            .fixed => |value| value,
            .percent => 0,
            .fit, .grow => content + padding_along(node.layout, axis),
        };
        set_extent(
            &node.rect,
            axis,
            std.math.clamp(requested, sizing.minimum(), sizing.maximum()),
        );
    }
}

fn grow(tree: *Tree, axis: Axis, available: i32) void {
    std.debug.assert(tree.len > 0);
    std.debug.assert(available >= 0);
    resolve_root(tree, axis, available);

    var cursor: Index = 0;
    while (cursor < tree.len) : (cursor += 1) {
        const node = tree.at(cursor);
        if (node.first_child == none) continue;
        if (node.is_inline()) continue;
        if (tree.at(node.first_child).is_inline()) continue;

        const main = axis_of(node.layout.direction);
        const inner = @max(0, extent(node.rect, axis) - padding_along(node.layout, axis));
        if (axis != main) {
            size_off_axis(tree, cursor, axis, inner);
        } else {
            size_on_axis(tree, cursor, axis, inner);
        }
    }
}

fn resolve_root(tree: *Tree, axis: Axis, available: i32) void {
    std.debug.assert(tree.len > 0);
    std.debug.assert(available >= 0);
    const root = tree.at(0);
    const sizing = sizing_for(root.layout, axis);
    const resolved = switch (sizing) {
        .fixed => |value| value,
        .percent => |value| @divTrunc(available * value, 100),
        .grow => available,
        .fit => extent(root.rect, axis),
    };
    set_extent(
        &root.rect,
        axis,
        std.math.clamp(resolved, sizing.minimum(), sizing.maximum()),
    );
}

fn size_off_axis(tree: *Tree, parent: Index, axis: Axis, inner: i32) void {
    std.debug.assert(parent < tree.len);
    std.debug.assert(inner >= 0);
    var child = tree.at(parent).first_child;
    while (child != none) {
        const kid = tree.at(child);
        const sizing = sizing_for(kid.layout, axis);
        const resolved = switch (sizing) {
            .grow => inner,
            .percent => |value| @divTrunc(inner * value, 100),
            .fixed => |value| value,
            .fit => @min(extent(kid.rect, axis), inner),
        };
        set_extent(&kid.rect, axis, std.math.clamp(
            resolved,
            sizing.minimum(),
            sizing.maximum(),
        ));
        child = kid.next_sibling;
    }
}

fn size_on_axis(tree: *Tree, parent: Index, axis: Axis, inner: i32) void {
    std.debug.assert(parent < tree.len);
    std.debug.assert(inner >= 0);
    const node = tree.at(parent);

    var used: i32 = 0;
    var count: i32 = 0;
    var growers: i32 = 0;
    var child = node.first_child;
    while (child != none) {
        const kid = tree.at(child);
        const sizing = sizing_for(kid.layout, axis);
        if (sizing == .percent) {
            set_extent(&kid.rect, axis, std.math.clamp(
                @divTrunc(inner * sizing.percent, 100),
                sizing.minimum(),
                sizing.maximum(),
            ));
        }
        if (sizing == .grow) growers += 1;
        used += extent(kid.rect, axis);
        count += 1;
        child = kid.next_sibling;
    }
    std.debug.assert(count > 0);
    used += node.layout.gap * @max(0, count - 1);

    const slack = inner - used;
    if (slack > 0 and growers > 0) {
        distribute(tree, parent, axis, slack, growers);
    } else if (slack < 0) {
        shrink(tree, parent, axis, slack);
    }
}

fn distribute(tree: *Tree, parent: Index, axis: Axis, slack: i32, growers: i32) void {
    std.debug.assert(slack > 0);
    std.debug.assert(growers > 0);
    const share = @divTrunc(slack, growers);
    var remainder = @mod(slack, growers);
    var child = tree.at(parent).first_child;
    while (child != none) {
        const kid = tree.at(child);
        const sizing = sizing_for(kid.layout, axis);
        if (sizing == .grow) {
            var give = share;
            if (remainder > 0) {
                give += 1;
                remainder -= 1;
            }
            set_extent(
                &kid.rect,
                axis,
                @min(extent(kid.rect, axis) + give, sizing.maximum()),
            );
        }
        child = kid.next_sibling;
    }
    std.debug.assert(remainder == 0);
}

fn shrink(tree: *Tree, parent: Index, axis: Axis, initial: i32) void {
    std.debug.assert(initial < 0);
    std.debug.assert(parent < tree.len);
    var slack = initial;
    var guard: u32 = 0;
    while (slack < 0 and guard < 64) : (guard += 1) {
        var shrinkable: i32 = 0;
        var child = tree.at(parent).first_child;
        while (child != none) {
            const kid = tree.at(child);
            const sizing = sizing_for(kid.layout, axis);
            if (sizing != .fixed and extent(kid.rect, axis) > sizing.minimum()) {
                shrinkable += 1;
            }
            child = kid.next_sibling;
        }
        if (shrinkable == 0) break;
        const step = @max(1, @divTrunc(-slack + shrinkable - 1, shrinkable));
        child = tree.at(parent).first_child;
        while (child != none and slack < 0) {
            const kid = tree.at(child);
            const sizing = sizing_for(kid.layout, axis);
            if (sizing != .fixed) {
                const size = extent(kid.rect, axis);
                const floor = sizing.minimum();
                if (size > floor) {
                    const taken = @min(step, size - floor);
                    set_extent(&kid.rect, axis, size - taken);
                    slack += taken;
                }
            }
            child = kid.next_sibling;
        }
    }
}

fn flow(tree: *Tree, options: Options) void {
    std.debug.assert(tree.len > 0);
    var cursor: Index = 0;
    while (cursor < tree.len) : (cursor += 1) {
        const node = tree.at(cursor);
        if (node.is_inline()) continue;
        if (!holds_text(tree, cursor)) continue;
        const inner = @max(0, node.rect.width - node.layout.padding.horizontal());
        std.debug.assert(inner >= 0);
        var runs = TextIterator.init(tree, cursor);
        const size = options.measure(
            &runs,
            node.wrap,
            if (node.wrap) inner else unbounded,
            options.context,
        );
        std.debug.assert(node.line_units >= 1);
        node.measured = .{
            .width = size.width,
            .height = size.height * node.line_units,
        };
    }
}

fn place(tree: *Tree) void {
    std.debug.assert(tree.len > 0);
    std.debug.assert(tree.at(0).rect.width >= 0);
    var cursor: Index = 0;
    while (cursor < tree.len) : (cursor += 1) {
        const node = tree.at(cursor);
        if (node.first_child == none) continue;
        if (node.is_inline()) continue;
        if (tree.at(node.first_child).is_inline()) continue;
        place_children(tree, cursor);
    }
}

fn place_children(tree: *Tree, parent: Index) void {
    std.debug.assert(parent < tree.len);
    const node = tree.at(parent);
    std.debug.assert(node.first_child != none);

    const main = axis_of(node.layout.direction);
    const inner_x = @max(0, node.rect.width - node.layout.padding.horizontal());
    const inner_y = @max(0, node.rect.height - node.layout.padding.vertical());
    const origin_x = node.rect.x + node.layout.padding.left;
    const origin_y = node.rect.y + node.layout.padding.top;

    var used: i32 = 0;
    var count: i32 = 0;
    var child = node.first_child;
    while (child != none) {
        const kid = tree.at(child);
        used += if (main == .x) kid.rect.width else kid.rect.height;
        count += 1;
        child = kid.next_sibling;
    }
    std.debug.assert(count > 0);
    used += node.layout.gap * @max(0, count - 1);

    const free = @max(0, (if (main == .x) inner_x else inner_y) - used);
    var walk: i32 = if (main == .x)
        origin_x + switch (node.layout.alignment.x) {
            .left => 0,
            .center => @divTrunc(free, 2),
            .right => free,
        }
    else
        origin_y + switch (node.layout.alignment.y) {
            .top => 0,
            .center => @divTrunc(free, 2),
            .bottom => free,
        };

    child = node.first_child;
    while (child != none) {
        const kid = tree.at(child);
        if (main == .x) {
            kid.rect.x = walk;
            const slack = @max(0, inner_y - kid.rect.height);
            kid.rect.y = origin_y + switch (node.layout.alignment.y) {
                .top => 0,
                .center => @divTrunc(slack, 2),
                .bottom => slack,
            };
            walk += kid.rect.width + node.layout.gap;
        } else {
            kid.rect.y = walk;
            const slack = @max(0, inner_x - kid.rect.width);
            kid.rect.x = origin_x + switch (node.layout.alignment.x) {
                .left => 0,
                .center => @divTrunc(slack, 2),
                .right => slack,
            };
            walk += kid.rect.height + node.layout.gap;
        }
        child = kid.next_sibling;
    }
}
