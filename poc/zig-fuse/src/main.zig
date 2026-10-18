const std = @import("std");
const zio = @import("zio");
const vfs_mod = @import("vfs.zig");
const fuse_vfs_mod = @import("fuse_vfs.zig");
const voila_vfs_mod = @import("voila_vfs.zig");
const fuse_linux = @import("fuse_linux.zig");
const posix_util = @import("posix_util.zig");
const constants = @import("constants.zig");
const voila_loader = @import("voila_loader.zig");
const voila_registry = @import("voila_registry.zig");
const voila_registry_creds = @import("voila_registry_creds.zig");
const voila_fetch_stats = @import("voila_fetch_stats.zig");
const voila_runtime = @import("runtime/open.zig");
const voila_refkey = @import("voila_refkey.zig");
const _voila_image_pull = @import("voila_image_pull.zig");
const _registry_session = @import("registry_session.zig");

pub const std_options_debug_io = zio.debug_io;

pub fn main(init: std.process.Init) !void {
    const zio_rt = try zio.Runtime.init(init.gpa, .{});
    defer zio_rt.deinit();
    const io = zio_rt.io();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const sub = args.next() orelse "prove";

    if (std.mem.eql(u8, sub, "prove")) {
        const fixture_dir = args.next() orelse "fixture-out";
        try prove(io, init, fixture_dir);
        return;
    }
    if (std.mem.eql(u8, sub, "prove-store")) {
        const voila_root = args.next() orelse return error.NeedVoilaRoot;
        const image = args.next() orelse return error.NeedImage;
        try proveStore(io, init, voila_root, image);
        return;
    }
    if (std.mem.eql(u8, sub, "serve")) {
        const fixture_dir = args.next() orelse "fixture-out";
        const mountpoint = args.next() orelse return error.NeedMountpoint;
        const fixture_abs = try resolveAbs(init.gpa, fixture_dir);
        defer init.gpa.free(fixture_abs);
        var fixture_vfs = try vfs_mod.Vfs.load(init.gpa, fixture_abs);
        defer fixture_vfs.deinit();
        try fixture_vfs.preloadAllChunks(io);
        var fuse_vfs: fuse_vfs_mod.FuseVfs = .{ .fixture = fixture_vfs };
        try fuse_linux.mountAndServe(io, init.gpa, &fuse_vfs, mountpoint);
        return;
    }
    if (std.mem.eql(u8, sub, "serve-index")) {
        const index_path = args.next() orelse return error.NeedIndex;
        const mountpoint = args.next() orelse return error.NeedMountpoint;
        var voila_vfs = try voila_vfs_mod.VoilaVfs.load(init.gpa, index_path);
        defer voila_vfs.deinit();
        var fuse_vfs: fuse_vfs_mod.FuseVfs = .{ .voila = voila_vfs };
        try fuse_linux.mountAndServe(io, init.gpa, &fuse_vfs, mountpoint);
        return;
    }
    if (std.mem.eql(u8, sub, "run")) {
        const parsed = try parseRunArgs(init.gpa, &args);
        defer parsed.deinit(init.gpa);
        var worker = try openRuntime(init.gpa, parsed.runtime_cfg);
        defer worker.deinit(init.gpa);
        const code = try worker.run(io, init.gpa, .{ .image = parsed.image, .argv = parsed.cmd });
        std.process.exit(code);
    }
    if (std.mem.eql(u8, sub, "ps")) {
        const cfg = try parseRuntimeOnlyArgs(init.gpa, &args);
        defer init.gpa.free(cfg.store_root);
        var worker = try openRuntime(init.gpa, cfg);
        defer worker.deinit(init.gpa);
        worker.ps(io, init.gpa) catch |e| {
            if (e == voila_runtime.Error.NotImplemented) std.process.exit(2);
            return e;
        };
        return;
    }
    if (std.mem.eql(u8, sub, "logs")) {
        const parsed = try parseLogsArgs(init.gpa, &args);
        defer parsed.deinit(init.gpa);
        var worker = try openRuntime(init.gpa, parsed.runtime_cfg);
        defer worker.deinit(init.gpa);
        worker.logs(io, init.gpa, parsed.opts) catch |e| {
            if (e == voila_runtime.Error.NotImplemented) std.process.exit(2);
            return e;
        };
        return;
    }
    if (std.mem.eql(u8, sub, "pull")) {
        const parsed = try parsePullArgs(init.gpa, &args);
        defer init.gpa.free(parsed.runtime_cfg.store_root);
        defer init.gpa.free(parsed.image);
        var worker = try openRuntime(init.gpa, parsed.runtime_cfg);
        defer worker.deinit(init.gpa);
        try worker.pull(io, init.gpa, .{ .image = parsed.image });
        return;
    }
    if (std.mem.eql(u8, sub, "images")) {
        const cfg = try parseRuntimeOnlyArgs(init.gpa, &args);
        defer init.gpa.free(cfg.store_root);
        var worker = try openRuntime(init.gpa, cfg);
        defer worker.deinit(init.gpa);
        try worker.images(io, init.gpa);
        return;
    }
    if (std.mem.eql(u8, sub, "kill")) {
        const parsed = try parseKillArgs(init.gpa, &args);
        defer init.gpa.free(parsed.runtime_cfg.store_root);
        defer init.gpa.free(parsed.opts.context_id);
        var worker = try openRuntime(init.gpa, parsed.runtime_cfg);
        defer worker.deinit(init.gpa);
        worker.kill(io, init.gpa, parsed.opts) catch |e| {
            if (e == voila_runtime.Error.NotImplemented) std.process.exit(2);
            return e;
        };
        return;
    }
    if (std.mem.eql(u8, sub, "serve-store")) {
        const voila_root = args.next() orelse return error.NeedVoilaRoot;
        const image = args.next() orelse return error.NeedImage;
        const mountpoint = args.next() orelse return error.NeedMountpoint;
        const stats_path_arg = args.next();
        const voila_root_abs = try resolveAbs(init.gpa, voila_root);
        defer init.gpa.free(voila_root_abs);
        voila_registry.setIo(io, init.gpa);
        try voila_registry_creds.loadFromCredsFile(init.gpa, voila_root_abs);
        try voila_registry.loadFromEnv(init.gpa);
        voila_fetch_stats.init(init.gpa, stats_path_arg);
        defer voila_fetch_stats.writeStatsFile();
        const chunks_arg = args.next();
        const bytes_arg = args.next();
        if (chunks_arg) |c| {
            const chunks = std.fmt.parseInt(u64, c, 10) catch 0;
            var bytes: u64 = 0;
            if (bytes_arg) |b| bytes = std.fmt.parseInt(u64, b, 10) catch 0;
            voila_fetch_stats.setImageTotals(chunks, bytes);
        }
        const tree = try voila_loader.loadTreeRoot(init.gpa, voila_root_abs, image);
        var fuse_vfs: fuse_vfs_mod.FuseVfs = .{ .voila = voila_vfs_mod.VoilaVfs.initFromTree(init.gpa, tree) };
        defer fuse_vfs.deinit();
        try fuse_linux.mountAndServe(io, init.gpa, &fuse_vfs, mountpoint);
        return;
    }
    std.debug.print(
        "usage:\n  zig-fuse run [-root <dir>] [-backend local|remote] <image-ref> -- <cmd> [args...]\n  zig-fuse ps|logs|kill [-root <dir>] [-backend local|remote] ...\n  zig-fuse prove [fixture-dir]\n  zig-fuse prove-store <voila-root> <image>\n  zig-fuse serve-store <voila-root> <image-ref> <mountpoint>\n",
        .{},
    );
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

fn prove(io: std.Io, init: std.process.Init, fixture_dir: []const u8) !void {
    try ensureFixture(init, fixture_dir);
    const fixture_abs = try resolveAbs(init.gpa, fixture_dir);
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

fn proveStore(io: std.Io, init: std.process.Init, voila_root: []const u8, image: []const u8) !void {
    if (!fuse_linux.canUseFuse()) {
        std.debug.print("skip: need root and /dev/fuse\n", .{});
        return;
    }
    const voila_root_abs = try resolveAbs(init.gpa, voila_root);
    defer init.gpa.free(voila_root_abs);
    const index = try voila_loader.loadIndex(init.gpa, voila_root_abs, image);
    var fuse_vfs: fuse_vfs_mod.FuseVfs = .{ .voila = try voila_vfs_mod.VoilaVfs.initFromIndex(init.gpa, index) };
    defer fuse_vfs.deinit();

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

fn fusermountU(allocator: std.mem.Allocator, mount_dir: []const u8) !void {
    const cmd = try std.fmt.allocPrint(allocator, "fusermount3 -u {s} 2>/dev/null || umount {s}", .{ mount_dir, mount_dir });
    defer allocator.free(cmd);
    const cmd_z = try allocator.allocSentinel(u8, cmd.len, 0);
    defer allocator.free(cmd_z);
    @memcpy(cmd_z, cmd);
    _ = posix_util.shell(cmd_z);
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
        const err: std.posix.E = @enumFromInt(std.c._errno().*);
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
        const err: std.posix.E = @enumFromInt(std.c._errno().*);
        if (err == .SUCCESS) return error.Unexpected;
        return std.posix.unexpectedErrno(err);
    }
    defer _ = std.c.close(fd);
    const rc = std.c.pread(fd, buf.ptr, buf.len, @bitCast(@as(i64, @intCast(offset))));
    if (rc < 0) {
        const err: std.posix.E = @enumFromInt(std.c._errno().*);
        if (err == .SUCCESS) return error.Unexpected;
        return std.posix.unexpectedErrno(err);
    }
    if (@as(usize, @intCast(rc)) != buf.len) return error.ShortRead;
}

fn ensureFixture(init: std.process.Init, dir: []const u8) !void {
    const out_abs = try resolveAbs(init.gpa, dir);
    defer init.gpa.free(out_abs);
    const tree = try std.fmt.allocPrint(init.gpa, "{s}/tree.txt", .{out_abs});
    defer init.gpa.free(tree);
    if (posix_util.access(tree)) return;

    try posix_util.makePath(out_abs);
    const voila_root = try findVoilaRoot(init.gpa);
    defer init.gpa.free(voila_root);
    const cmd = try std.fmt.allocPrint(init.gpa, "cd {s} && go run -tags zig_fuse_fixture ./poc/zig-fuse/fixture -o {s}", .{ voila_root, out_abs });
    defer init.gpa.free(cmd);
    const cmd_z = try init.gpa.allocSentinel(u8, cmd.len, 0);
    defer init.gpa.free(cmd_z);
    @memcpy(cmd_z, cmd);
    const rc = posix_util.shell(cmd_z);
    if (rc != 0) return error.FixtureFailed;
}

fn openRuntime(allocator: std.mem.Allocator, cfg: voila_runtime.Config) !voila_runtime.Runtime {
    return voila_runtime.open(allocator, cfg);
}

fn parseBackendArg(arg: []const u8) ?voila_runtime.Kind {
    if (std.mem.eql(u8, arg, "local")) return .local;
    if (std.mem.eql(u8, arg, "remote")) return .remote;
    return null;
}

fn resolveStoreRoot(allocator: std.mem.Allocator, root: ?[]const u8) ![]const u8 {
    const r = root orelse blk: {
        const p = std.c.getenv("VOILA_ROOT") orelse return error.NeedVoilaRoot;
        break :blk std.mem.span(p);
    };
    return resolveAbs(allocator, r);
}

const PullParsed = struct {
    runtime_cfg: voila_runtime.Config,
    image: []const u8,
};

fn parsePullArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !PullParsed {
    var root: ?[]const u8 = null;
    var kind = voila_runtime.kindFromEnv();
    var image: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-root")) {
            const r = args.next() orelse return error.NeedVoilaRoot;
            root = try allocator.dupe(u8, r);
        } else if (std.mem.eql(u8, arg, "-backend")) {
            const b = args.next() orelse return error.BadRunArgs;
            kind = parseBackendArg(b) orelse return error.BadRunArgs;
        } else if (image == null) {
            image = try allocator.dupe(u8, arg);
        } else {
            return error.BadRunArgs;
        }
    }
    const img = image orelse return error.NeedImage;
    const root_abs = try resolveStoreRoot(allocator, root);
    if (root) |owned| allocator.free(owned);
    return .{
        .runtime_cfg = .{ .kind = kind, .store_root = root_abs },
        .image = img,
    };
}

