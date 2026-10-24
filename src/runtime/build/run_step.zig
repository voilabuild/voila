//! Rootless RUN: the step's image is FUSE-mounted read-only, overlayfs on top captures
//! writes in `upper_dir`, and the command runs pivoted into it in user + mount + PID namespaces.
//! With a subuid range the namespace maps 0 -> invoking uid and 1..N -> the range.
const std = @import("std");
const steps = @import("steps.zig");
const fs = @import("../../sys/fs.zig");
const process = @import("../../sys/process.zig");
const idmap = @import("../../core/idmap.zig");
const passwd = @import("../../core/passwd.zig");
const dir_walk = @import("../../store/ingest/ingest_dir_walk.zig");
const container_fuse_sibling = @import("../oci/container_fuse_sibling.zig");
const container_bind = @import("../oci/container_bind.zig");
const container_root = @import("../oci/container_root.zig");
const userns_ids = @import("../oci/userns_ids.zig");

extern "c" fn unshare(flags: c_int) c_int;
extern "c" fn mount(source: ?[*:0]const u8, target: [*:0]const u8, fstype: ?[*:0]const u8, flags: usize, data: ?*const anyopaque) c_int;

const CLONE_NEWNS: c_int = 0x00020000;
const CLONE_NEWUSER: c_int = 0x10000000;
const CLONE_NEWPID: c_int = 0x20000000;
const MS_BIND: usize = 4096;
const MS_PRIVATE: usize = 1 << 18;
const MS_REC: usize = 16384;

/// Status-pipe bytes the child writes before failing; exec success closes the pipe.
const Failure = enum(u8) { setup = 'S', user = 'U', release = 'R', _ };

pub const NamespaceRunner = struct {
    allocator: std.mem.Allocator,
    /// Mapping to request; ranges are written with newuidmap/newgidmap (`userns_ids.detect`).
    ids: idmap.Mapping,
    paths: userns_ids.Paths = .{},

    pub fn runner(self: *NamespaceRunner) steps.StepRunner {
        return .{ .ptr = self, .runFn = run };
    }

    fn run(ptr: *anyopaque, io: std.Io, req: steps.RunRequest) steps.RunnerError!steps.RunResult {
        const self: *NamespaceRunner = @ptrCast(@alignCast(ptr));
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const lower = try std.fmt.allocPrint(a, "{s}/lower", .{req.scratch_dir});
        const work = try std.fmt.allocPrint(a, "{s}/work", .{req.scratch_dir});
        const merged = try std.fmt.allocPrint(a, "{s}/merged", .{req.scratch_dir});
        for ([_][]const u8{ lower, work, merged }) |d| fs.mkdir(d, 0o755) catch return error.MountFailed;

        const hex = std.fmt.bytesToHex(req.root, .lower);
        const image = try std.fmt.allocPrint(a, "@{s}", .{&hex});
        var fuse = container_fuse_sibling.startWith(io, a, req.voila_root, image, lower, .{
            .map_root = true,
            .subuid = self.ids.uid.sub,
            .subgid = self.ids.gid.sub,
        }) catch return error.MountFailed;
        defer fuse.deinit();

        const cred = try resolveUser(a, lower, req.user);
        const plan = try Plan.init(a, req, self.ids, cred, lower, work, merged);
        defer chmodTree(a, work);
        return self.spawn(plan);
    }

    fn spawn(self: *NamespaceRunner, plan: Plan) steps.RunnerError!steps.RunResult {
        var up: [2]std.posix.fd_t = undefined;
        var down: [2]std.posix.fd_t = undefined;
        var status: [2]std.posix.fd_t = undefined;
        if (std.c.pipe2(&up, .{ .CLOEXEC = true }) != 0) return error.SpawnFailed;
        if (std.c.pipe2(&down, .{ .CLOEXEC = true }) != 0) {
            closeBoth(up);
            return error.SpawnFailed;
        }
        if (std.c.pipe2(&status, .{ .CLOEXEC = true }) != 0) {
            closeBoth(up);
            closeBoth(down);
            return error.SpawnFailed;
        }
        const pid = std.c.fork();
        if (pid == 0) {
            _ = std.c.close(up[0]);
            _ = std.c.close(down[1]);
            _ = std.c.close(status[0]);
            plan.child(.{ .up = up[1], .down = down[0], .status = status[1] });
        }
        // Close the child's ends so a child that dies early unblocks the reads below.
        _ = std.c.close(up[1]);
        _ = std.c.close(down[0]);
        _ = std.c.close(status[1]);
        defer _ = std.c.close(up[0]);
        defer _ = std.c.close(down[1]);
        defer _ = std.c.close(status[0]);
        if (pid < 0) return error.SpawnFailed;

        var ids = userns_ids.effective(self.ids, 0);
        var byte: u8 = 0;
        if (std.c.read(up[0], @ptrCast(&byte), 1) == 1) {
            var written: u8 = 0;
            if (self.ids.isRange()) {
                const applied = userns_ids.applyHelpers(pid, self.ids, self.paths);
                written = applied.written;
                ids = applied.ids;
            }
            _ = std.c.write(down[1], @ptrCast(&written), 1);
        }
        var wst: c_int = 0;
        while (std.c.waitpid(pid, &wst, 0) < 0) {}
        if (std.c.read(status[0], @ptrCast(&byte), 1) == 1) {
            return switch (@as(Failure, @fromBackingInt(@intCast(byte)))) {
                .user => error.UserSwitchFailed,
                .setup, .release => error.OverlayFailed,
                _ => error.OverlayFailed,
            };
        }
        return .{ .code = exitCode(wst), .ids = ids, .user_not_applied = userSwitch(plan.cred, ids) == .not_mapped };
    }
};

