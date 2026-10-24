//! Run libfuse in a child process so the parent can chroot into the mount without deadlocking.
const std = @import("std");
const fuse_linux = @import("../../mount/fuse/fuse_linux.zig");
const fuse_vfs_mod = @import("../../mount/fuse/fuse_vfs.zig");
const voila_vfs_mod = @import("../../mount/fuse/voila_vfs.zig");
const voila_loader = @import("../../store/voila_loader.zig");
const voila_registry = @import("../../registry/voila_registry.zig");
const voila_registry_creds = @import("../../registry/voila_registry_creds.zig");
const voila_login_creds = @import("../../registry/voila_login_creds.zig");
const mount_exec = @import("../../mount/mount_exec.zig");
const posix_util = @import("../../sys/posix_util.zig");
const idmap = @import("../../core/idmap.zig");

const ServeCtx = struct {
    session: fuse_linux.Session,
    err: ?anyerror,
};

pub const Handle = struct {
    pid: std.c.pid_t,
    stop_w: std.posix.fd_t,
    mount_dir: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Handle) void {
        if (self.stop_w >= 0) _ = std.c.close(self.stop_w);
        self.stop_w = -1;
        if (self.pid > 0) {
            _ = std.c.kill(self.pid, std.c.SIG.TERM);
            var status: i32 = 0;
            _ = std.c.waitpid(self.pid, &status, 0);
            self.pid = 0;
        }
        fusermountU(self.allocator, self.mount_dir);
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
    if (std.c.pipe(&ready) != 0) return error.PipeFailed;
    if (std.c.pipe(&stop) != 0) {
        _ = std.c.close(ready[0]);
        _ = std.c.close(ready[1]);
        return error.PipeFailed;
    }
    const exe = selfExePath(allocator) catch return error.ForkFailed;
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
        sleepMs(1);
    }
    _ = std.c.write(ready_w, &[_]u8{1}, 1);
    _ = std.c.close(ready_w);
    fuse_linux.serveSession(&ctx.session) catch |e| {
        ctx.err = e;
    };
    var buf: [1]u8 = .{0};
    while (std.c.read(stop_r, &buf, 1) > 0) {}
    ctx.session.stop();
    fusermountU(allocator, mount_dir);
    ctx.session.deinit();
    _ = std.c.close(stop_r);
}

fn sleepMs(ms: u64) void {
    var ts: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    while (std.c.nanosleep(&ts, &ts) == -1 and std.c.errno(-1) == .INTR) {}
}

fn selfExePath(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [4096]u8 = undefined;
    const n = std.c.readlink("/proc/self/exe", &buf, buf.len);
    if (n <= 0) return error.ForkFailed;
    return allocator.dupe(u8, buf[0..@intCast(n)]);
}

fn closeInheritedFds(keep_a: std.posix.fd_t, keep_b: std.posix.fd_t, keep_c: std.posix.fd_t) void {
    var fd: i32 = 3;
    while (fd < 512) : (fd += 1) {
        if (fd == keep_a or fd == keep_b or fd == keep_c) continue;
        _ = std.c.close(fd);
    }
}

fn fusermountU(allocator: std.mem.Allocator, mount_dir: []const u8) void {
    const cmd = std.fmt.allocPrint(allocator, "fusermount3 -uz {s} 2>/dev/null || fusermount3 -u {s} 2>/dev/null || umount -l {s} 2>/dev/null", .{ mount_dir, mount_dir, mount_dir }) catch return;
    defer allocator.free(cmd);
    const cmd_z = allocator.allocSentinel(u8, cmd.len, 0) catch return;
    defer allocator.free(cmd_z);
    @memcpy(cmd_z, cmd);
    _ = posix_util.shell(cmd_z);
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