const RunParsed = struct {
    runtime_cfg: voila_runtime.Config,
    image: []const u8,
    cmd: []const []const u8,

    fn deinit(self: RunParsed, allocator: std.mem.Allocator) void {
        allocator.free(self.runtime_cfg.store_root);
        allocator.free(self.image);
        for (self.cmd) |a| allocator.free(a);
        allocator.free(self.cmd);
    }
};

fn parseRunArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !RunParsed {
    var root: ?[]const u8 = null;
    var kind = voila_runtime.kindFromEnv();
    var image: ?[]const u8 = null;
    var cmd_list: std.ArrayList([]const u8) = .empty;
    var after_sep = false;
    while (args.next()) |arg| {
        if (after_sep) {
            try cmd_list.append(allocator, try allocator.dupe(u8, arg));
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            after_sep = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-root")) {
            const r = args.next() orelse return error.NeedVoilaRoot;
            root = try allocator.dupe(u8, r);
            continue;
        }
        if (std.mem.eql(u8, arg, "-backend")) {
            const b = args.next() orelse return error.BadRunArgs;
            kind = parseBackendArg(b) orelse return error.BadRunArgs;
            continue;
        }
        if (root == null and image == null and !voila_refkey.looksLikeRef(arg)) {
            root = try allocator.dupe(u8, arg);
            continue;
        }
        if (image == null) {
            image = try allocator.dupe(u8, arg);
            continue;
        }
        return error.BadRunArgs;
    }

    var image_ref = image;
    if (image_ref == null and root != null and voila_refkey.looksLikeRef(root.?)) {
        image_ref = root;
        root = null;
    }
    const image_final = image_ref orelse return error.NeedImage;
    if (cmd_list.items.len == 0) return error.NeedCommand;

    const root_abs = try resolveStoreRoot(allocator, root);
    if (root) |owned| allocator.free(owned);

    return .{
        .runtime_cfg = .{ .kind = kind, .store_root = root_abs },
        .image = image_final,
        .cmd = try cmd_list.toOwnedSlice(allocator),
    };
}

