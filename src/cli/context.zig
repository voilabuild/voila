const std = @import("std");
const flags = @import("flags.zig");
const voila_runtime = @import("runtime").open;

pub const Parsed = struct {
    runtime_cfg: voila_runtime.Config,
    refs: []voila_runtime.ContextRef,

    pub fn deinit(self: Parsed, allocator: std.mem.Allocator) void {
        allocator.free(self.runtime_cfg.store_root);
        for (self.refs) |r| allocator.free(r.context_id);
        allocator.free(self.refs);
    }
};

pub fn parseArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !Parsed {
    var root: ?[]const u8 = null;
    var kind = voila_runtime.kindFromEnv();
    var ids: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
        if (root) |r| allocator.free(r);
    }
    while (args.next()) |arg| {
        if (try flags.tryRuntimeFlag(allocator, arg, args, &root, &kind)) continue;
        try ids.append(allocator, try allocator.dupe(u8, arg));
    }
    if (ids.items.len == 0) return error.NeedContextId;
    const cfg = try flags.finishRuntimeConfig(allocator, root, kind);
    root = null;
    const refs = try allocator.alloc(voila_runtime.ContextRef, ids.items.len);
    for (ids.items, 0..) |id, i| refs[i] = .{ .context_id = id };
    ids.deinit(allocator);
    return .{ .runtime_cfg = cfg, .refs = refs };
}

pub const KillParsed = struct {
    runtime_cfg: voila_runtime.Config,
    ids: [][]const u8,
    signal: i32,

    pub fn deinit(self: KillParsed, allocator: std.mem.Allocator) void {
        allocator.free(self.runtime_cfg.store_root);
        for (self.ids) |id| allocator.free(id);
        allocator.free(self.ids);
    }
};

pub fn parseKillArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !KillParsed {
    var root: ?[]const u8 = null;
    var kind = voila_runtime.kindFromEnv();
    var ids: std.ArrayList([]const u8) = .empty;
    var signal: i32 = 0;
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
        if (root) |r| allocator.free(r);
    }
    while (args.next()) |arg| {
        if (try flags.tryRuntimeFlag(allocator, arg, args, &root, &kind)) continue;
        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--signal")) {
            const n = args.next() orelse return error.BadRunArgs;
            signal = std.fmt.parseInt(i32, n, 10) catch return error.BadRunArgs;
            continue;
        }
        try ids.append(allocator, try allocator.dupe(u8, arg));
    }
    if (ids.items.len == 0) return error.NeedContextId;
    const cfg = try flags.finishRuntimeConfig(allocator, root, kind);
    root = null;
    return .{
        .runtime_cfg = cfg,
        .ids = try ids.toOwnedSlice(allocator),
        .signal = signal,
    };
}

test "parseArgs keeps every container id" {
    const alloc = std.testing.allocator;
    const argv: []const [*:0]const u8 = &.{ "--root", "/voila-test-root", "a", "b" };
    var it = std.process.Args.Iterator.init(.{ .vector = argv });
    const parsed = try parseArgs(alloc, &it);
    defer parsed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), parsed.refs.len);
    try std.testing.expectEqualStrings("a", parsed.refs[0].context_id);
    try std.testing.expectEqualStrings("b", parsed.refs[1].context_id);
}
