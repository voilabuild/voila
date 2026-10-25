const std = @import("std");
const flags = @import("flags.zig");
const vfs_mod = @import("mount").fuse.vfs;
const fuse_vfs_mod = @import("mount").fuse.fuse_vfs;
const voila_vfs_mod = @import("mount").fuse.voila_vfs;
const fuse_linux = @import("mount").fuse.fuse_linux;
const posix_util = @import("sys").posix_util;
const constants = @import("core").constants;
const voila_loader = @import("runtime").voila_loader;

pub fn run(io: std.Io, init: std.process.Init, fixture_dir: []const u8) !void {
    try ensureFixture(init, fixture_dir);
    const fixture_abs = try flags.resolveAbs(init.gpa, fixture_dir);
    defer init.gpa.free(fixture_abs);
    var fixture_vfs = try vfs_mod.Vfs.load(init.gpa, fixture_abs);
    defer fixture_vfs.deinit();
    var fuse_vfs: fuse_vfs_mod.FuseVfs = .{ .fixture = fixture_vfs };
    if (!fuse_linux.canUseFuse()) {
        std.debug.print("skip: need root and /dev/fuse (read walker unit tests: zig build test)\n", .{});
        return;
    }
    try rootMountProve(io, init, &fuse_vfs);
}

pub fn runStore(io: std.Io, init: std.process.Init, voila_root: []const u8, image: []const u8) !void {
    if (!fuse_linux.canUseFuse()) {
        std.debug.print("skip: need root and /dev/fuse\n", .{});
        return;
    }
    const voila_root_abs = try flags.resolveAbs(init.gpa, voila_root);
    defer init.gpa.free(voila_root_abs);
    const index = try voila_loader.loadIndex(io, init.gpa, voila_root_abs, image);
    var fuse_vfs: fuse_vfs_mod.FuseVfs = .{ .voila = try voila_vfs_mod.VoilaVfs.initFromIndex(init.gpa, index) };
    defer fuse_vfs.deinit();
    fuse_vfs.voila.fetcher = voila_loader.fetcherFor(io);

    const mount_dir = try std.fmt.allocPrint(init.gpa, "/tmp/zig-fuse-store-mnt-{d}", .{std.c.getpid()});
    defer init.gpa.free(mount_dir);
    try posix_util.makePath(mount_dir);

    const ServeCtx = struct {
        session: fuse_linux.Session,
        err: ?anyerror,
    };
    var ctx: ServeCtx = .{
        .session = try fuse_linux.mountSession(init.gpa, mount_dir, &fuse_vfs),
        .err = null,
    };

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(shared: *ServeCtx) void {
            fuse_linux.serveSession(&shared.session) catch |e| {
                shared.err = e;
            };
        }
    }.run, .{&ctx});
    defer {
        ctx.session.stop();
        thread.join();
        ctx.session.deinit();
    }

    for (0..5000) |_| {
        if (mountDirReady(mount_dir)) break;
        try io.sleep(std.Io.Duration.fromMilliseconds(1), .awake);
    }

    try checkReaddirStore(init.gpa, mount_dir);

    if (fuse_vfs.inoFromPath("/bench/large.bin")) |_| {
        try verifyMountBytes(init.gpa, mount_dir, &fuse_vfs, "/bench/large.bin", 0, 32);
        try verifyMountBytes(init.gpa, mount_dir, &fuse_vfs, "/bench/large.bin", constants.chunk_size - 1, 2);
        std.debug.print("bench/large.bin: nested path + byte match at 0 and chunk boundary\n", .{});
    }

    try proveStoreDistroExtras(init.gpa, mount_dir);
    std.debug.print("prove-store: native index, mount, readdir, sample read — ok\n", .{});
}

