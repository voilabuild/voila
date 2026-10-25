const std = @import("std");
const flags = @import("flags.zig");
const voila_runtime = @import("runtime").open;

pub const Parsed = struct {
    runtime_cfg: voila_runtime.Config,
    ref: voila_runtime.ContextRef,

    pub fn deinit(self: Parsed, allocator: std.mem.Allocator) void {
        allocator.free(self.runtime_cfg.store_root);
        allocator.free(self.ref.context_id);
    }
};

pub fn parseArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !Parsed {
    var root: ?[]const u8 = null;
    var kind = voila_runtime.kindFromEnv();
    var context_id: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (try flags.tryRuntimeFlag(allocator, arg, args, &root, &kind)) continue;
        if (context_id == null) {
            context_id = try allocator.dupe(u8, arg);
        }
    }
    const cid = context_id orelse return error.NeedContextId;
    return .{
        .runtime_cfg = try flags.finishRuntimeConfig(allocator, root, kind),
        .ref = .{ .context_id = cid },
    };
}

pub const KillParsed = struct {
    runtime_cfg: voila_runtime.Config,
    opts: voila_runtime.KillSpec,

    pub fn deinit(self: KillParsed, allocator: std.mem.Allocator) void {
        allocator.free(self.runtime_cfg.store_root);
        allocator.free(self.opts.context_id);
    }
};

pub fn parseKillArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !KillParsed {
    var root: ?[]const u8 = null;
    var kind = voila_runtime.kindFromEnv();
    var context_id: ?[]const u8 = null;
    var signal: i32 = 0;
    while (args.next()) |arg| {
        if (try flags.tryRuntimeFlag(allocator, arg, args, &root, &kind)) continue;
        if (context_id == null) {
            context_id = try allocator.dupe(u8, arg);
        } else {
            signal = std.fmt.parseInt(i32, arg, 10) catch continue;
        }
    }
    const cid = context_id orelse return error.NeedContextId;
    return .{
        .runtime_cfg = try flags.finishRuntimeConfig(allocator, root, kind),
        .opts = .{ .context_id = cid, .signal = signal },
    };
}
