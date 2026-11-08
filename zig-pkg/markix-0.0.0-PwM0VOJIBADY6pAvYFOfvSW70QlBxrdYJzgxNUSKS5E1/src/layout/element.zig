const std = @import("std");

pub const Display = enum { block, inline_ };

pub const Element = enum(u8) {
    box,
    paragraph,
    heading,
    link,
    list,
    list_item,
    code_block,
    code_span,
    quote,
    rule,
    image,
    emphasis,
    strong,
    article,
    header,
    footer,
    navigation,
    main_content,
    time,
    label,
    text_run,
    canvas,

    pub fn tag(self: Element) []const u8 {
        return switch (self) {
            .box => "div",
            .paragraph => "p",
            .heading => "h2",
            .link => "a",
            .list => "ul",
            .list_item => "li",
            .code_block => "pre",
            .code_span => "code",
            .quote => "blockquote",
            .rule => "hr",
            .image => "img",
            .emphasis => "i",
            .strong => "b",
            .article => "article",
            .header => "header",
            .footer => "footer",
            .navigation => "nav",
            .main_content => "main",
            .time => "time",
            .label => "span",
            .text_run => "",
            .canvas => "canvas",
        };
    }

    pub fn tag_for(self: Element, level: u8) []const u8 {
        if (self != .heading) return self.tag();
        return switch (level) {
            0, 1 => "h1",
            2 => "h2",
            3 => "h3",
            4 => "h4",
            5 => "h5",
            else => "h6",
        };
    }

    pub fn is_void(self: Element) bool {
        return self == .image or self == .rule;
    }

    pub fn is_inline(self: Element) bool {
        return switch (self) {
            .link, .emphasis, .strong, .code_span, .text_run => true,
            else => false,
        };
    }
};

test "headings resolve their level, everything else is constant" {
    try std.testing.expectEqualStrings("h1", Element.heading.tag_for(1));
    try std.testing.expectEqualStrings("h3", Element.heading.tag_for(3));
    try std.testing.expectEqualStrings("h6", Element.heading.tag_for(9));
    try std.testing.expectEqualStrings("p", Element.paragraph.tag_for(3));
}

test "void elements are the ones HTML forbids a close on" {
    try std.testing.expect(Element.image.is_void());
    try std.testing.expect(Element.rule.is_void());
    try std.testing.expect(!Element.paragraph.is_void());
}

test "inline elements flow, block elements are placed" {
    try std.testing.expect(Element.link.is_inline());
    try std.testing.expect(Element.strong.is_inline());
    try std.testing.expect(!Element.paragraph.is_inline());
    try std.testing.expect(!Element.image.is_inline());
}
