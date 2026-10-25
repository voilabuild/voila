//! The `app` layer: process entry only; subcommands live in `cli/`.

pub const Ctx = @import("Ctx.zig").Ctx;
pub const main = @import("main.zig");

pub const std_options_debug_io = main.std_options_debug_io;

test {
    _ = @import("Ctx.zig");
    _ = @import("main.zig");
}
