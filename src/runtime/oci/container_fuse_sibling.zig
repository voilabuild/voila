//! Run libfuse in a child process so the parent can chroot into the mount without deadlocking.
const std = @import("std");
const fuse_linux = @import("mount").fuse.fuse_linux;
const fuse_vfs_mod = @import("mount").fuse.fuse_vfs;
const voila_vfs_mod = @import("mount").fuse.voila_vfs;
const FetchPool = @import("mount").fuse.chunk_fetch_pool.FetchPool;
const voila_loader = @import("../voila_loader.zig");
const voila_registry = @import("registry").voila_registry;
const voila_registry_creds = @import("registry").voila_registry_creds;
const voila_login_creds = @import("registry").voila_login_creds;
const mount_exec = @import("mount").mount_exec;
const posix_util = @import("sys").posix_util;
const fusermount = @import("sys").fusermount;
const idmap = @import("core").idmap;

/// libfuse worker threads; each can wait on its own chunk fetch.
const fuse_threads = 16;

const ServeCtx = struct {
    session: fuse_linux.Session,
    err: ?anyerror,
};

pub const Handle = struct {
    pid: std.c.pid_t,
    stop_w: std.posix.fd_t,
    mount_dir: []const u8,
    allocator: std.mem.Allocator,

    /// Closing the stop pipe makes the server unmount and exit; it is killed only if it
    /// has not exited after a few seconds.
    pub fn deinit(self: *Handle) void {
        if (self.stop_w >= 0) _ = std.c.close(self.stop_w);
        self.stop_w = -1;
        if (self.pid > 0) {
            var status: i32 = 0;
            var exited = false;
            for (0..300) |_| {
                if (std.c.waitpid(self.pid, &status, std.c.W.NOHANG) == self.pid) {
                    exited = true;
                    break;
                }
                posix_util.sleepMs(10);
            }
            if (!exited) {
                _ = std.c.kill(self.pid, std.c.SIG.KILL);
                _ = std.c.waitpid(self.pid, &status, 0);
            }
            self.pid = 0;
        }
        unmountQuietly(self.mount_dir);
        self.allocator.free(self.mount_dir);
    }

    pub fn alive(self: *const Handle) bool {
        if (self.pid <= 0) return false;
        var status: i32 = 0;
        const r = std.c.waitpid(self.pid, &status, std.c.W.NOHANG);
        if (r == self.pid) return false;
        return true;
    }
};

pub const Options = struct {
    /// Present image uid/gid 0 as the calling user (rootless writes through overlayfs).
    map_root: bool = false,
    /// With `map_root`: also present image ids 1..N as these subordinate host ranges.
    subuid: ?idmap.Range = null,
    subgid: ?idmap.Range = null,
};

pub fn start(
    io: std.Io,
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    image: []const u8,
    mount_dir: []const u8,
) !Handle {
    return startWith(io, allocator, voila_root, image, mount_dir, .{});
}

pub fn startWith(
    _: std.Io,
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    image: []const u8,
    mount_dir: []const u8,
    opts: Options,
) !Handle {
    var ready: [2]std.posix.fd_t = undefined;
    var stop: [2]std.posix.fd_t = undefined;
    // CLOEXEC: the server gets its ends through exec arguments after fork clears the flag,
    // and later children (the container itself) must not hold the stop pipe open.
    if (std.c.pipe2(&ready, .{ .CLOEXEC = true }) != 0) return error.PipeFailed;
    if (std.c.pipe2(&stop, .{ .CLOEXEC = true }) != 0) {
        _ = std.c.close(ready[0]);
        _ = std.c.close(ready[1]);
        return error.PipeFailed;
    }
    const exe = posix_util.selfExePath(allocator) catch return error.ForkFailed;
    defer allocator.free(exe);
    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(ready[0]);
        _ = std.c.close(ready[1]);
        _ = std.c.close(stop[0]);
        _ = std.c.close(stop[1]);
        return error.ForkFailed;
    }
    if (pid == 0) {
        _ = std.c.close(ready[0]);
        _ = std.c.close(stop[1]);
        clearCloexec(ready[1]);
        clearCloexec(stop[0]);
        // Own process group: `voila stop` signals the worker's group, and the image must stay
        // readable until the container has exited.
        _ = std.c.setpgid(0, 0);
        closeInheritedFds(ready[1], stop[0], -1);
        execFuseServe(exe, voila_root, image, mount_dir, ready[1], stop[0], opts);
        std.c._exit(127);
    }
    _ = std.c.close(ready[1]);
    _ = std.c.close(stop[0]);
    var byte: u8 = 0;
    const n = std.c.read(ready[0], @ptrCast(&byte), 1);
    _ = std.c.close(ready[0]);
    if (n != 1 or byte != 1) {
        _ = std.c.close(stop[1]);
        var st: i32 = 0;
        _ = std.c.waitpid(pid, &st, 0);
        return error.FuseServerFailed;
    }
    var early_status: i32 = 0;
    if (std.c.waitpid(pid, &early_status, std.c.W.NOHANG) == pid) {
        _ = std.c.close(stop[1]);
        return error.FuseServerFailed;
    }
    return .{
        .pid = pid,
        .stop_w = stop[1],
        .mount_dir = try allocator.dupe(u8, mount_dir),
        .allocator = allocator,
    };
}

