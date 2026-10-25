const std = @import("std");
const flags = @import("flags.zig");
const voila_runtime = @import("runtime").open;

pub const Parsed = struct {
    runtime_cfg: voila_runtime.Config,
    opts: voila_runtime.LogsOptions,

    pub fn deinit(self: Parsed, allocator: std.mem.Allocator) void {
        allocator.free(self.runtime_cfg.store_root);
        allocator.free(self.opts.context_id);
    }
};

pub fn parseArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !Parsed {
    var root: ?[]const u8 = null;
    var kind = voila_runtime.kindFromEnv();
    var follow = false;
    var context_id: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (try flags.tryRuntimeFlag(allocator, arg, args, &root, &kind)) continue;
        if (std.mem.eql(u8, arg, "-follow") or std.mem.eql(u8, arg, "-f")) {
            follow = true;
        } else if (context_id == null) {
            context_id = try allocator.dupe(u8, arg);
        }
    }
    const cid = context_id orelse return error.NeedContextId;
    return .{
        .runtime_cfg = try flags.finishRuntimeConfig(allocator, root, kind),
        .opts = .{ .context_id = cid, .follow = follow },
    };
}