fn rootMountProve(io: std.Io, init: std.process.Init, fuse_vfs: *fuse_vfs_mod.FuseVfs) !void {
    const mount_dir = try std.fmt.allocPrint(init.gpa, "/tmp/zig-fuse-mnt-{d}", .{std.c.getpid()});
    defer init.gpa.free(mount_dir);
    try posix_util.makePath(mount_dir);

    try fuse_vfs.preloadAllChunks(io);

    const ServeCtx = struct {
        session: fuse_linux.Session,
        fuse_vfs: *fuse_vfs_mod.FuseVfs,
        err: ?anyerror,
    };

    var ctx: ServeCtx = undefined;
    ctx.err = null;
    ctx.fuse_vfs = fuse_vfs;
    ctx.session = fuse_linux.mountSession(init.gpa, mount_dir, fuse_vfs) catch |e| return e;

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(shared: *ServeCtx) void {
            fuse_linux.serveSession(&shared.session) catch |e| {
                shared.err = e;
            };
        }
    }.run, .{&ctx});

    for (0..3000) |_| {
        if (dirHasEntries(mount_dir)) break;
        try io.sleep(std.Io.Duration.fromMilliseconds(1), .awake);
    }
    try checkReaddir(init.gpa, mount_dir);

    const link_target = try std.fmt.allocPrint(init.gpa, "{s}/link", .{mount_dir});
    defer init.gpa.free(link_target);
    const target = try readlinkAlloc(init.gpa, link_target);
    defer init.gpa.free(target);
    if (!std.mem.eql(u8, target, "big.bin")) return error.ReadlinkWrong;

    const big_path = try std.fmt.allocPrint(init.gpa, "{s}/big.bin", .{mount_dir});
    defer init.gpa.free(big_path);
    var pair: [2]u8 = undefined;
    try preadFile(big_path, &pair, constants.chunk_size - 1);
    std.debug.print("byte[1048575]=0x{x:02} byte[1048576]=0x{x:02}\n", .{ pair[0], pair[1] });
    if (pair[0] != 0xAA or pair[1] != 0xCC) return error.BoundaryBytesWrong;
    const big_z = try init.gpa.allocSentinel(u8, big_path.len, 0);
    defer init.gpa.free(big_z);
    @memcpy(big_z, big_path);
    const write_fd = std.c.open(big_z, .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
    if (write_fd >= 0) {
        _ = std.c.close(write_fd);
        return error.WriteShouldFail;
    }

    ctx.session.stop();
    thread.join();
    ctx.session.deinit();
    if (ctx.err != null) return ctx.err.?;
    std.debug.print("prove: readdir, readlink, boundary bytes, write EROFS — ok\n", .{});
}

fn proveStoreDistroExtras(allocator: std.mem.Allocator, mount_dir: []const u8) !void {
    const os_release = try std.fmt.allocPrint(allocator, "{s}/etc/os-release", .{mount_dir});
    defer allocator.free(os_release);
    if (posix_util.access(os_release)) {
        var hdr: [64]u8 = undefined;
        preadFile(os_release, &hdr, 0) catch return error.OsReleaseReadFailed;
        if (!std.mem.startsWith(u8, hdr[0..], "NAME=")) return error.OsReleaseWrong;
        std.debug.print("etc/os-release: {s}...\n", .{hdr[0..@min(hdr.len, 32)]});
    }

    const link_path = try std.fmt.allocPrint(allocator, "{s}/bin/arch", .{mount_dir});
    defer allocator.free(link_path);
    if (posix_util.access(link_path)) {
        const target = readlinkAlloc(allocator, link_path) catch return error.BusyboxLinkReadFailed;
        defer allocator.free(target);
        if (!std.mem.eql(u8, target, "/bin/busybox")) return error.BusyboxLinkWrong;
        std.debug.print("readlink bin/arch -> {s}\n", .{target});
    }
}

fn verifyMountBytes(
    allocator: std.mem.Allocator,
    mount_dir: []const u8,
    vfs: *fuse_vfs_mod.FuseVfs,
    vpath: []const u8,
    off: u64,
    len: usize,
) !void {
    const ino = vfs.inoFromPath(vpath) orelse return error.NoTestFile;
    var expect: [64]u8 = undefined;
    if (len > expect.len) return error.NoTestFile;
    const got = vfs.readFuse(ino, expect[0..len], off);
    if (got < len) return error.ShortRead;
    const rel = if (vpath.len > 0 and vpath[0] == '/') vpath[1..] else vpath;
    const mount_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ mount_dir, rel });
    defer allocator.free(mount_path);
    var fuse_buf: [64]u8 = undefined;
    try preadFile(mount_path, fuse_buf[0..len], off);
    if (!std.mem.eql(u8, expect[0..len], fuse_buf[0..len])) return error.BytesMismatch;
}