pub const UserSwitch = enum { none, apply, not_mapped };

/// Whether RUN can switch to `cred`: a single-id namespace only maps root, and then the
/// command runs as root as it did before subuid support.
pub fn userSwitch(cred: ?passwd.Cred, ids: idmap.Mapping) UserSwitch {
    const c = cred orelse return .none;
    if (ids.uid.toHost(c.uid) == null or ids.gid.toHost(c.gid) == null) return .not_mapped;
    return .apply;
}

/// The mapped subset of `groups`; setgroups rejects unmapped ids.
fn mappedGroups(groups: []const u32, ids: idmap.Mapping, buf: []u32) []const u32 {
    var n: usize = 0;
    for (groups) |g| {
        if (n == buf.len) break;
        if (ids.gid.toHost(g) == null) continue;
        buf[n] = g;
        n += 1;
    }
    return buf[0..n];
}

fn closeBoth(fds: [2]std.posix.fd_t) void {
    _ = std.c.close(fds[0]);
    _ = std.c.close(fds[1]);
}

fn exitCode(status: c_int) u8 {
    const st: u32 = @bitCast(status);
    if (std.posix.W.IFEXITED(st)) return std.posix.W.EXITSTATUS(st);
    return 128 +| @as(u8, @truncate(@backingInt(std.posix.W.TERMSIG(st))));
}

/// `USER` resolved against the step's image, read through the FUSE lower before the run.
fn resolveUser(a: std.mem.Allocator, lower: []const u8, spec: []const u8) steps.RunnerError!?passwd.Cred {
    if (spec.len == 0) return null;
    const pw = try readImageFile(a, lower, "etc/passwd");
    const gr = try readImageFile(a, lower, "etc/group");
    return passwd.resolveCred(a, spec, pw, gr) catch |e| switch (e) {
        error.UnknownUser => error.UnknownUser,
        error.UnknownGroup => error.UnknownGroup,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Contents of `rel` under `root`, or "" when missing or a symlink.
fn readImageFile(a: std.mem.Allocator, root: []const u8, rel: []const u8) error{OutOfMemory}![]const u8 {
    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, rel });
    const f = fs.File.openRead(path) catch return "";
    defer f.close();
    var out: std.ArrayList(u8) = .empty;
    var buf: [16384]u8 = undefined;
    while (out.items.len < 16 << 20) {
        const n = f.readFull(&buf) catch return "";
        try out.appendSlice(a, buf[0..n]);
        if (n < buf.len) break;
    }
    return out.items;
}

const ChildFds = struct { up: std.posix.fd_t, down: std.posix.fd_t, status: std.posix.fd_t };

