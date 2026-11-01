const std = @import("std");
const box = @import("box.zig");
const dom = @import("element.zig");
const Rect = @import("rect.zig").Rect;
const Style = @import("style.zig").Style;
const Display = dom.Display;

pub const Index = u32;
pub const none: Index = std.math.maxInt(Index);

pub const Node = struct {
    layout: box.Layout = .{},
    style: Style = .{},
    element: dom.Element = .box,
    display: Display = .block,

    text: []const u8 = "",
    href: []const u8 = "",
    external: bool = false,
    id: []const u8 = "",
    level: u8 = 0,
    wrap: bool = true,
    line_units: u8 = 1,
    clip: bool = false,
    rect: Rect = .{},
    measured: Rect = .{},

    parent: Index = none,
    first_child: Index = none,
    last_child: Index = none,
    next_sibling: Index = none,
    child_count: u32 = 0,

    pub fn is_inline(self: Node) bool {
        return self.display == .inline_;
    }
};

pub const Tree = struct {
    nodes: []Node,
    len: Index = 0,

    pub fn init(storage: []Node) Tree {
        return .{ .nodes = storage };
    }

    pub fn reset(self: *Tree) void {
        self.len = 0;
    }

    pub fn at(self: *const Tree, index: Index) *Node {
        std.debug.assert(index < self.len);
        return &self.nodes[index];
    }

    pub fn root(self: *const Tree) ?Index {
        return if (self.len == 0) null else 0;
    }

    pub fn append(self: *Tree, parent: Index, node: Node) !Index {
        if (self.len >= self.nodes.len) return error.TreeFull;
        if (parent == none and self.len != 0) return error.RootAlreadySet;
        if (parent != none and parent >= self.len) return error.InvalidParent;

        std.debug.assert(self.len < self.nodes.len);
        const index = self.len;
        self.nodes[index] = node;
        self.nodes[index].parent = parent;
        self.nodes[index].first_child = none;
        self.nodes[index].last_child = none;
        self.nodes[index].next_sibling = none;
        self.nodes[index].child_count = 0;
        self.len += 1;

        if (parent != none) {
            const owner = &self.nodes[parent];
            if (owner.last_child == none) {
                owner.first_child = index;
            } else {
                self.nodes[owner.last_child].next_sibling = index;
            }
            owner.last_child = index;
            owner.child_count += 1;
            std.debug.assert(index > parent);
        }
        return index;
    }

    pub fn children(self: *const Tree, index: Index) ChildIterator {
        return .{ .tree = self, .next_index = self.at(index).first_child };
    }

    pub const ChildIterator = struct {
        tree: *const Tree,
        next_index: Index,

        pub fn next(self: *ChildIterator) ?Index {
            if (self.next_index == none) return null;
            const current = self.next_index;
            self.next_index = self.tree.nodes[current].next_sibling;
            return current;
        }
    };

    pub fn hit(self: *const Tree, x: i32, y: i32) ?Index {
        var found: ?Index = null;
        var index: Index = 0;
        while (index < self.len) : (index += 1) {
            if (self.nodes[index].rect.contains(x, y)) found = index;
        }
        return found;
    }

    pub fn holds_children(self: *const Tree, index: Index) bool {
        return self.at(index).first_child != none;
    }

    pub fn enclosing(self: *const Tree, index: Index, element: dom.Element) Index {
        var walker = index;
        while (walker != none) {
            if (self.at(walker).element == element) return walker;
            walker = self.at(walker).parent;
        }
        return none;
    }

    pub fn first_within(self: *const Tree, index: Index, element: dom.Element) Index {
        std.debug.assert(index < self.len);
        if (self.at(index).element == element) return index;
        var child = self.at(index).first_child;
        while (child != none) {
            const found = self.first_within(child, element);
            if (found != none) return found;
            child = self.at(child).next_sibling;
        }
        return none;
    }

    pub fn with_id(self: *const Tree, id: []const u8) Index {
        if (id.len == 0) return none;
        var index: Index = 0;
        while (index < self.len) : (index += 1) {
            const node = self.at(index);
            if (node.id.len > 0 and std.mem.eql(u8, node.id, id)) return index;
        }
        return none;
    }

    pub fn nth(self: *const Tree, element: dom.Element, ordinal: usize) Index {
        var seen: usize = 0;
        var index: Index = 0;
        while (index < self.len) : (index += 1) {
            if (self.at(index).element != element) continue;
            if (seen == ordinal) return index;
            seen += 1;
        }
        return none;
    }

    pub fn ordinal_of(self: *const Tree, index: Index) usize {
        std.debug.assert(index < self.len);
        const element = self.at(index).element;
        var seen: usize = 0;
        var walker: Index = 0;
        while (walker < index) : (walker += 1) {
            if (self.at(walker).element == element) seen += 1;
        }
        return seen;
    }

    pub fn count_of(self: *const Tree, element: dom.Element) usize {
        var seen: usize = 0;
        var index: Index = 0;
        while (index < self.len) : (index += 1) {
            if (self.at(index).element == element) seen += 1;
        }
        return seen;
    }
};

