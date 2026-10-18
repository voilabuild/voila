const std = @import("std");
const iface = @import("iface.zig");
const types = @import("types.zig");
const run_attached = @import("../run_attached.zig");
const registry_session = @import("../registry_session.zig");
const voila_image_pull = @import("../voila_image_pull.zig");
const voila_resolve = @import("../voila_resolve.zig");
const voila_registry = @import("../voila_registry.zig");

const Local = struct {
    store_root: []const u8,
};

pub fn open(allocator: std.mem.Allocator, store_root: []const u8) !iface.Runtime {
    const self = try allocator.create(Local);
    self.* = .{ .store_root = try allocator.dupe(u8, store_root) };
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

const vtable: iface.Runtime.VTable = .{
    .run = runImpl,
    .ps = notImplPs,
    .logs = notImplLogs,
    .kill = notImplKill,
    .pull = pullImpl,
    .images = imagesImpl,
    .deinit = deinitImpl,
};

fn runImpl(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, spec: types.RunSpec) !u8 {
    const self: *Local = @ptrCast(@alignCast(ptr));
    return run_attached.run(io, allocator, self.store_root, spec.image, spec.argv);
}

fn notImplPs(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator) !void {
    _ = ptr;
    std.debug.print("local runtime: ps requires detached containers (not implemented)\n", .{});
    return iface.Error.NotImplemented;
}

fn notImplLogs(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator, _: types.LogsOptions) !void {
    _ = ptr;
    std.debug.print("local runtime: logs requires detached containers (not implemented)\n", .{});
    return iface.Error.NotImplemented;
}

fn notImplKill(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator, _: types.KillSpec) !void {
    _ = ptr;
    return iface.Error.NotImplemented;
}

fn pullImpl(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, spec: types.PullSpec) !void {
    const self: *Local = @ptrCast(@alignCast(ptr));
    try registry_session.prepare(io, allocator, self.store_root);
    const cfg = voila_registry.getConfigCopy(allocator) orelse return iface.Error.NoRegistry;
    defer {
        allocator.free(cfg.base_url);
        allocator.free(cfg.token);
    }
    const man = try voila_image_pull.pullManifest(io, allocator, self.store_root, cfg, spec.image);
    defer {
        allocator.free(man.image_ref);
        allocator.free(man.image_digest);
        allocator.free(man.merged_root);
    }
    std.debug.print("pulled {s}\n", .{spec.image});
}

fn imagesImpl(ptr: *anyopaque, _: std.Io, allocator: std.mem.Allocator) !void {
    const self: *Local = @ptrCast(@alignCast(ptr));
    const rows = try voila_resolve.listImagesInStore(allocator, self.store_root);
    defer {
        for (rows) |r| {
            allocator.free(r.ref);
            allocator.free(r.image_digest);
            allocator.free(r.merged_root_manifest);
        }
        allocator.free(rows);
    }
    std.debug.print("REPOSITORY\n", .{});
    for (rows) |r| std.debug.print("{s}\n", .{r.ref});
}

fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const self: *Local = @ptrCast(@alignCast(ptr));
    allocator.free(self.store_root);
    allocator.destroy(self);
}
