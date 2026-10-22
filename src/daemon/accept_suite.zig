const std = @import("std");
const posix_util = @import("posix_util");
const runtime = @import("runtime");
const voila_resolve = @import("voila_resolve");
const mount_backend = @import("mount_backend");
const erofs_mount = @import("erofs_mount");
const chunk_cache = @import("chunk_cache");
const registry_creds = @import("registry_creds");
const voila_registry = @import("voila_registry");

pub fn acceptSuite(
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    zig_fuse_bin: []const u8,
    image: []const u8,
    backend_name: []const u8,
    cases_script: []const u8,
    golden_dir: []const u8,
) !void {
    chunk_cache.install();
    const nbd_tree = @import("voilad_nbd").voila_tree;
    nbd_tree.prefetch_io = runtime.io;
    voila_registry.setIo(runtime.io, allocator);
    const creds = registry_creds.load(allocator, voila_root) catch registry_creds.RegistryCreds{ .registry = "", .token = "" };
    if (creds.registry.len != 0) {
        voila_registry.configure(allocator, creds.registry, creds.token) catch {};
    }

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

    const python = try std.fmt.allocPrint(allocator, "{s}/usr/local/bin/python3", .{mount_dir});
    defer allocator.free(python);

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

    var ready = false;
    for (0..600) |_| {
        if (posix_util.access(python)) {
            ready = true;
            break;
        }
        _ = posix_util.shell("sleep 0.05");
    }
    if (!ready) return error.RootfsNotReady;

    const backend_label = if (use_erofs) "zig-erofs" else "zig-fuse";
    const cmd = try std.fmt.allocPrint(
        allocator,
        "VOILA_ACCEPT_BACKEND={s} bash {s} {s} {s}",
        .{ backend_label, cases_script, mount_dir, golden_dir },
    );
    defer allocator.free(cmd);
    const cmd_z = try allocator.allocSentinel(u8, cmd.len, 0);
    defer allocator.free(cmd_z);
    @memcpy(cmd_z, cmd);
    if (posix_util.shell(cmd_z) != 0) return error.AcceptCasesFailed;
}

pub const Error = error{
    RootfsNotReady,
    AcceptCasesFailed,
};
