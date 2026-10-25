const std = @import("std");
const flags = @import("flags.zig");
const voila_runtime = @import("runtime").open;

pub const Parsed = struct {
    runtime_cfg: voila_runtime.Config,
    context_id: []const u8,
    cmd: []const []const u8,
    tty: bool,
    interactive: bool,

    pub fn deinit(self: Parsed, allocator: std.mem.Allocator) void {
        allocator.free(self.runtime_cfg.store_root);
        allocator.free(self.context_id);
        for (self.cmd) |a| allocator.free(a);
        allocator.free(self.cmd);
    }
};

pub fn parseArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !Parsed {
    var root: ?[]const u8 = null;
    var kind = voila_runtime.kindFromEnv();
    var context_id: ?[]const u8 = null;
    var cmd_list: std.ArrayList([]const u8) = .empty;
    var after_sep = false;
    var tty = false;
    var interactive = false;
    while (args.next()) |arg| {
        if (after_sep) {
            try cmd_list.append(allocator, try allocator.dupe(u8, arg));
            continue;
        }
        if (context_id != null) {
            try cmd_list.append(allocator, try allocator.dupe(u8, arg));
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            after_sep = true;
            continue;
        }
        if (try flags.tryRuntimeFlag(allocator, arg, args, &root, &kind)) continue;
        if (std.mem.eql(u8, arg, "-i")) {
            interactive = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-t")) {
            tty = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-it") or std.mem.eql(u8, arg, "-ti")) {
            interactive = true;
            tty = true;
            continue;
        }
        if (context_id == null) {
            context_id = try allocator.dupe(u8, arg);
            continue;
        }
        return error.BadRunArgs;
    }
    const cid = context_id orelse return error.NeedContextId;
    if (cmd_list.items.len == 0) return error.NeedCommand;
    return .{
        .runtime_cfg = try flags.finishRuntimeConfig(allocator, root, kind),
        .context_id = cid,
        .cmd = try cmd_list.toOwnedSlice(allocator),
        .tty = tty,
        .interactive = interactive,
    };
}