fn checkReaddirStore(allocator: std.mem.Allocator, mount_dir: []const u8) !void {
    const cmd = try std.fmt.allocPrint(allocator, "ls -1 {s} | head -5", .{mount_dir});
    defer allocator.free(cmd);
    const cmd_z = try allocator.allocSentinel(u8, cmd.len, 0);
    defer allocator.free(cmd_z);
    @memcpy(cmd_z, cmd);
    if (posix_util.shell(cmd_z) != 0) return error.ReaddirMissing;
}

fn checkReaddir(allocator: std.mem.Allocator, mount_dir: []const u8) !void {
    const cmd = try std.fmt.allocPrint(allocator, "ls -1 {s}", .{mount_dir});
    defer allocator.free(cmd);
    const cmd_z = try allocator.allocSentinel(u8, cmd.len, 0);
    defer allocator.free(cmd_z);
    @memcpy(cmd_z, cmd);
    const out_path = "/tmp/zig-fuse-readdir.txt";
    const full = try std.fmt.allocPrint(allocator, "{s} > {s}", .{ cmd, out_path });
    defer allocator.free(full);
    const full_z = try allocator.allocSentinel(u8, full.len, 0);
    defer allocator.free(full_z);
    @memcpy(full_z, full);
    if (posix_util.shell(full_z) != 0) return error.ReaddirMissing;
    const listing = try posix_util.readFileAlloc(allocator, out_path, 4096);
    defer allocator.free(listing);
    var has_big = false;
    var has_link = false;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "big.bin")) has_big = true;
        if (std.mem.eql(u8, line, "link")) has_link = true;
    }
    if (!has_big or !has_link) return error.ReaddirMissing;
}

fn mountDirReady(mount_dir: []const u8) bool {
    const cmd = std.fmt.allocPrint(std.heap.page_allocator, "ls -1 {s} 2>/dev/null | head -1", .{mount_dir}) catch return false;
    defer std.heap.page_allocator.free(cmd);
    const cmd_z = std.heap.page_allocator.allocSentinel(u8, cmd.len, 0) catch return false;
    defer std.heap.page_allocator.free(cmd_z);
    @memcpy(cmd_z, cmd);
    return posix_util.shell(cmd_z) == 0;
}

fn dirHasEntries(mount_dir: []const u8) bool {
    const probe = std.fmt.allocPrint(std.heap.page_allocator, "{s}/big.bin", .{mount_dir}) catch return false;
    defer std.heap.page_allocator.free(probe);
    return posix_util.access(probe);
}

fn readlinkAlloc(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var buf: [4096]u8 = undefined;
    const path_z = try allocator.allocSentinel(u8, path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, path);
    const n = std.c.readlink(path_z, &buf, buf.len);
    if (n < 0) {
        const err: std.posix.E = @fromBackingInt(@intCast(std.c._errno().*));
        if (err == .SUCCESS) return error.Unexpected;
        return std.posix.unexpectedErrno(err);
    }
    return allocator.dupe(u8, buf[0..@intCast(n)]);
}

fn preadFile(path: []const u8, buf: []u8, offset: u64) !void {
    const path_z = try std.heap.page_allocator.allocSentinel(u8, path.len, 0);
    defer std.heap.page_allocator.free(path_z);
    @memcpy(path_z, path);
    const fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) {
        const err: std.posix.E = @fromBackingInt(@intCast(std.c._errno().*));
        if (err == .SUCCESS) return error.Unexpected;
        return std.posix.unexpectedErrno(err);
    }
    defer _ = std.c.close(fd);
    const rc = std.c.pread(fd, buf.ptr, buf.len, @bitCast(@as(i64, @intCast(offset))));
    if (rc < 0) {
        const err: std.posix.E = @fromBackingInt(@intCast(std.c._errno().*));
        if (err == .SUCCESS) return error.Unexpected;
        return std.posix.unexpectedErrno(err);
    }
    if (@as(usize, @intCast(rc)) != buf.len) return error.ShortRead;
}

fn ensureFixture(init: std.process.Init, dir: []const u8) !void {
    const out_abs = try flags.resolveAbs(init.gpa, dir);
    defer init.gpa.free(out_abs);
    const tree = try std.fmt.allocPrint(init.gpa, "{s}/tree.txt", .{out_abs});
    defer init.gpa.free(tree);
    if (!posix_util.access(tree)) return error.FixtureNotFound;
}