pub fn runServe(io: std.Io, cli: ServeCli) void {
    serveChild(io, cli.root, cli.image, cli.mount, cli.ready_fd, cli.stop_fd, .{ .map_root = cli.map_root, .subuid = cli.subuid, .subgid = cli.subgid });
}

fn execFuseServe(
    exe: []const u8,
    voila_root: []const u8,
    image: []const u8,
    mount_dir: []const u8,
    ready_w: std.posix.fd_t,
    stop_r: std.posix.fd_t,
    opts: Options,
) void {
    const allocator = std.heap.page_allocator;
    const rw = std.fmt.allocPrint(allocator, "{d}", .{ready_w}) catch return;
    const sw = std.fmt.allocPrint(allocator, "{d}", .{stop_r}) catch return;
    const parts = [_][]const u8{
        exe,                                              "container-fuse-serve", "-root",     voila_root, "-image",                                             image,      "-mount",                                         mount_dir,
        "--ready-fd",                                     rw,                     "--stop-fd", sw,         if (opts.map_root) "--map-root" else "--no-map-root", "--subuid", formatRange(allocator, opts.subuid) catch return, "--subgid",
        formatRange(allocator, opts.subgid) catch return,
    };
    var zargs: [parts.len][:0]const u8 = undefined;
    for (parts, 0..) |s, i| {
        const z = allocator.allocSentinel(u8, s.len, 0) catch return;
        @memcpy(z, s);
        zargs[i] = z;
    }
    var cargv: [parts.len + 1]?[*:0]const u8 = undefined;
    for (zargs, 0..) |z, i| cargv[i] = z.ptr;
    cargv[parts.len] = null;
    _ = std.c.execve(zargs[0].ptr, @ptrCast(&cargv), std.c.environ);
}

fn serveChild(
    io: std.Io,
    voila_root: []const u8,
    image: []const u8,
    mount_dir: []const u8,
    ready_w: std.posix.fd_t,
    stop_r: std.posix.fd_t,
    opts: Options,
) void {
    // page_allocator maps a page per allocation; decoding a large manifest makes ~10^5 of them.
    const allocator = std.heap.smp_allocator;
    if (!fuse_linux.canUseFuse()) return;
    voila_registry.setIo(io, allocator);
    voila_login_creds.loadIntoHub(allocator) catch return;
    voila_registry_creds.loadFromCredsFile(allocator, voila_root) catch return;
    voila_registry.loadFromEnv(allocator) catch return;
    const tree = voila_loader.loadTreeRoot(io, allocator, voila_root, image) catch return;
    var fuse_vfs: fuse_vfs_mod.FuseVfs = .{ .voila = voila_vfs_mod.VoilaVfs.initFromTree(allocator, tree) };
    defer fuse_vfs.deinit();
    // libfuse threads are not zio tasks, and the zio executor (this thread) is parked in
    // the FUSE loop, so registry fetches and the VFS lock run on a thread-based Io.
    // Unlimited async: past the limit `Io.async` runs inline, and each request's
    // timeout is an async sleep that would then block its caller for the full timeout.
    var threaded: std.Io.Threaded = .init(allocator, .{ .async_limit = .unlimited });
    defer threaded.deinit();
    const fetch_io = threaded.io();
    fuse_vfs.voila.lock_io = fetch_io;
    fuse_vfs.voila.setFetchIo(fetch_io);
    var pool: ?FetchPool = if (fuse_vfs.voila.fetcher) |f| FetchPool.init(allocator, fetch_io, f, voila_root) else null;
    if (pool) |*p| {
        p.start();
        fuse_vfs.voila.pool = p;
    }
    defer if (pool) |*p| p.deinit();
    if (opts.map_root) fuse_vfs.voila.owner_map = .{
        .uid = .{ .host = std.c.getuid(), .sub = opts.subuid },
        .gid = .{ .host = std.c.getgid(), .sub = opts.subgid },
    };
    posix_util.makePath(mount_dir) catch return;
    var ctx: ServeCtx = .{
        .session = fuse_linux.mountSession(allocator, mount_dir, &fuse_vfs) catch return,
        .err = null,
    };
    for (0..10_000) |_| {
        if (mount_exec.mountListed(mount_dir)) break;
        posix_util.sleepMs(1);
    }
    _ = std.c.write(ready_w, &[_]u8{1}, 1);
    _ = std.c.close(ready_w);
    // EOF on the stop pipe (parent closed it or died) unmounts, which ends the serve loop.
    const watcher = std.Thread.spawn(.{}, watchStop, .{ stop_r, mount_dir, &ctx.session }) catch null;
    fuse_linux.serveSessionMt(&ctx.session, fuse_threads) catch |e| {
        ctx.err = e;
    };
    unmountQuietly(mount_dir);
    if (watcher) |t| t.join();
    ctx.session.deinit();
}

