//! Linux namespace, mount and signal syscalls used to set up a container root.
const std = @import("std");
const linux = std.os.linux;

pub const MS = linux.MS;
pub const CLONE = linux.CLONE;
pub const SIG = linux.SIG;
pub const sigset_t = linux.sigset_t;

pub const Error = error{
    MountFailed,
    UnmountFailed,
    PivotRootFailed,
    ChrootFailed,
    ChdirFailed,
    UnshareFailed,
    PrctlFailed,
    MkdirFailed,
    CreateFailed,
    SymlinkFailed,
    OpenFailed,
    SignalFailed,
    ForkFailed,
    WaitFailed,
};

fn failed(rc: usize) bool {
    return linux.errno(rc) != .SUCCESS;
}

/// mount(2) with optional source, fstype and data.
pub fn mount(source: ?[*:0]const u8, target: [*:0]const u8, fstype: ?[*:0]const u8, flags: u32, data: ?[*:0]const u8) Error!void {
    if (failed(linux.mount(source, target, fstype, flags, @intFromPtr(data)))) return error.MountFailed;
}

pub fn umountDetach(target: [*:0]const u8) Error!void {
    if (failed(linux.umount2(target, linux.MNT.DETACH))) return error.UnmountFailed;
}

pub fn pivotRoot(new_root: [*:0]const u8, put_old: [*:0]const u8) Error!void {
    if (failed(linux.pivot_root(new_root, put_old))) return error.PivotRootFailed;
}

pub fn chroot(path: [*:0]const u8) Error!void {
    if (failed(linux.chroot(path))) return error.ChrootFailed;
}

pub fn chdir(path: [*:0]const u8) Error!void {
    if (failed(linux.chdir(path))) return error.ChdirFailed;
}

pub fn unshare(flags: usize) Error!void {
    if (failed(linux.unshare(flags))) return error.UnshareFailed;
}

pub fn setParentDeathSignal(sig: SIG) Error!void {
    const rc = linux.prctl(@backingInt(linux.PR.SET_PDEATHSIG), @backingInt(sig), 0, 0, 0);
    if (failed(rc)) return error.PrctlFailed;
}

/// mkdir(2); an existing entry counts as success.
pub fn mkdir(path: [*:0]const u8, mode: linux.mode_t) Error!void {
    const e = linux.errno(linux.mkdir(path, mode));
    if (e != .SUCCESS and e != .EXIST) return error.MkdirFailed;
}

/// Create an empty file to serve as a bind-mount target.
pub fn touch(path: [*:0]const u8, mode: linux.mode_t) Error!void {
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, mode);
    if (failed(rc)) return error.CreateFailed;
    _ = linux.close(@intCast(rc));
}

/// symlink(2); an existing entry counts as success.
pub fn symlink(target: [*:0]const u8, link: [*:0]const u8) Error!void {
    const e = linux.errno(linux.symlink(target, link));
    if (e != .SUCCESS and e != .EXIST) return error.SymlinkFailed;
}

/// O_PATH directory handle, kept to reach a directory after it is mounted over.
pub fn openPath(path: [*:0]const u8) Error!linux.fd_t {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .PATH = true, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (failed(rc)) return error.OpenFailed;
    return @intCast(rc);
}

pub fn close(fd: linux.fd_t) void {
    _ = linux.close(fd);
}

pub fn sigset(sigs: []const SIG) sigset_t {
    var set = linux.sigemptyset();
    for (sigs) |s| linux.sigaddset(&set, s);
    return set;
}

/// Block `set` and return the previous mask.
pub fn blockSignals(set: *const sigset_t) Error!sigset_t {
    var old = linux.sigemptyset();
    if (failed(linux.sigprocmask(linux.SIG.BLOCK, set, &old))) return error.SignalFailed;
    return old;
}

pub fn setSignalMask(set: *const sigset_t) Error!void {
    if (failed(linux.sigprocmask(linux.SIG.SETMASK, set, null))) return error.SignalFailed;
}

