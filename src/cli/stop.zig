const std = @import("std");
const command = @import("command.zig");
const context = @import("context.zig");

pub fn execute(ctx: command.Ctx) !void {
    const gpa = ctx.gpa();
    const parsed = try context.parseArgs(gpa, ctx.args);
    defer parsed.deinit(gpa);
    var worker = try command.openRuntime(gpa, parsed.runtime_cfg);
    defer worker.deinit(gpa);
    var failed = false;
    for (parsed.refs) |ref| {
        worker.stop(ctx.io, gpa, ref) catch |e| {
            command.exitIfNotImplemented(e);
            if (e == error.NotFound) {
                std.debug.print("voila stop: no such container {s}\n", .{ref.context_id});
                failed = true;
                continue;
            }
            return e;
        };
    }
    if (failed) std.process.exit(1);
}