/// Everything the child needs, prepared before fork so the child only makes syscalls.
const Plan = struct {
    ids: idmap.Mapping,
    cred: ?passwd.Cred,
    upper: []const u8,
    owners_path: []const u8,
    merged_z: [:0]const u8,
    overlay_opts: [:0]const u8,
    workdir_z: ?[:0]const u8,
    argv: [:null]?[*:0]const u8,
    envp: [:null]?[*:0]const u8,
    /// Candidate executable paths: argv[0] as is, or joined with each PATH entry.
    candidates: []const [:0]const u8,
    resolv_src: [:0]const u8 = "/etc/resolv.conf",
    resolv_dst: [:0]const u8,
    root_ops: []const container_root.Op,

    fn init(a: std.mem.Allocator, req: steps.RunRequest, ids: idmap.Mapping, cred: ?passwd.Cred, lower: []const u8, work: []const u8, merged: []const u8) !Plan {
        const argv = try a.allocSentinel(?[*:0]const u8, req.argv.len, null);
        for (req.argv, 0..) |s, i| argv[i] = try a.dupeSentinel(u8, s, 0);
        var env: std.ArrayList(?[*:0]const u8) = .empty;
        var path_var: []const u8 = steps.default_path["PATH=".len..];
        var has_home = false;
        for (req.env) |s| {
            try env.append(a, try a.dupeSentinel(u8, s, 0));
            if (std.mem.startsWith(u8, s, "PATH=")) path_var = s["PATH=".len..];
            if (std.mem.startsWith(u8, s, "HOME=")) has_home = true;
        }
        if (!has_home) if (cred) |c| if (c.home) |h| try env.append(a, try std.fmt.allocPrintSentinel(a, "HOME={s}", .{h}, 0));
        var cands: std.ArrayList([:0]const u8) = .empty;
        const exe = req.argv[0];
        if (std.mem.indexOfScalar(u8, exe, '/') != null) {
            try cands.append(a, try a.dupeSentinel(u8, exe, 0));
        } else {
            var it = std.mem.tokenizeScalar(u8, path_var, ':');
            while (it.next()) |dir| try cands.append(a, try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, exe }, 0));
        }
        return .{
            .ids = ids,
            .cred = cred,
            .upper = req.upper_dir,
            .owners_path = req.owners_path,
            .merged_z = try a.dupeSentinel(u8, merged, 0),
            .overlay_opts = try std.fmt.allocPrintSentinel(a, "lowerdir={s},upperdir={s},workdir={s},userxattr", .{ lower, req.upper_dir, work }, 0),
            .workdir_z = if (req.workdir.len > 0) try a.dupeSentinel(u8, req.workdir, 0) else null,
            .argv = argv,
            .envp = try env.toOwnedSliceSentinel(a, null),
            .candidates = try cands.toOwnedSlice(a),
            .resolv_dst = try std.fmt.allocPrintSentinel(a, "{s}/etc/resolv.conf", .{merged}, 0),
            .root_ops = try container_root.plan(a, merged),
        };
    }

    /// Enters the namespaces, runs the command in a grandchild, then hands the upper dir
    /// back to the build user. Never returns.
    fn child(self: Plan, fds: ChildFds) noreturn {
        if (unshare(CLONE_NEWUSER) != 0) fail(fds.status, .setup);
        var written: u8 = 0;
        if (std.c.write(fds.up, "u", 1) != 1) fail(fds.status, .setup);
        if (std.c.read(fds.down, @ptrCast(&written), 1) != 1) fail(fds.status, .setup);
        if (written & userns_ids.uid_written == 0 and !container_bind.writeUidMapFor(self.ids.uid.host)) fail(fds.status, .setup);
        if (written & userns_ids.gid_written == 0) container_bind.writeGidMapFor(self.ids.gid.host);
        // The command becomes pid 1 of its own namespace: when it exits, background
        // processes die with it, so nothing changes the upper dir during `release`.
        if (unshare(CLONE_NEWNS | CLONE_NEWPID) != 0) fail(fds.status, .setup);
        _ = mount(null, "/", null, MS_REC | MS_PRIVATE, null);
        if (mount("overlay", self.merged_z, "overlay", 0, self.overlay_opts.ptr) != 0) fail(fds.status, .setup);
        // A created mountpoint is fine: steps.mountpoints keeps it out of the layer.
        const fd = std.c.open(self.resolv_dst, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(std.c.mode_t, 0o644));
        if (fd >= 0) _ = std.c.close(fd);
        _ = mount(self.resolv_src, self.resolv_dst, null, MS_BIND, null);

        const pid = std.c.fork();
        if (pid < 0) fail(fds.status, .setup);
        if (pid == 0) self.command(fds.status, userns_ids.effective(self.ids, written));
        var wst: c_int = 0;
        while (std.c.waitpid(pid, &wst, 0) < 0) {}
        _ = std.os.linux.umount2(self.merged_z, std.os.linux.MNT.DETACH);
        if (written != 0) release(self.upper, self.owners_path) catch fail(fds.status, .release);
        std.c._exit(exitCode(wst));
    }

    fn command(self: Plan, status_fd: std.posix.fd_t, ids: idmap.Mapping) noreturn {
        if (container_root.enterPidNamespace(&.{}) catch fail(status_fd, .setup)) |c| std.c._exit(c);
        container_root.apply(self.root_ops);
        container_root.pivotInto(self.merged_z) catch fail(status_fd, .setup);
        if (self.workdir_z) |wd| {
            makePathZ(wd);
            if (std.c.chdir(wd) != 0) fail(status_fd, .setup);
        }
        if (userSwitch(self.cred, ids) == .apply) {
            const c = self.cred.?;
            var buf: [64]u32 = undefined;
            process.switchUser(c.uid, c.gid, mappedGroups(c.groups, ids, &buf)) catch fail(status_fd, .user);
        }
        _ = std.c.umask(0o022);
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (devnull >= 0) _ = std.c.dup2(devnull, 0);
        for (self.candidates) |c| _ = std.c.execve(c, self.argv.ptr, self.envp.ptr);
        std.c._exit(127);
    }
};

