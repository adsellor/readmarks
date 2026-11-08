pub const PointerAction = enum {
    press,
    drag,
    release,
};

pub const PointerButton = enum {
    primary,
    middle,
    secondary,
    wheel_up,
    wheel_down,
    none,
};

pub const Pointer = struct {
    x: u16,
    y: u16,
    action: PointerAction,
    button: PointerButton,
};

pub const Key = union(enum) {
    character: u8,
    control: u8,
    pointer: Pointer,
    enter,
    escape,
    backspace,
    delete,
    tab,
    shift_tab,
    up,
    down,
    left,
    right,
    home,
    end,
};
