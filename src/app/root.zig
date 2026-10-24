//! The `app` layer. CLI entry point; picks implementations and reads env.

pub const build_cmd = @import("build_cmd.zig");
pub const main = @import("main.zig");

pub const std_options_debug_io = main.std_options_debug_io;

test {
    _ = @import("build_cmd.zig");
    _ = @import("main.zig");
}
