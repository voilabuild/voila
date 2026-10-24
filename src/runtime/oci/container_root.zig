//! Container root setup: PID namespace init, fresh /proc, minimal /dev, read-only /sys, pivot_root.
const std = @import("std");
const ns = @import("sys").ns;

const MS = ns.MS;

/// Host device nodes bind-mounted into the container's tmpfs /dev.
pub const dev_nodes = [_][]const u8{ "null", "zero", "full", "random", "urandom", "tty" };

const dev_links = [_][2][]const u8{
    .{ "fd", "/proc/self/fd" },
    .{ "stdin", "/proc/self/fd/0" },
    .{ "stdout", "/proc/self/fd/1" },
    .{ "stderr", "/proc/self/fd/2" },
    .{ "ptmx", "pts/ptmx" },
};

pub const Mount = struct {
    source: ?[:0]const u8,
    target: [:0]const u8,
    fstype: ?[:0]const u8 = null,
    flags: u32,
    data: ?[:0]const u8 = null,
    /// Host path bound recursively instead when the mount is refused.
    fallback_bind: ?[:0]const u8 = null,
};

pub const Op = union(enum) {
    mkdir: [:0]const u8,
    touch: [:0]const u8,
    symlink: struct { target: [:0]const u8, link: [:0]const u8 },
    mount: Mount,
    /// Remount a bind read-only; detach it when that is refused.
    readonly: [:0]const u8,
};

/// Mounts that give `root` its /proc, /dev and /sys. Built before fork so the child only makes syscalls.
pub fn plan(a: std.mem.Allocator, root: []const u8) std.mem.Allocator.Error![]Op {
    var ops: std.ArrayList(Op) = .empty;
    const proc = try join(a, root, "/proc");
    try ops.append(a, .{ .mkdir = proc });
    try ops.append(a, .{ .mount = .{ .source = "proc", .target = proc, .fstype = "proc", .flags = MS.NOSUID | MS.NODEV | MS.NOEXEC, .fallback_bind = "/proc" } });

    const dev = try join(a, root, "/dev");
    try ops.append(a, .{ .mkdir = dev });
    try ops.append(a, .{ .mount = .{ .source = "tmpfs", .target = dev, .fstype = "tmpfs", .flags = MS.NOSUID | MS.STRICTATIME, .data = "mode=755,size=65536k" } });
    for (dev_nodes) |n| {
        const target = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dev, n }, 0);
        try ops.append(a, .{ .touch = target });
        const host = try std.fmt.allocPrintSentinel(a, "/dev/{s}", .{n}, 0);
        try ops.append(a, .{ .mount = .{ .source = host, .target = target, .flags = MS.BIND } });
    }
    const pts = try join(a, dev, "/pts");
    try ops.append(a, .{ .mkdir = pts });
    try ops.append(a, .{ .mount = .{ .source = "devpts", .target = pts, .fstype = "devpts", .flags = MS.NOSUID | MS.NOEXEC, .data = "newinstance,ptmxmode=0666,mode=0620" } });
    const shm = try join(a, dev, "/shm");
    try ops.append(a, .{ .mkdir = shm });
    try ops.append(a, .{ .mount = .{ .source = "shm", .target = shm, .fstype = "tmpfs", .flags = MS.NOSUID | MS.NODEV | MS.NOEXEC, .data = "mode=1777,size=65536k" } });
    for (dev_links) |l| {
        try ops.append(a, .{ .symlink = .{
            .target = try a.dupeSentinel(u8, l[1], 0),
            .link = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dev, l[0] }, 0),
        } });
    }

    // sysfs itself needs a network namespace; bind the host's instead.
    const sys = try join(a, root, "/sys");
    try ops.append(a, .{ .mkdir = sys });
    try ops.append(a, .{ .mount = .{ .source = "/sys", .target = sys, .flags = MS.BIND | MS.REC } });
    try ops.append(a, .{ .readonly = sys });
    return ops.toOwnedSlice(a);
}

/// Run `ops`; each failure only skips that step, so a read-only root without mountpoints still runs.
pub fn apply(ops: []const Op) void {
    for (ops) |op| switch (op) {
        .mkdir => |p| ns.mkdir(p, 0o755) catch {},
        .touch => |p| ns.touch(p, 0o666) catch {},
        .symlink => |s| ns.symlink(s.target, s.link) catch {},
        .mount => |m| applyMount(m),
        .readonly => |p| ns.readOnlyRecursive(p) catch {
            // Before Linux 5.12 only the top mount can be made read-only; locked host
            // flags must be repeated or the kernel refuses the remount.
            const flags = MS.BIND | MS.REMOUNT | MS.RDONLY | MS.NOSUID | MS.NODEV | MS.NOEXEC;
            ns.mount(null, p, null, flags, null) catch ns.umountDetach(p) catch {};
        },
    };
}

fn applyMount(m: Mount) void {
    const src: ?[*:0]const u8 = if (m.source) |s| s.ptr else null;
    const fstype: ?[*:0]const u8 = if (m.fstype) |s| s.ptr else null;
    const data: ?[*:0]const u8 = if (m.data) |s| s.ptr else null;
    ns.mount(src, m.target, fstype, m.flags, data) catch {
        const host = m.fallback_bind orelse return;
        ns.mount(host, m.target, null, MS.BIND | MS.REC, null) catch {};
    };
}

