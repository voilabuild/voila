const std = @import("std");
const command = @import("command.zig");
const container_bind = @import("runtime").oci.container_bind;

pub fn execute(_: command.Ctx) !void {
    std.process.exit(exitCode());
}

pub fn exitCode() u8 {
    return if (container_bind.probeUserNamespaces()) 0 else 1;
}
