const std = @import("std");
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
