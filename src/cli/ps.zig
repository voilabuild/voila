const command = @import("command.zig");
const runtime_only = @import("runtime_only.zig");

pub fn execute(ctx: command.Ctx) !void {
    const gpa = ctx.gpa();
    const cfg = try runtime_only.parseArgs(gpa, ctx.args);
    defer gpa.free(cfg.store_root);
    var worker = try command.openRuntime(gpa, cfg);
    defer worker.deinit(gpa);
    worker.ps(ctx.io, gpa) catch |e| {
        command.exitIfNotImplemented(e);
        return e;
    };
}