/// Wait for one signal of `set` (which must be blocked).
pub fn waitSignal(set: *const sigset_t) Error!SIG {
    while (true) {
        const rc = linux.syscall4(.rt_sigtimedwait, @intFromPtr(set), 0, 0, linux.NSIG / 8);
        switch (linux.errno(rc)) {
            .SUCCESS => return @fromBackingInt(@as(u32, @intCast(rc))),
            .INTR => continue,
            else => return error.SignalFailed,
        }
    }
}

pub fn kill(pid: linux.pid_t, sig: SIG) void {
    _ = linux.kill(pid, sig);
}

/// fork(2) through libc so its process state stays consistent; 0 in the child.
pub fn fork() Error!linux.pid_t {
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    return pid;
}

/// Raw wait status of `pid` if it has exited, without blocking.
pub fn waitNoHang(pid: linux.pid_t) Error!?u32 {
    var status: i32 = 0;
    while (true) {
        const rc = linux.wait4(pid, &status, linux.W.NOHANG, null);
        switch (linux.errno(rc)) {
            .SUCCESS => return if (rc == 0) null else @bitCast(status),
            .INTR => continue,
            else => return error.WaitFailed,
        }
    }
}

/// Whether `pid` catches or ignores `sig`, read through the `proc` directory fd;
/// true when its status cannot be read.
pub fn signalHandled(proc: linux.fd_t, pid: linux.pid_t, sig: SIG) bool {
    if (proc < 0) return true;
    var path_buf: [32]u8 = undefined;
    const path = std.mem.printSentinel(&path_buf, "{d}/status", .{pid}, 0) catch return true;
    const rc = linux.openat(proc, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (failed(rc)) return true;
    const fd: linux.fd_t = @intCast(rc);
    defer close(fd);
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = linux.read(fd, buf[len..].ptr, buf.len - len);
        if (failed(n) or n == 0) break;
        len += n;
    }
    return statusHandles(buf[0..len], sig) orelse true;
}

/// Parse SigIgn/SigCgt from /proc/<pid>/status text; null when either is missing.
pub fn statusHandles(status: []const u8, sig: SIG) ?bool {
    const bit = @as(u64, 1) << @intCast(@backingInt(sig) - 1);
    var mask: u64 = 0;
    var found: u2 = 0;
    var lines = std.mem.tokenizeScalar(u8, status, '\n');
    while (lines.next()) |line| {
        for ([_][]const u8{ "SigIgn:", "SigCgt:" }) |key| {
            if (!std.mem.startsWith(u8, line, key)) continue;
            const hex = std.mem.trim(u8, line[key.len..], " \t");
            mask |= std.fmt.parseInt(u64, hex, 16) catch return null;
            found += 1;
        }
    }
    if (found < 2) return null;
    return mask & bit != 0;
}

test "statusHandles reads caught and ignored masks" {
    const status = "Name:\tsh\nSigIgn:\t0000000000001000\nSigCgt:\t0000000000004002\n";
    try std.testing.expectEqual(@as(?bool, true), statusHandles(status, .INT));
    try std.testing.expectEqual(@as(?bool, true), statusHandles(status, .PIPE));
    try std.testing.expectEqual(@as(?bool, true), statusHandles(status, .TERM));
    try std.testing.expectEqual(@as(?bool, false), statusHandles(status, .HUP));
    try std.testing.expectEqual(@as(?bool, null), statusHandles("Name:\tsh\n", .TERM));
}

/// Shell-style exit code for a wait status: the exit code, or 128 + signal.
pub fn exitCode(status: u32) u8 {
    if (linux.W.IFEXITED(status)) return linux.W.EXITSTATUS(status);
    if (linux.W.IFSIGNALED(status)) return 128 +| @as(u8, @truncate(@backingInt(linux.W.TERMSIG(status))));
    return 1;
}

test "exitCode maps exit and signal statuses" {
    try std.testing.expectEqual(@as(u8, 0), exitCode(0));
    try std.testing.expectEqual(@as(u8, 3), exitCode(3 << 8));
    try std.testing.expectEqual(@as(u8, 137), exitCode(9));
    try std.testing.expectEqual(@as(u8, 143), exitCode(15));
    try std.testing.expectEqual(@as(u8, 139), exitCode(11 | 0x80));
}
