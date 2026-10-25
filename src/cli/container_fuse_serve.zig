const std = @import("std");
const command = @import("command.zig");
const container_fuse_sibling = @import("runtime").oci.container_fuse_sibling;

pub fn execute(ctx: command.Ctx) !void {
    const parsed = try container_fuse_sibling.parseServeCliArgs(ctx.gpa(), ctx.args);
    container_fuse_sibling.runServe(ctx.io, parsed);
    std.process.exit(1);
}