test "append links children in order" {
    var storage: [8]Node = undefined;
    var tree = Tree.init(&storage);
    const root = try tree.append(none, .{});
    const first = try tree.append(root, .{});
    const second = try tree.append(root, .{});

    try std.testing.expectEqual(@as(u32, 2), tree.at(root).child_count);
    var iterator = tree.children(root);
    try std.testing.expectEqual(first, iterator.next().?);
    try std.testing.expectEqual(second, iterator.next().?);
    try std.testing.expect(iterator.next() == null);
}

test "a second root is refused" {
    var storage: [4]Node = undefined;
    var tree = Tree.init(&storage);
    _ = try tree.append(none, .{});
    try std.testing.expectError(error.RootAlreadySet, tree.append(none, .{}));
}

test "storage exhaustion is an error, not a crash" {
    var storage: [2]Node = undefined;
    var tree = Tree.init(&storage);
    const root = try tree.append(none, .{});
    _ = try tree.append(root, .{});
    try std.testing.expectError(error.TreeFull, tree.append(root, .{}));
}

test "text is borrowed, never copied" {
    var storage: [2]Node = undefined;
    var tree = Tree.init(&storage);
    const source = "a slice of somebody else's memory";
    const index = try tree.append(none, .{ .text = source });
    try std.testing.expectEqual(source.ptr, tree.at(index).text.ptr);
}

test "a run climbs to the link it belongs to" {
    var storage: [8]Node = undefined;
    var tree = Tree.init(&storage);
    const row = try tree.append(none, .{ .element = .list_item });
    const link = try tree.append(row, .{ .element = .link, .href = "/there/" });
    const run = try tree.append(link, .{ .element = .text_run, .text = "there" });

    try std.testing.expectEqual(link, tree.enclosing(run, .link));
    try std.testing.expectEqual(row, tree.enclosing(run, .list_item));
    try std.testing.expectEqual(link, tree.enclosing(link, .link));
    try std.testing.expectEqual(none, tree.enclosing(run, .image));

    try std.testing.expectEqual(link, tree.first_within(row, .link));
    try std.testing.expectEqual(run, tree.first_within(row, .text_run));
    try std.testing.expectEqual(none, tree.first_within(link, .list_item));
}

test "an anchor finds the heading it names" {
    var storage: [4]Node = undefined;
    var tree = Tree.init(&storage);
    _ = try tree.append(none, .{});
    const heading = try tree.append(0, .{ .element = .heading, .id = "why" });

    try std.testing.expectEqual(heading, tree.with_id("why"));
    try std.testing.expectEqual(none, tree.with_id("nowhere"));
    try std.testing.expectEqual(none, tree.with_id(""));
}

test "rows are found by position, and report the one they are at" {
    var storage: [8]Node = undefined;
    var tree = Tree.init(&storage);
    const list = try tree.append(none, .{ .element = .list });
    const first = try tree.append(list, .{ .element = .list_item });
    _ = try tree.append(first, .{ .element = .link });
    const second = try tree.append(list, .{ .element = .list_item });

    try std.testing.expectEqual(@as(usize, 2), tree.count_of(.list_item));
    try std.testing.expectEqual(first, tree.nth(.list_item, 0));
    try std.testing.expectEqual(second, tree.nth(.list_item, 1));
    try std.testing.expectEqual(none, tree.nth(.list_item, 2));
    try std.testing.expectEqual(@as(usize, 1), tree.ordinal_of(second));
}
