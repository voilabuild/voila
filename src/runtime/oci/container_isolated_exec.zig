//! Enter user/mount/PID namespaces and pivot into the image root without holding FUSE fds (re-exec entrypoint).
const std = @import("std");
const ns = @import("sys").ns;
const container_bind = @import("container_bind.zig");
const container_root = @import("container_root.zig");
const container_run_opts = @import("container_run_opts.zig");
const run_flags = @import("../run_flags.zig");
const container_pty = @import("container_pty.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub const Spec = struct {
    mount_dir: []const u8,
    log_path: []const u8,
    vfs_argv0: []const u8,
    cmd_argv: []const []const u8,
    opts: container_run_opts.RunOpts,
    /// Disk dir for the writable root's overlay upper; empty keeps the root read-only.
    rw_dir: []const u8 = "",
    use_tty: bool,
    /// Unix socket the container's pty master is sent back on.
    console_fd: std.posix.fd_t = -1,
};

pub fn run(spec: Spec) Error!u8 {
    if (!container_bind.enterUserNamespaceOnly()) return error.UserNamespacesRequired;
    ns.unshare(ns.CLONE.NEWNS) catch return error.UserNamespacesRequired;
    // Refused when / is not a mount point; pivotInto then falls back to chroot.
    ns.mount(null, "/", null, ns.MS.REC | ns.MS.PRIVATE, null) catch {};
    // A host path: open it before the root changes.
    const log_fd: std.posix.fd_t = if (spec.console_fd >= 0 or spec.log_path.len == 0) -1 else openLogAppend(spec.log_path);
    const keep = [_]std.posix.fd_t{ log_fd, spec.console_fd };
    if (container_root.enterPidNamespace(&keep) catch return error.SetupFailed) |code| return code;
    try enterRoot(spec);
    if (container_root.forkCommand(&keep) catch return error.SetupFailed) |code| return code;
    for (spec.opts.env) |e| {
        const key_z = allocZ(e.key) catch return error.SetupFailed;
        const val_z = allocZ(e.value) catch return error.SetupFailed;
        _ = setenv(key_z, val_z, 1);
    }
    if (spec.opts.workdir.len > 0) {
        const wd_z = allocZ(spec.opts.workdir) catch return error.SetupFailed;
        _ = std.c.chdir(wd_z);
    }
    if (spec.console_fd >= 0) {
        try attachConsole(spec.console_fd);
    } else if (log_fd >= 0) {
        _ = std.c.dup2(log_fd, std.c.STDOUT_FILENO);
        _ = std.c.dup2(log_fd, std.c.STDERR_FILENO);
        _ = std.c.close(log_fd);
    }
    return execCommand(spec);
}

/// In PID 1: mount the root (overlay on `rw_dir`, else a read-only bind), apply `-v`,
/// /proc, /dev and /sys, then pivot into it.
fn enterRoot(spec: Spec) Error!void {
    const mount_z = allocZ(spec.mount_dir) catch return error.SetupFailed;
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const overlay: ?[:0]const u8 = if (spec.rw_dir.len == 0) null else blk: {
        const rw_z = allocZ(spec.rw_dir) catch return error.SetupFailed;
        break :blk container_root.mountOverlayRoot(spec.mount_dir, rw_z, &root_buf) catch null;
    };
    const root = overlay orelse blk: {
        ns.mount(mount_z, mount_z, null, ns.MS.BIND | ns.MS.REC, null) catch return error.SetupFailed;
        break :blk mount_z;
    };
    if (!container_bind.applyVolumeBinds(root, spec.opts.volumes)) return error.SetupFailed;
    const ops = container_root.plan(std.heap.page_allocator, root) catch return error.SetupFailed;
    container_root.apply(ops);
    container_root.pivotInto(root) catch return error.SetupFailed;
}

/// Take the terminal from the container's own devpts so ttyname() resolves inside, send
/// the master back to the host side and make the slave the controlling terminal.
fn attachConsole(console_fd: std.posix.fd_t) Error!void {
    const pty = ns.openPty("/dev/ptmx") catch return error.SetupFailed;
    ns.sendFd(console_fd, pty.master) catch return error.SetupFailed;
    ns.close(pty.master);
    ns.close(console_fd);
    var p: container_pty.Pty = .{ .master = -1, .slave = pty.slave };
    p.useSlaveInChild() catch return error.SetupFailed;
}

fn execCommand(spec: Spec) Error {
    var argv_z: std.ArrayList([*:0]const u8) = .empty;
    defer {
        for (argv_z.items) |a| std.heap.page_allocator.free(std.mem.span(a));
        argv_z.deinit(std.heap.page_allocator);
    }
    const a0 = allocZ(spec.vfs_argv0) catch return error.SetupFailed;
    argv_z.append(std.heap.page_allocator, a0.ptr) catch return error.SetupFailed;
    for (spec.cmd_argv[1..]) |arg| {
        const z = allocZ(arg) catch return error.SetupFailed;
        argv_z.append(std.heap.page_allocator, z.ptr) catch return error.SetupFailed;
    }
    var cargv = std.heap.page_allocator.alloc(?[*:0]const u8, argv_z.items.len + 1) catch return error.SetupFailed;
    defer std.heap.page_allocator.free(cargv);
    for (argv_z.items, 0..) |a, i| cargv[i] = a;
    cargv[argv_z.items.len] = null;
    _ = std.c.execve(a0.ptr, @ptrCast(cargv.ptr), std.c.environ);
    return if (std.c.errno(-1) == .NOENT) error.CommandNotFound else error.ExecFailed;
}