fn parseRuntimeOnlyArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !voila_runtime.Config {
    var root: ?[]const u8 = null;
    var kind = voila_runtime.kindFromEnv();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-root")) {
            const r = args.next() orelse return error.NeedVoilaRoot;
            root = try allocator.dupe(u8, r);
        } else if (std.mem.eql(u8, arg, "-backend")) {
            const b = args.next() orelse return error.BadRunArgs;
            kind = parseBackendArg(b) orelse return error.BadRunArgs;
        }
    }
    const root_abs = try resolveStoreRoot(allocator, root);
    if (root) |owned| allocator.free(owned);
    return .{ .kind = kind, .store_root = root_abs };
}

const LogsParsed = struct {
    runtime_cfg: voila_runtime.Config,
    opts: voila_runtime.LogsOptions,

    fn deinit(self: LogsParsed, allocator: std.mem.Allocator) void {
        allocator.free(self.runtime_cfg.store_root);
        allocator.free(self.opts.context_id);
    }
};

fn parseLogsArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !LogsParsed {
    var root: ?[]const u8 = null;
    var kind = voila_runtime.kindFromEnv();
    var follow = false;
    var context_id: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-root")) {
            const r = args.next() orelse return error.NeedVoilaRoot;
            root = try allocator.dupe(u8, r);
        } else if (std.mem.eql(u8, arg, "-backend")) {
            const b = args.next() orelse return error.BadRunArgs;
            kind = parseBackendArg(b) orelse return error.BadRunArgs;
        } else if (std.mem.eql(u8, arg, "-follow")) {
            follow = true;
        } else if (context_id == null) {
            context_id = try allocator.dupe(u8, arg);
        }
    }
    const cid = context_id orelse return error.NeedContextId;
    const root_abs = try resolveStoreRoot(allocator, root);
    if (root) |owned| allocator.free(owned);
    return .{
        .runtime_cfg = .{ .kind = kind, .store_root = root_abs },
        .opts = .{ .context_id = cid, .follow = follow },
    };
}

