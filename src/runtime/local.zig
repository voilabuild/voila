const std = @import("std");
const iface = @import("./iface.zig");
const types = @import("./types.zig");
const container_run = @import("./oci/container_run.zig");
const container_exec = @import("./oci/container_exec.zig");
const container_lifecycle = @import("./oci/container_lifecycle.zig");
const registry_session = @import("registry").registry_session;
const voila_image_pull = @import("registry").voila_image_pull;
const voila_image_push = @import("registry").voila_image_push;
const voila_image_tag = @import("registry").voila_image_tag;
const voila_resolve = @import("registry").voila_resolve;
const voila_registry = @import("registry").voila_registry;
const posix_util = @import("sys").posix_util;
const voila_hub_import = @import("registry").voila_hub_import;
const voila_gc = @import("registry").voila_gc;
const container_store = @import("./oci/container_store.zig");

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
        if (voila_hub_import.formatMissingImageHelp(allocator, spec.image, cfg.token.len > 0)) |msg| {
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
    const target = try pushTarget(allocator, spec.image, cfg.org);
    defer allocator.free(target);
    if (!std.mem.eql(u8, target, spec.image)) {
        try voila_image_tag.tagImage(allocator, self.store_root, spec.image, target);
        std.debug.print("tagged {s} as {s}\n", .{ spec.image, target });
    }
    try voila_image_push.pushImage(io, allocator, self.store_root, cfg, target);
}

/// `VOILA_ORG` namespaces a push of a ref without an org (`alpine:3.20` -> `acme/alpine:3.20`).
fn pushTarget(allocator: std.mem.Allocator, ref: []const u8, org: []const u8) ![]u8 {
    const name_end = std.mem.indexOfAny(u8, ref, ":@") orelse ref.len;
    if (org.len == 0 or std.mem.indexOfScalar(u8, ref[0..name_end], '/') != null) return allocator.dupe(u8, ref);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ org, ref });
}

test "pushTarget prefixes VOILA_ORG only for org-less refs" {
    const a = std.testing.allocator;
    const cases = [_][3][]const u8{
        .{ "alpine:3.20", "acme", "acme/alpine:3.20" },
        .{ "saucisson/x:1", "acme", "saucisson/x:1" },
        .{ "alpine:3.20", "", "alpine:3.20" },
        .{ "alpine@sha256:ab", "acme", "acme/alpine@sha256:ab" },
    };
    for (cases) |c| {
        const got = try pushTarget(a, c[0], c[1]);
        defer a.free(got);
        try std.testing.expectEqualStrings(c[2], got);
    }
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
    if (try runningUser(allocator, self.store_root, spec.image)) |id| {
        defer allocator.free(id);
        std.debug.print("voila rmi: {s} is used by running container {s}; stop it first\n", .{ spec.image, id });
        return error.ImageInUse;
    }
    try voila_resolve.removeImage(allocator, self.store_root, spec.image);
    std.debug.print("Removed {s}\n", .{spec.image});
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const now: u64 = @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    const freed = voila_gc.collect(allocator, self.store_root, now, voila_gc.default_grace_ns) catch |e| {
        if (e == error.UnknownImageRoots) return; // an image without a cached manifest: keep all chunks
        return e;
    };
    if (freed.chunks > 0) std.debug.print("Freed {d} chunks ({d} MiB)\n", .{ freed.chunks, freed.bytes / (1024 * 1024) });
}

/// Id of a running container started from `image`, if any.
fn runningUser(allocator: std.mem.Allocator, voila_root: []const u8, image: []const u8) !?[]const u8 {
    const states = container_store.listStates(allocator, voila_root) catch return null;
    defer {
        for (states) |st| container_store.freeState(allocator, st);
        allocator.free(states);
    }
    const want = voila_resolve.resolveImage(allocator, voila_root, image) catch null;
    defer if (want) |r| {
        allocator.free(r.ref);
        allocator.free(r.image_digest);
        allocator.free(r.merged_root_manifest);
    };
    for (states) |st| {
        if (!container_lifecycle.isRunning(st)) continue;
        if (std.mem.eql(u8, st.image, image)) return try allocator.dupe(u8, st.id);
        if (want) |w| {
            const got = voila_resolve.resolveImage(allocator, voila_root, st.image) catch continue;
            defer {
                allocator.free(got.ref);
                allocator.free(got.image_digest);
                allocator.free(got.merged_root_manifest);
            }
            if (std.mem.eql(u8, got.image_digest, w.image_digest)) return try allocator.dupe(u8, st.id);
        }
    }
    return null;
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
    posix_util.printOut("REPOSITORY\n", .{});
    for (rows) |r| posix_util.printOut("{s}\n", .{r.ref});
}

fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const self: *Local = @ptrCast(@alignCast(ptr));
    allocator.free(self.store_root);
    allocator.destroy(self);
}
