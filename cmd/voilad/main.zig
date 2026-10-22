//! Thin executable root for voilad (build with `zig build -Dvoilad`; gRPC via `-Dgrpc`).
const std = @import("std");

pub fn main() void {
    std.debug.print("voilad: rebuild with -Dvoilad (daemon wiring in progress)\n", .{});
    std.process.exit(2);
}
