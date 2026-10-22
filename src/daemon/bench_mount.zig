const std = @import("std");
const posix_util = @import("posix_util");
const runtime = @import("runtime");
const voila_resolve = @import("voila_resolve");
const mount_backend = @import("mount_backend");
const erofs_mount = @import("erofs_mount");
const chunk_cache = @import("chunk_cache");
const registry_creds = @import("registry_creds");
const voila_registry = @import("voila_registry");

extern "c" fn clock_gettime(clk_id: i32, tp: *std.posix.timespec) i32;
const CLOCK_MONOTONIC: i32 = 1;

fn monotonicNs() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = clock_gettime(CLOCK_MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

pub fn benchOnce(
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    zig_fuse_bin: []const u8,
    image: []const u8,
    backend_name: []const u8,
    probe_rel: []const u8,
) !void {
    chunk_cache.install();
    const nbd_tree = @import("voilad_nbd").voila_tree;
    nbd_tree.prefetch_io = runtime.io;
    voila_registry.setIo(runtime.io, allocator);
    const creds = registry_creds.load(allocator, voila_root) catch registry_creds.RegistryCreds{ .registry = "", .token = "" };
    if (creds.registry.len != 0) {
        voila_registry.configure(allocator, creds.registry, creds.token) catch {};
    }
    const t0 = monotonicNs();

    const rec = try voila_resolve.resolveImage(allocator, voila_root, image);
    defer {
        allocator.free(rec.ref);
        allocator.free(rec.image_digest);
        allocator.free(rec.merged_root_manifest);
    }

    const mount_dir = "/tmp/zig-voilad-bench-mnt";
    try posix_util.makePath(mount_dir);
    erofs_mount.unmountLower(allocator, mount_dir);

    const use_erofs = std.ascii.eqlIgnoreCase(backend_name, "erofs");

    var fuse: ?std.process.Child = null;
    var nbd_session: ?*erofs_mount.NbdSession = null;
    defer {
        if (nbd_session) |s| s.stop();
        if (fuse) |*f| {
            f.kill(runtime.io);
            _ = f.wait(runtime.io) catch {};
        }
        erofs_mount.unmountLower(allocator, mount_dir);
        const nbd = @import("voilad_nbd");
        nbd.nbd_linux.disconnect(mount_backend.nbdDevicePath());
    }

    if (use_erofs) {
        nbd_session = try erofs_mount.mountStoreRoot(
            allocator,
            voila_root,
            rec.merged_root_manifest,
            mount_dir,
            mount_backend.nbdDevicePath(),
        );
    } else {
        fuse = try std.process.spawn(runtime.io, .{
            .argv = &[_][]const u8{ zig_fuse_bin, "serve-store", voila_root, rec.ref, mount_dir, "/dev/null", "0", "0" },
        });
    }

    const probe = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ mount_dir, probe_rel });
    defer allocator.free(probe);

    var ready = false;
    for (0..400) |_| {
        if (posix_util.access(probe)) {
            ready = true;
            break;
        }
        _ = posix_util.shell("sleep 0.01");
    }
    if (!ready) return error.RootfsNotReady;

    const data = try posix_util.readFileAlloc(allocator, probe, 1 << 20);
    defer allocator.free(data);
    if (data.len == 0) return error.EmptyProbe;

    const ms = @as(f64, @floatFromInt(monotonicNs() - t0)) / 1e6;
    const ms_thou = @as(u64, @intFromFloat(ms * 1000));
    std.debug.print("rootfs_ready_ms={d}.{d:0>3} backend={s} bytes={d}\n", .{
        ms_thou / 1000,
        ms_thou % 1000,
        backend_name,
        data.len,
    });
}