const KillParsed = struct {
    runtime_cfg: voila_runtime.Config,
    opts: voila_runtime.KillSpec,
};

fn parseKillArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !KillParsed {
    var root: ?[]const u8 = null;
    var kind = voila_runtime.kindFromEnv();
    var context_id: ?[]const u8 = null;
    var signal: i32 = 0;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-root")) {
            const r = args.next() orelse return error.NeedVoilaRoot;
            root = try allocator.dupe(u8, r);
        } else if (std.mem.eql(u8, arg, "-backend")) {
            const b = args.next() orelse return error.BadRunArgs;
            kind = parseBackendArg(b) orelse return error.BadRunArgs;
        } else if (context_id == null) {
            context_id = try allocator.dupe(u8, arg);
        } else {
            signal = std.fmt.parseInt(i32, arg, 10) catch continue;
        }
    }
    const cid = context_id orelse return error.NeedContextId;
    const root_abs = try resolveStoreRoot(allocator, root);
    if (root) |owned| allocator.free(owned);
    return .{
        .runtime_cfg = .{ .kind = kind, .store_root = root_abs },
        .opts = .{ .context_id = cid, .signal = signal },
    };
}

fn resolveAbs(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (path.len > 0 and path[0] == '/') return allocator.dupe(u8, path);
    var cwd: [4096]u8 = undefined;
    const cwd_rc = std.os.linux.getcwd(cwd[0..].ptr, cwd.len);
    const cwd_err = std.posix.errno(cwd_rc);
    if (cwd_err != .SUCCESS) return allocator.dupe(u8, path);
    const cwd_slice = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(cwd[0..].ptr)), 0);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd_slice, path });
}

fn findVoilaRoot(allocator: std.mem.Allocator) ![]const u8 {
    const seeds = [_][]const u8{
        "/agent/repos/voila",
        "../../..",
        "../..",
    };
    for (seeds) |seed| {
        const gomod = try std.fmt.allocPrint(allocator, "{s}/go.mod", .{seed});
        defer allocator.free(gomod);
        if (posix_util.access(gomod)) return allocator.dupe(u8, seed);
    }
    return error.NoVoilaRoot;
}