fn fail(status_fd: std.posix.fd_t, why: Failure) noreturn {
    const b: u8 = @backingInt(why);
    _ = std.c.write(status_fd, @ptrCast(&b), 1);
    std.c._exit(1);
}

/// Entries owned by other namespace ids are unreadable for the build user outside the
/// namespace: record their owner, chown them to namespace root, restore setuid bits.
fn release(upper: []const u8, owners_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    try releaseDir(a, upper, "", &out);
    if (out.items.len > 0) try fs.writeFile(owners_path, out.items, 0o600);
}

fn releaseDir(a: std.mem.Allocator, abs: []const u8, rel: []const u8, out: *std.ArrayList(u8)) !void {
    const names = try fs.listDir(a, abs);
    for (names) |n| {
        const p = try std.fmt.allocPrint(a, "{s}/{s}", .{ abs, n });
        const r = try steps.joinRel(a, rel, n);
        const st = try fs.lstat(p);
        // A later hard link to an inode chowned here reads 0:0 and is not recorded; the
        // walker shares one node per inode, so the first path's owner covers it.
        if (st.uid != 0 or st.gid != 0) {
            try dir_walk.appendOwner(a, out, r, .{ .uid = st.uid, .gid = st.gid });
            try fs.lchown(p, 0, 0);
            if (st.kind != .symlink) try fs.chmodNoFollow(p, st.perm);
        }
        if (st.kind == .dir) try releaseDir(a, p, r, out);
    }
}

fn makePathZ(path: [:0]const u8) void {
    var buf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    if (path.len >= buf.len) return;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i != path.len and path[i] != '/') continue;
        @memcpy(buf[0..i], path[0..i]);
        buf[i] = 0;
        _ = std.c.mkdir(buf[0..i :0], 0o755);
    }
}

/// overlayfs leaves `work/work` mode 000; make it removable by the build user.
fn chmodTree(a: std.mem.Allocator, dir: []const u8) void {
    const names = fs.listDir(a, dir) catch return;
    for (names) |n| {
        const p = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, n }, 0) catch return;
        _ = std.c.chmod(p, 0o700);
    }
}

const testing = std.testing;

test "userSwitch runs as root when the single-id map cannot hold USER" {
    const single = idmap.Mapping.single(1000, 1000);
    const range: idmap.Mapping = .{
        .uid = .{ .host = 1000, .sub = .{ .start = 100000, .count = 65536 } },
        .gid = .{ .host = 1000, .sub = .{ .start = 100000, .count = 65536 } },
    };
    const app: passwd.Cred = .{ .uid = 1234, .gid = 1234, .groups = &.{ 1234, 29 } };
    const root: passwd.Cred = .{ .uid = 0, .gid = 0, .groups = &.{0} };
    try testing.expectEqual(UserSwitch.none, userSwitch(null, single));
    try testing.expectEqual(UserSwitch.not_mapped, userSwitch(app, single));
    try testing.expectEqual(UserSwitch.apply, userSwitch(root, single));
    try testing.expectEqual(UserSwitch.apply, userSwitch(app, range));
    const big: passwd.Cred = .{ .uid = 70000, .gid = 1, .groups = &.{1} };
    try testing.expectEqual(UserSwitch.not_mapped, userSwitch(big, range));
    var buf: [4]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{}, mappedGroups(app.groups, single, &buf));
    try testing.expectEqualSlices(u32, &.{ 1234, 29 }, mappedGroups(app.groups, range, &buf));
}