/// Exit code for a failed `run`: 127 command not found, 126 not executable, 125 sandbox setup.
pub fn errorExitCode(err: Error) u8 {
    return switch (err) {
        error.CommandNotFound => 127,
        error.ExecFailed => 126,
        else => 125,
    };
}

pub fn spawnAndWait(_: std.Io, allocator: std.mem.Allocator, spec: Spec, timeout_ms: u64) !u8 {
    const console: ?[2]std.posix.fd_t = if (spec.use_tty) ns.socketPair() catch null else null;
    defer if (console) |c| ns.close(c[0]);
    const exe = selfExePath(allocator) catch return error.ExecFailed;
    defer allocator.free(exe);
    const mount_z = try allocator.dupe(u8, spec.mount_dir);
    defer allocator.free(mount_z);
    const log_z = try allocator.dupe(u8, spec.log_path);
    defer allocator.free(log_z);
    const argv0_z = try allocator.dupe(u8, spec.vfs_argv0);
    defer allocator.free(argv0_z);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe);
    try argv.append(allocator, "container-isolated-exec");
    try argv.append(allocator, "--mount");
    try argv.append(allocator, mount_z);
    try argv.append(allocator, "--log");
    try argv.append(allocator, log_z);
    try argv.append(allocator, "--argv0");
    try argv.append(allocator, argv0_z);
    if (spec.opts.workdir.len > 0) {
        try argv.append(allocator, "-w");
        try argv.append(allocator, spec.opts.workdir);
    }
    for (spec.opts.env) |e| {
        try argv.append(allocator, "-e");
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "{s}={s}", .{ e.key, e.value }));
    }
    for (spec.opts.volumes) |v| {
        try argv.append(allocator, "-v");
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "{s}:{s}", .{ v.host, v.container }));
    }
    if (spec.rw_dir.len > 0) {
        try argv.append(allocator, "--rw-dir");
        try argv.append(allocator, spec.rw_dir);
    }
    if (console) |c| {
        try argv.append(allocator, "--console-fd");
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{c[1]}));
    }
    try argv.append(allocator, "--");
    for (spec.cmd_argv) |a| try argv.append(allocator, try allocator.dupe(u8, a));

    var zargs: std.ArrayList([:0]const u8) = .empty;
    defer {
        for (zargs.items) |z| allocator.free(z);
        zargs.deinit(allocator);
    }
    for (argv.items) |s| {
        const z = try allocator.allocSentinel(u8, s.len, 0);
        @memcpy(z, s);
        try zargs.append(allocator, z);
    }
    var cargv = try allocator.alloc(?[*:0]const u8, zargs.items.len + 1);
    defer allocator.free(cargv);
    for (zargs.items, 0..) |z, i| cargv[i] = z.ptr;
    cargv[zargs.items.len] = null;

    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        const child_console: std.posix.fd_t = if (console) |c| c[1] else -1;
        closeInheritedFds(child_console);
        if (child_console >= 0) clearCloexec(child_console);
        _ = std.c.execve(zargs.items[0].ptr, @ptrCast(cargv.ptr), std.c.environ);
        std.c._exit(127);
    }
    var status: i32 = 0;
    var pty_master: std.posix.fd_t = -1;
    if (console) |c| {
        ns.close(c[1]);
        pty_master = (ns.recvFd(c[0]) catch null) orelse -1;
        if (pty_master >= 0) container_pty.syncWindowSize(pty_master);
    }
    const saved_mode = if (pty_master >= 0) ns.rawMode(std.c.STDIN_FILENO) else null;
    defer if (saved_mode) |m| ns.restoreMode(std.c.STDIN_FILENO, m);
    defer if (pty_master >= 0) ns.close(pty_master);
    // Blocks on the terminal until the next keystroke, so it is never joined.
    if (if (pty_master >= 0)
        std.Thread.spawn(.{}, container_pty.copyTerminalToMaster, .{pty_master}) catch null
    else
        null) |t| t.detach();
    const out_thread = if (pty_master >= 0)
        std.Thread.spawn(.{}, container_pty.pumpMasterToStdout, .{pty_master}) catch null
    else
        null;
    const deadline_ms: ?i64 = if (timeout_ms == 0) null else monotonicMs() + @as(i64, @intCast(timeout_ms));
    while (true) {
        const w = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (w == pid) break;
        if (w < 0 and std.c.errno(-1) != .CHILD) return error.ForkFailed;
        if (deadline_ms) |deadline| {
            if (monotonicMs() > deadline) {
                _ = std.c.kill(pid, std.c.SIG.KILL);
                while (std.c.waitpid(pid, &status, 0) < 0 and std.c.errno(-1) == .INTR) {}
                return error.ExecTimeout;
            }
        }
        sleepMs(10);
    }
    if (out_thread) |t| t.join();
    return ns.exitCode(@bitCast(status));
}