/// Make `root` the process root and detach the old one. `root` must be a mount
/// created in this mount namespace; chroot is used only when pivot_root is refused.
pub fn pivotInto(root: [:0]const u8) ns.Error!void {
    try ns.chdir(root);
    // pivot_root(".", ".") stacks the old root under the new one; detaching "." drops it.
    if (ns.pivotRoot(".", ".")) {
        try ns.umountDetach(".");
    } else |_| {
        try ns.chroot(".");
    }
    try ns.chdir("/");
}

/// Writable root: overlay of the read-only `lower` with upper/work dirs under `rw_dir`,
/// mounted at `<rw_dir>/root`, whose path is returned in `buf`.
pub fn mountOverlayRoot(lower: []const u8, rw_dir: [:0]const u8, buf: []u8) (ns.Error || error{NameTooLong})![:0]const u8 {
    var upper_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var work_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var opts_buf: [3 * std.Io.Dir.max_path_bytes]u8 = undefined;
    const upper = std.mem.printSentinel(&upper_buf, "{s}/upper", .{rw_dir}, 0) catch return error.NameTooLong;
    const work = std.mem.printSentinel(&work_buf, "{s}/work", .{rw_dir}, 0) catch return error.NameTooLong;
    const root = std.mem.printSentinel(buf, "{s}/root", .{rw_dir}, 0) catch return error.NameTooLong;
    for ([_][:0]const u8{ rw_dir, upper, work, root }) |d| try ns.mkdir(d, 0o755);
    const opts = std.mem.printSentinel(&opts_buf, "lowerdir={s},upperdir={s},workdir={s},userxattr", .{ lower, upper, work }, 0) catch return error.NameTooLong;
    try ns.mount("overlay", root, "overlay", 0, opts);
    return root;
}

const forwarded = [_]ns.SIG{ .HUP, .INT, .QUIT, .TERM, .USR1, .USR2, .WINCH, .CHLD };

/// Unshare a PID namespace and fork its init (killed with its parent). Returns null in
/// the child and, in the parent, the child's exit code. `close_in_parent` are fds only the child keeps.
pub fn enterPidNamespace(close_in_parent: []const std.posix.fd_t) ns.Error!?u8 {
    try ns.unshare(ns.CLONE.NEWPID);
    return forkSupervised(close_in_parent, true);
}

/// From PID 1, fork the command as PID 2. Returns null in the command and, in init, the
/// command's exit code; init forwards signals to it and reaps orphans meanwhile.
pub fn forkCommand(close_in_parent: []const std.posix.fd_t) ns.Error!?u8 {
    return forkSupervised(close_in_parent, false);
}

fn forkSupervised(close_in_parent: []const std.posix.fd_t, death_signal: bool) ns.Error!?u8 {
    const set = ns.sigset(&forwarded);
    const old = try ns.blockSignals(&set);
    const pid = try ns.fork();
    if (pid == 0) {
        try ns.setSignalMask(&old);
        if (death_signal) try ns.setParentDeathSignal(.KILL);
        return null;
    }
    for (close_in_parent) |fd| if (fd >= 0) ns.close(fd);
    while (true) {
        const sig = try ns.waitSignal(&set);
        if (sig != .CHLD) {
            ns.kill(pid, sig);
            continue;
        }
        while (try ns.reapAny()) |e| {
            if (e.pid == pid) return ns.exitCode(e.status);
        }
    }
}

fn join(a: std.mem.Allocator, base: []const u8, rel: []const u8) std.mem.Allocator.Error![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, "{s}{s}", .{ base, rel }, 0);
}

const testing = std.testing;

fn indexOfMount(ops: []const Op, target: []const u8) ?usize {
    for (ops, 0..) |op, i| switch (op) {
        .mount => |m| if (std.mem.eql(u8, m.target, target)) return i,
        else => {},
    };
    return null;
}

test "plan mounts a fresh proc with a host bind fallback" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ops = try plan(arena.allocator(), "/r");
    try testing.expectEqualStrings("/r/proc", ops[0].mkdir);
    const m = ops[indexOfMount(ops, "/r/proc").?].mount;
    try testing.expectEqualStrings("proc", m.fstype.?);
    try testing.expectEqualStrings("/proc", m.fallback_bind.?);
}

test "plan binds device nodes into a tmpfs /dev" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ops = try plan(arena.allocator(), "/r");
    const dev = indexOfMount(ops, "/r/dev").?;
    try testing.expectEqualStrings("tmpfs", ops[dev].mount.fstype.?);
    for (dev_nodes) |n| {
        var buf: [64]u8 = undefined;
        const target = try std.fmt.bufPrint(&buf, "/r/dev/{s}", .{n});
        const i = indexOfMount(ops, target).?;
        try testing.expect(i > dev);
        try testing.expectEqualStrings(target, ops[i - 1].touch);
        try testing.expectEqual(@as(u32, MS.BIND), ops[i].mount.flags);
        try testing.expectEqualStrings(target[2..], ops[i].mount.source.?);
    }
    try testing.expect(indexOfMount(ops, "/r/dev/pts").? > dev);
    try testing.expect(indexOfMount(ops, "/r/dev/shm").? > dev);
}

test "plan binds /sys and then makes it read-only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ops = try plan(arena.allocator(), "/r");
    const i = indexOfMount(ops, "/r/sys").?;
    try testing.expectEqualStrings("/sys", ops[i].mount.source.?);
    try testing.expectEqualStrings("/r/sys", ops[i + 1].readonly);
    try testing.expectEqual(ops.len, i + 2);
}
