const std = @import("std");
const command = @import("command.zig");
const flags = @import("flags.zig");
const voila_runtime = @import("runtime").open;

pub const Parsed = struct {
    runtime_cfg: voila_runtime.Config,
    image: []const u8,
};

pub fn parseArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !Parsed {
    var root: ?[]const u8 = null;
    var kind = voila_runtime.kindFromEnv();
    var image: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (try flags.tryRuntimeFlag(allocator, arg, args, &root, &kind)) continue;
        if (image == null) {
            image = try allocator.dupe(u8, arg);
        } else {
            return error.BadRunArgs;
        }
    }
    const img = image orelse return error.NeedImage;
    return .{
        .runtime_cfg = try flags.finishRuntimeConfig(allocator, root, kind),
        .image = img,
    };
}

pub fn executePull(ctx: command.Ctx) !void {
    const gpa = ctx.gpa();
    const parsed = try parseArgs(gpa, ctx.args);
    defer gpa.free(parsed.runtime_cfg.store_root);
    defer gpa.free(parsed.image);
    var worker = try command.openRuntime(gpa, parsed.runtime_cfg);
    defer worker.deinit(gpa);
    worker.pull(ctx.io, gpa, .{ .image = parsed.image }) catch |e| {
        command.exitIfNotImplemented(e);
        // local already printed a Hub-import hint for a missing registry image
        if (e == error.HttpStatus or e == error.FetchFailed) std.process.exit(1);
        return e;
    };
}
