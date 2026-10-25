const std = @import("std");
const flags = @import("flags.zig");
const voila_runtime = @import("runtime").open;

pub fn parseArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !voila_runtime.Config {
    var root: ?[]const u8 = null;
    var kind = voila_runtime.kindFromEnv();
    while (args.next()) |arg| {
        if (try flags.tryRuntimeFlag(allocator, arg, args, &root, &kind)) continue;
    }
    return flags.finishRuntimeConfig(allocator, root, kind);
}
