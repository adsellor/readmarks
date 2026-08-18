const commands_module = @import("web/commands.zig");
const serialize_module = @import("web/serialize.zig");
const input_module = @import("web/input.zig");

pub const commands = commands_module;
pub const serialize = serialize_module;
pub const input = input_module;

test {
    _ = commands_module;
    _ = serialize_module;
    _ = input_module;
}
