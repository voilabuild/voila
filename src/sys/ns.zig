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
    SocketFailed,
    PtyFailed,
    SetnsFailed,
};

fn failed(rc: usize) bool {
    return linux.errno(rc) != .SUCCESS;
}

/// mount(2) with optional source, fstype and data.
pub fn mount(source: ?[*:0]const u8, target: [*:0]const u8, fstype: ?[*:0]const u8, flags: u32, data: ?[*:0]const u8) Error!void {
    if (failed(linux.mount(source, target, fstype, flags, @intFromPtr(data)))) return error.MountFailed;
}

/// Make the mount tree at `path` read-only, submounts included (mount_setattr, Linux 5.12+).
pub fn readOnlyRecursive(path: [*:0]const u8) Error!void {
    const MountAttr = extern struct { attr_set: u64, attr_clr: u64, propagation: u64, userns_fd: u64 };
    const attr: MountAttr = .{ .attr_set = 1, .attr_clr = 0, .propagation = 0, .userns_fd = 0 };
    const at_fdcwd: usize = @bitCast(@as(isize, linux.AT.FDCWD));
    const rc = linux.syscall5(.mount_setattr, at_fdcwd, @intFromPtr(path), linux.AT.RECURSIVE, @intFromPtr(&attr), @sizeOf(MountAttr));
    if (failed(rc)) return error.MountFailed;
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

pub fn setns(fd: linux.fd_t, nstype: u32) Error!void {
    if (failed(linux.setns(fd, nstype))) return error.SetnsFailed;
}

/// Bring up `lo` in the current network namespace.
pub fn bringUpLoopback() Error!void {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (failed(rc)) return error.SocketFailed;
    const sock: linux.fd_t = @intCast(rc);
    defer close(sock);
    var ifr: linux.ifreq = undefined;
    @memset(std.mem.asBytes(&ifr), 0);
    ifr.ifrn.name[0] = 'l';
    ifr.ifrn.name[1] = 'o';
    if (failed(linux.ioctl(sock, linux.SIOCGIFFLAGS, @intFromPtr(&ifr)))) return error.SocketFailed;
    ifr.ifru.flags.UP = true;
    ifr.ifru.flags.RUNNING = true;
    if (failed(linux.ioctl(sock, linux.SIOCSIFFLAGS, @intFromPtr(&ifr)))) return error.SocketFailed;
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

pub fn openRead(path: [*:0]const u8) Error!linux.fd_t {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
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

pub const Exited = struct { pid: linux.pid_t, status: u32 };

/// Reap one exited child without blocking; null when none is ready or none is left.
pub fn reapAny() Error!?Exited {
    var status: i32 = 0;
    while (true) {
        const rc = linux.wait4(-1, &status, linux.W.NOHANG, null);
        switch (linux.errno(rc)) {
            .SUCCESS => return if (rc == 0) null else .{ .pid = @intCast(rc), .status = @bitCast(status) },
            .INTR => continue,
            .CHILD => return null,
            else => return error.WaitFailed,
        }
    }
}

pub fn socketPair() Error![2]linux.fd_t {
    var fds: [2]linux.fd_t = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds);
    if (failed(rc)) return error.SocketFailed;
    return fds;
}

const fd_cmsg_len = @sizeOf(linux.cmsghdr) + @sizeOf(linux.fd_t);
const fd_cmsg_space = std.mem.alignForward(usize, fd_cmsg_len, linux.cmsg_align);

/// Pass `fd` over a unix socket (SCM_RIGHTS).
pub fn sendFd(sock: linux.fd_t, fd: linux.fd_t) Error!void {
    var byte: u8 = 0;
    const iov = [_]std.posix.iovec_const{.{ .base = @ptrCast(&byte), .len = 1 }};
    var control: [fd_cmsg_space]u8 align(@alignOf(linux.cmsghdr)) = @splat(0);
    const hdr: *linux.cmsghdr = @ptrCast(&control);
    hdr.* = .{ .len = fd_cmsg_len, .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
    std.mem.writeInt(linux.fd_t, control[@sizeOf(linux.cmsghdr)..][0..@sizeOf(linux.fd_t)], fd, .little);
    const msg: linux.msghdr_const = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &control, .controllen = control.len, .flags = 0 };
    if (failed(linux.sendmsg(sock, &msg, linux.MSG.NOSIGNAL))) return error.SocketFailed;
}

/// Receive an fd sent with `sendFd`; null when the peer closed without sending one.
pub fn recvFd(sock: linux.fd_t) Error!?linux.fd_t {
    var byte: u8 = 0;
    var iov = [_]std.posix.iovec{.{ .base = @ptrCast(&byte), .len = 1 }};
    var control: [fd_cmsg_space]u8 align(@alignOf(linux.cmsghdr)) = @splat(0);
    var msg: linux.msghdr = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &control, .controllen = control.len, .flags = 0 };
    while (true) {
        const rc = linux.recvmsg(sock, &msg, linux.MSG.CMSG_CLOEXEC);
        switch (linux.errno(rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.SocketFailed,
        }
    }
    if (msg.controllen < fd_cmsg_len) return null;
    const hdr: *const linux.cmsghdr = @ptrCast(&control);
    if (hdr.level != linux.SOL.SOCKET or hdr.type != linux.SCM.RIGHTS) return null;
    return std.mem.readInt(linux.fd_t, control[@sizeOf(linux.cmsghdr)..][0..@sizeOf(linux.fd_t)], .little);
}

/// Make `pgid` the foreground process group of terminal `fd`. SIGTTOU is blocked so a
/// background caller can take the terminal back. False when `fd` is not a terminal.
pub fn setForeground(fd: linux.fd_t, pgid: linux.pid_t) bool {
    const set = sigset(&.{.TTOU});
    const old = blockSignals(&set) catch return false;
    defer setSignalMask(&old) catch {};
    return !failed(linux.tcsetpgrp(fd, &pgid));
}

pub fn processGroup() linux.pid_t {
    return @intCast(linux.getpgid(0));
}

/// Put terminal `fd` in raw mode and return the previous settings, or null when it is not a terminal.
pub fn rawMode(fd: linux.fd_t) ?linux.termios {
    var old: linux.termios = undefined;
    if (failed(linux.tcgetattr(fd, &old))) return null;
    var raw = old;
    raw.iflag.IGNBRK = false;
    raw.iflag.BRKINT = false;
    raw.iflag.PARMRK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cflag.CSIZE = .CS8;
    raw.cflag.PARENB = false;
    raw.cc[@backingInt(linux.V.MIN)] = 1;
    raw.cc[@backingInt(linux.V.TIME)] = 0;
    if (failed(linux.tcsetattr(fd, .FLUSH, &raw))) return null;
    return old;
}

pub fn restoreMode(fd: linux.fd_t, mode: linux.termios) void {
    _ = linux.tcsetattr(fd, .FLUSH, &mode);
}

pub const Pty = struct { master: linux.fd_t, slave: linux.fd_t };

/// Open a pty pair from `ptmx` (the container's devpts), slave via TIOCGPTPEER.
pub fn openPty(ptmx: [*:0]const u8) Error!Pty {
    const rc = linux.open(ptmx, .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0);
    if (failed(rc)) return error.PtyFailed;
    const master: linux.fd_t = @intCast(rc);
    errdefer close(master);
    var unlock: c_int = 0;
    if (failed(linux.ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock)))) return error.PtyFailed;
    const flags: u32 = @bitCast(linux.O{ .ACCMODE = .RDWR, .NOCTTY = true });
    const peer = linux.ioctl(master, linux.T.IOCGPTPEER, flags);
    if (failed(peer)) return error.PtyFailed;
    return .{ .master = master, .slave = @intCast(peer) };
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

test "sendFd passes a working pty master" {
    const pair = try socketPair();
    defer close(pair[0]);
    defer close(pair[1]);
    const pty = try openPty("/dev/ptmx");
    defer close(pty.slave);
    try sendFd(pair[0], pty.master);
    close(pty.master);
    const got = (try recvFd(pair[1])).?;
    defer close(got);
    _ = linux.write(pty.slave, "hi", 2);
    var buf: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), linux.read(got, &buf, 2));
    try std.testing.expectEqualStrings("hi", &buf);
}

test "recvFd returns null when the peer closes" {
    const pair = try socketPair();
    defer close(pair[1]);
    close(pair[0]);
    try std.testing.expectEqual(@as(?linux.fd_t, null), try recvFd(pair[1]));
}
