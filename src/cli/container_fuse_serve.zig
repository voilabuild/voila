const std = @import("std");
const command = @import("command.zig");
const container_fuse_sibling = @import("runtime").oci.container_fuse_sibling;
const chunk_fetch_pool = @import("mount").fuse.chunk_fetch_pool;

pub fn execute(ctx: command.Ctx) !void {
    var parsed = try container_fuse_sibling.parseServeCliArgs(ctx.gpa(), ctx.args);
    parsed.fetch_concurrency = fetchConcurrency();
    container_fuse_sibling.runServe(ctx.io, parsed);
    std.process.exit(1);
}

/// `VOILA_FETCH_CONCURRENCY`, inherited from the `voila` command that started the server.
/// Unset or not a positive number keeps the default.
fn fetchConcurrency() ?u16 {
    const v = std.c.getenv(chunk_fetch_pool.concurrency_env) orelse return null;
    const n = std.fmt.parseInt(u16, std.mem.span(v), 10) catch return null;
    return if (n == 0) null else n;
}