fn watchStop(stop_r: std.posix.fd_t, mount_dir: []const u8, session: *fuse_linux.Session) void {
    var buf: [1]u8 = .{0};
    while (std.c.read(stop_r, &buf, 1) > 0) {}
    _ = std.c.close(stop_r);
    session.stop();
    unmountQuietly(mount_dir);
}

fn clearCloexec(fd: std.posix.fd_t) void {
    _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, 0));
}

fn closeInheritedFds(keep_a: std.posix.fd_t, keep_b: std.posix.fd_t, keep_c: std.posix.fd_t) void {
    var fd: i32 = 3;
    while (fd < 512) : (fd += 1) {
        if (fd == keep_a or fd == keep_b or fd == keep_c) continue;
        _ = std.c.close(fd);
    }
}

fn unmountQuietly(mount_dir: []const u8) void {
    if (!fusermount.unmount(mount_dir, .lazy)) _ = fusermount.unmount(mount_dir, .normal);
}

pub const ServeCli = struct {
    root: []const u8,
    image: []const u8,
    mount: []const u8,
    ready_fd: std.posix.fd_t,
    stop_fd: std.posix.fd_t,
    map_root: bool = false,
    subuid: ?idmap.Range = null,
    subgid: ?idmap.Range = null,
};

/// `start:count`, or `-` for none.
fn formatRange(a: std.mem.Allocator, r: ?idmap.Range) ![]const u8 {
    const v = r orelse return "-";
    return std.fmt.allocPrint(a, "{d}:{d}", .{ v.start, v.count });
}

fn parseRange(s: []const u8) error{BadArgs}!?idmap.Range {
    if (std.mem.eql(u8, s, "-")) return null;
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return error.BadArgs;
    return .{
        .start = std.fmt.parseInt(u32, s[0..colon], 10) catch return error.BadArgs,
        .count = std.fmt.parseInt(u32, s[colon + 1 ..], 10) catch return error.BadArgs,
    };
}

pub fn parseServeCliArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !ServeCli {
    var root: ?[]const u8 = null;
    var image: ?[]const u8 = null;
    var mount: ?[]const u8 = null;
    var ready_fd: std.posix.fd_t = -1;
    var stop_fd: std.posix.fd_t = -1;
    var map_root = false;
    var subuid: ?idmap.Range = null;
    var subgid: ?idmap.Range = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-root")) {
            root = try allocator.dupe(u8, args.next() orelse return error.BadArgs);
        } else if (std.mem.eql(u8, arg, "-image")) {
            image = try allocator.dupe(u8, args.next() orelse return error.BadArgs);
        } else if (std.mem.eql(u8, arg, "-mount")) {
            mount = try allocator.dupe(u8, args.next() orelse return error.BadArgs);
        } else if (std.mem.eql(u8, arg, "--ready-fd")) {
            const n = args.next() orelse return error.BadArgs;
            ready_fd = @intCast(std.fmt.parseInt(i32, n, 10) catch return error.BadArgs);
        } else if (std.mem.eql(u8, arg, "--stop-fd")) {
            const n = args.next() orelse return error.BadArgs;
            stop_fd = @intCast(std.fmt.parseInt(i32, n, 10) catch return error.BadArgs);
        } else if (std.mem.eql(u8, arg, "--map-root")) {
            map_root = true;
        } else if (std.mem.eql(u8, arg, "--no-map-root")) {
            map_root = false;
        } else if (std.mem.eql(u8, arg, "--subuid")) {
            subuid = try parseRange(args.next() orelse return error.BadArgs);
        } else if (std.mem.eql(u8, arg, "--subgid")) {
            subgid = try parseRange(args.next() orelse return error.BadArgs);
        } else {
            return error.BadArgs;
        }
    }
    if (root == null or image == null or mount == null or ready_fd < 0 or stop_fd < 0) return error.BadArgs;
    return .{
        .root = root.?,
        .image = image.?,
        .mount = mount.?,
        .ready_fd = ready_fd,
        .stop_fd = stop_fd,
        .map_root = map_root,
        .subuid = subuid,
        .subgid = subgid,
    };
}

pub const Error = error{
    PipeFailed,
    ForkFailed,
    FuseServerFailed,
    BadArgs,
};
