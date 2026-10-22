//! Workspace module root for the voila CLI (enables imports under src/).
const std = @import("std");
const app_main = @import("./app/main.zig");

pub const std_options_debug_io = app_main.std_options_debug_io;

pub fn main(init: std.process.Init) !void {
    try app_main.main(init);
}
