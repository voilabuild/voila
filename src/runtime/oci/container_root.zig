//! Container root setup: PID namespace init, fresh /proc, minimal /dev, read-only /sys, pivot_root.
const std = @import("std");
const ns = @import("../../sys/ns.zig");

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
        .readonly => |p| {
            // Locked host flags must be repeated or the kernel refuses the remount.
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

/// Writable root over a read-only `dir`: tmpfs on `dir`, overlay of the hidden original
/// and the tmpfs at `<dir>/root`. Returns that root path in `buf`.
pub fn mountOverlayRoot(dir: [:0]const u8, buf: []u8) (ns.Error || error{NameTooLong})![:0]const u8 {
    const lower = try ns.openPath(dir);
    defer ns.close(lower);
    try ns.mount("tmpfs", dir, "tmpfs", MS.NOSUID | MS.NODEV, "mode=755");
    errdefer ns.umountDetach(dir) catch {};
    var upper_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var work_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var opts_buf: [3 * std.Io.Dir.max_path_bytes]u8 = undefined;
    const upper = std.mem.printSentinel(&upper_buf, "{s}/upper", .{dir}, 0) catch return error.NameTooLong;
    const work = std.mem.printSentinel(&work_buf, "{s}/work", .{dir}, 0) catch return error.NameTooLong;
    const root = std.mem.printSentinel(buf, "{s}/root", .{dir}, 0) catch return error.NameTooLong;
    for ([_][:0]const u8{ upper, work, root }) |d| try ns.mkdir(d, 0o755);
    const opts = std.mem.printSentinel(&opts_buf, "lowerdir=/proc/self/fd/{d},upperdir={s},workdir={s},userxattr", .{ lower, upper, work }, 0) catch return error.NameTooLong;
    try ns.mount("overlay", root, "overlay", 0, opts);
    return root;
}

/// Forwarded signals whose default action terminates the process.
const fatal = [_]ns.SIG{ .HUP, .INT, .QUIT, .TERM, .USR1, .USR2 };
const forwarded = fatal ++ [_]ns.SIG{ .WINCH, .CHLD };

/// Unshare a PID namespace and fork its init. Returns null in the child (PID 1, killed
/// with its parent) and, in the parent, the child's exit code after forwarding signals to it.
pub fn enterPidNamespace() ns.Error!?u8 {
    try ns.unshare(ns.CLONE.NEWPID);
    const set = ns.sigset(&forwarded);
    const old = try ns.blockSignals(&set);
    // pivot_root also moves this process's root, so keep a handle on the host /proc.
    const proc = ns.openPath("/proc") catch -1;
    const pid = try ns.fork();
    if (pid == 0) {
        if (proc >= 0) ns.close(proc);
        try ns.setSignalMask(&old);
        try ns.setParentDeathSignal(.KILL);
        return null;
    }
    var killed_by: ?ns.SIG = null;
    while (true) {
        const sig = try ns.waitSignal(&set);
        if (sig == .CHLD) {
            const status = try ns.waitNoHang(pid) orelse continue;
            if (killed_by) |k| if (ns.exitCode(status) == 128 + 9) return 128 + @as(u8, @intCast(@backingInt(k)));
            return ns.exitCode(status);
        }
        // PID 1 drops signals it does not handle; kill it as the default action would.
        if (isFatal(sig) and !ns.signalHandled(proc, pid, sig)) {
            killed_by = sig;
            ns.kill(pid, .KILL);
        } else {
            ns.kill(pid, sig);
        }
    }
}

fn isFatal(sig: ns.SIG) bool {
    for (fatal) |f| if (f == sig) return true;
    return false;
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
