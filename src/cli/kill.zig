const std = @import("std");
const command = @import("command.zig");
const context = @import("context.zig");

pub fn execute(ctx: command.Ctx) !void {
    const gpa = ctx.gpa();
    const parsed = try context.parseKillArgs(gpa, ctx.args);
    defer parsed.deinit(gpa);
    var worker = try command.openRuntime(gpa, parsed.runtime_cfg);
    defer worker.deinit(gpa);
    var failed = false;
    for (parsed.ids) |id| {
        worker.kill(ctx.io, gpa, .{ .context_id = id, .signal = parsed.signal }) catch |e| {
            command.exitIfNotImplemented(e);
            if (e == error.NotFound) {
                std.debug.print("voila kill: no such container {s}\n", .{id});
                failed = true;
                continue;
            }
            return e;
        };
    }
    if (failed) std.process.exit(1);
}
