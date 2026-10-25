const command = @import("command.zig");
const prove = @import("prove.zig");

pub fn execute(ctx: command.Ctx) !void {
    const voila_root = ctx.args.next() orelse return error.NeedVoilaRoot;
    const image = ctx.args.next() orelse return error.NeedImage;
    try prove.runStore(ctx.io, ctx.init, voila_root, image);
}
