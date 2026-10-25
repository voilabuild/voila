const command = @import("command.zig");
const context = @import("context.zig");

pub fn execute(ctx: command.Ctx) !void {
    const gpa = ctx.gpa();
    const parsed = try context.parseKillArgs(gpa, ctx.args);
    defer parsed.deinit(gpa);
    var worker = try command.openRuntime(gpa, parsed.runtime_cfg);
    defer worker.deinit(gpa);
    worker.kill(ctx.io, gpa, parsed.opts) catch |e| {
        command.exitIfNotImplemented(e);
        return e;
    };
}
