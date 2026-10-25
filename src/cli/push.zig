const command = @import("command.zig");
const pull = @import("pull.zig");

pub fn execute(ctx: command.Ctx) !void {
    const gpa = ctx.gpa();
    const parsed = try pull.parseArgs(gpa, ctx.args);
    defer gpa.free(parsed.runtime_cfg.store_root);
    defer gpa.free(parsed.image);
    var worker = try command.openRuntime(gpa, parsed.runtime_cfg);
    defer worker.deinit(gpa);
    try worker.push(ctx.io, gpa, .{ .image = parsed.image });
}