pub fn parseCliArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !Spec {
    var mount_dir: ?[]const u8 = null;
    var log_path: ?[]const u8 = null;
    var vfs_argv0: ?[]const u8 = null;
    var workdir: ?[]const u8 = null;
    var env_list: std.ArrayList(run_flags.EnvPair) = .empty;
    var vol_list: std.ArrayList(run_flags.Volume) = .empty;
    var cmd_list: std.ArrayList([]const u8) = .empty;
    var console_fd: std.posix.fd_t = -1;
    var rw_dir: []const u8 = "";
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
        if (std.mem.eql(u8, arg, "--mount")) {
            mount_dir = try allocator.dupe(u8, args.next() orelse return error.BadArgs);
            continue;
        }
        if (std.mem.eql(u8, arg, "--log")) {
            log_path = try allocator.dupe(u8, args.next() orelse return error.BadArgs);
            continue;
        }
        if (std.mem.eql(u8, arg, "--argv0")) {
            vfs_argv0 = try allocator.dupe(u8, args.next() orelse return error.BadArgs);
            continue;
        }
        if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--workdir")) {
            workdir = try allocator.dupe(u8, args.next() orelse return error.BadArgs);
            continue;
        }
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--env")) {
            const e = args.next() orelse return error.BadArgs;
            const pair = try run_flags.parseEnvArg(e);
            try env_list.append(allocator, .{
                .key = try allocator.dupe(u8, pair.key),
                .value = try allocator.dupe(u8, pair.value),
            });
            continue;
        }
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--volume")) {
            const v = args.next() orelse return error.BadArgs;
            const vol = try run_flags.parseVolumeSpec(v);
            try vol_list.append(allocator, .{
                .host = try allocator.dupe(u8, vol.host),
                .container = try allocator.dupe(u8, vol.container),
                .read_only = vol.read_only,
            });
            continue;
        }
        if (std.mem.eql(u8, arg, "--console-fd")) {
            const n = args.next() orelse return error.BadArgs;
            console_fd = @intCast(std.fmt.parseInt(i32, n, 10) catch return error.BadArgs);
            continue;
        }
        if (std.mem.eql(u8, arg, "--rw-dir")) {
            rw_dir = try allocator.dupe(u8, args.next() orelse return error.BadArgs);
            continue;
        }
        return error.BadArgs;
    }
    const mount = mount_dir orelse return error.BadArgs;
    const log = log_path orelse return error.BadArgs;
    const argv0 = vfs_argv0 orelse return error.BadArgs;
    const cmd = try cmd_list.toOwnedSlice(allocator);
    if (cmd.len == 0) return error.BadArgs;
    const wd = workdir orelse try allocator.dupe(u8, "");
    return .{
        .mount_dir = mount,
        .log_path = log,
        .vfs_argv0 = argv0,
        .cmd_argv = cmd,
        .opts = .{
            .env = try env_list.toOwnedSlice(allocator),
            .workdir = wd,
            .volumes = try vol_list.toOwnedSlice(allocator),
            .ports = &.{},
            .tty = false,
            .interactive = false,
        },
        .rw_dir = rw_dir,
        .use_tty = console_fd >= 0,
        .console_fd = console_fd,
    };
}

fn monotonicMs() i64 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divFloor(@as(i64, @intCast(ts.nsec)), 1_000_000);
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
    if (n <= 0) return error.ExecFailed;
    return allocator.dupe(u8, buf[0..@intCast(n)]);
}

fn closeInheritedFds(keep: std.posix.fd_t) void {
    var fd: i32 = 3;
    while (fd < 512) : (fd += 1) {
        if (fd != keep) _ = std.c.close(fd);
    }
}

fn clearCloexec(fd: std.posix.fd_t) void {
    _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, 0));
}

fn openLogAppend(path: []const u8) std.posix.fd_t {
    const path_z = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return -1;
    defer std.heap.page_allocator.free(path_z);
    @memcpy(path_z, path);
    return std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(std.c.mode_t, 0o644));
}

fn allocZ(s: []const u8) ![:0]const u8 {
    const out = try std.heap.page_allocator.allocSentinel(u8, s.len, 0);
    @memcpy(out, s);
    return out;
}

pub const Error = error{
    BadArgs,
    UserNamespacesRequired,
    SetupFailed,
    CommandNotFound,
    ExecFailed,
    ForkFailed,
    ExecTimeout,
};

test "errorExitCode separates setup and exec failures" {
    try std.testing.expectEqual(@as(u8, 127), errorExitCode(error.CommandNotFound));
    try std.testing.expectEqual(@as(u8, 126), errorExitCode(error.ExecFailed));
    try std.testing.expectEqual(@as(u8, 125), errorExitCode(error.SetupFailed));
    try std.testing.expectEqual(@as(u8, 125), errorExitCode(error.UserNamespacesRequired));
}
