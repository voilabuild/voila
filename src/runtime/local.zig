const std = @import("std");
const iface = @import("./iface.zig");
const types = @import("./types.zig");
const container_run = @import("./oci/container_run.zig");
const container_exec = @import("./oci/container_exec.zig");
const container_lifecycle = @import("./oci/container_lifecycle.zig");
const registry_session = @import("../registry/registry_session.zig");
const voila_image_pull = @import("../registry/voila_image_pull.zig");
const voila_image_push = @import("../registry/voila_image_push.zig");
const voila_resolve = @import("./voila_resolve.zig");
const voila_registry = @import("../registry/voila_registry.zig");
const voila_hub_import = @import("../registry/voila_hub_import.zig");

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
    .ps = psImpl,
    .logs = logsImpl,
    .kill = killImpl,
    .stop = stopImpl,
    .rm = rmImpl,
    .pull = pullImpl,
    .push = pushImpl,
    .images = imagesImpl,
    .exec = execImpl,
    .rmi = rmiImpl,
    .deinit = deinitImpl,
};

fn runImpl(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, spec: types.RunSpec) !u8 {
    const self: *Local = @ptrCast(@alignCast(ptr));
    return container_run.run(io, allocator, self.store_root, spec);
}

fn psImpl(ptr: *anyopaque, _: std.Io, allocator: std.mem.Allocator) !void {
    const self: *Local = @ptrCast(@alignCast(ptr));
    return container_lifecycle.ps(allocator, self.store_root);
}

fn logsImpl(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, opts: types.LogsOptions) !void {
    const self: *Local = @ptrCast(@alignCast(ptr));
    return container_lifecycle.logs(io, allocator, self.store_root, opts.context_id, opts.follow);
}

fn killImpl(ptr: *anyopaque, _: std.Io, allocator: std.mem.Allocator, spec: types.KillSpec) !void {
    const self: *Local = @ptrCast(@alignCast(ptr));
    return container_lifecycle.kill(allocator, self.store_root, spec.context_id, spec.signal);
}

fn stopImpl(ptr: *anyopaque, _: std.Io, allocator: std.mem.Allocator, ref: types.ContextRef) !void {
    const self: *Local = @ptrCast(@alignCast(ptr));
    return container_lifecycle.stop(allocator, self.store_root, ref.context_id);
}

fn rmImpl(ptr: *anyopaque, _: std.Io, allocator: std.mem.Allocator, ref: types.ContextRef) !void {
    const self: *Local = @ptrCast(@alignCast(ptr));
    return container_lifecycle.rm(allocator, self.store_root, ref.context_id);
}

fn pullImpl(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, spec: types.PullSpec) !void {
    const self: *Local = @ptrCast(@alignCast(ptr));
    try registry_session.prepare(io, allocator, self.store_root);
    const cfg = voila_registry.getConfigCopy(allocator) orelse return iface.Error.NoRegistry;
    defer {
        allocator.free(cfg.base_url);
        allocator.free(cfg.token);
        allocator.free(cfg.org);
    }
    const man = voila_image_pull.pullManifest(io, allocator, self.store_root, cfg, spec.image) catch |e| {
        if (voila_hub_import.formatMissingImageHelp(allocator, spec.image, cfg.org)) |msg| {
            defer allocator.free(msg);
            std.debug.print("{s}\n", .{msg});
        } else |_| {}
        return e;
    };
    defer {
        allocator.free(man.image_ref);
        allocator.free(man.image_digest);
        allocator.free(man.merged_root);
    }
    std.debug.print("pulled {s}\n", .{spec.image});
}

fn pushImpl(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, spec: types.PushSpec) !void {
    const self: *Local = @ptrCast(@alignCast(ptr));
    try registry_session.prepare(io, allocator, self.store_root);
    const cfg = voila_registry.getConfigCopy(allocator) orelse return iface.Error.NoRegistry;
    defer {
        allocator.free(cfg.base_url);
        allocator.free(cfg.token);
        allocator.free(cfg.org);
    }
    try voila_image_push.pushImage(io, allocator, self.store_root, cfg, spec.image);
}

fn execImpl(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, spec: types.ExecSpec) !u8 {
    const self: *Local = @ptrCast(@alignCast(ptr));
    return container_exec.exec(io, allocator, self.store_root, .{
        .context_id = spec.context_id,
        .argv = spec.argv,
        .tty = spec.tty,
        .interactive = spec.interactive,
    });
}

fn rmiImpl(ptr: *anyopaque, _: std.Io, allocator: std.mem.Allocator, spec: types.RmiSpec) !void {
    const self: *Local = @ptrCast(@alignCast(ptr));
    try voila_resolve.removeImage(allocator, self.store_root, spec.image);
    std.debug.print("Removed {s}\n", .{spec.image});
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
