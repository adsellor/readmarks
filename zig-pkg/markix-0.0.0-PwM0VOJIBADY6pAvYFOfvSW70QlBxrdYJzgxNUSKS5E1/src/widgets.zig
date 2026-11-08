const text_input = @import("widgets/text_input.zig");

pub const TextInput = text_input.TextInput;
pub const TextInputAction = text_input.Action;
pub const TextInputSplit = text_input.Split;
pub const split_text = text_input.split_text;

test {
    _ = text_input;
}
