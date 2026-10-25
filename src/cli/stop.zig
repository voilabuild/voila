const command = @import("command.zig");
const context = @import("context.zig");

pub fn execute(ctx: command.Ctx) !void {
    const gpa = ctx.gpa();
    const parsed = try context.parseArgs(gpa, ctx.args);
    defer parsed.deinit(gpa);
    var worker = try command.openRuntime(gpa, parsed.runtime_cfg);
    defer worker.deinit(gpa);
    worker.stop(ctx.io, gpa, parsed.ref) catch |e| {
        command.exitIfNotImplemented(e);
        return e;
    };
}
