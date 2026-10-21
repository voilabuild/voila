//! Enter user/mount namespaces and chroot without holding FUSE fds (re-exec entrypoint).
const std = @import("std");
const container_bind = @import("container_bind.zig");
const container_chroot = @import("container_chroot.zig");
const container_run_opts = @import("container_run_opts.zig");
const run_cli_parse = @import("run_cli_parse.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub const Spec = struct {
    mount_dir: []const u8,
    log_path: []const u8,
    vfs_argv0: []const u8,
    cmd_argv: []const []const u8,
    opts: container_run_opts.RunOpts,
    use_tty: bool,
};

pub fn run(spec: Spec) !u8 {
    if (!container_bind.enterUserNamespaceOnly()) return error.UserNamespacesRequired;
    if (spec.opts.volumes.len > 0) {
        if (!container_bind.attachPrivateMountRoot(spec.mount_dir)) return error.UserNamespacesRequired;
        if (!container_bind.applyVolumeBinds(spec.mount_dir, spec.opts.volumes)) return error.UserNamespacesRequired;
    }
    for (spec.opts.env) |e| {
        const key_z = std.heap.page_allocator.allocSentinel(u8, e.key.len, 0) catch return error.ExecFailed;
        @memcpy(key_z, e.key);
        const val_z = std.heap.page_allocator.allocSentinel(u8, e.value.len, 0) catch return error.ExecFailed;
        @memcpy(val_z, e.value);
        _ = setenv(key_z, val_z, 1);
    }
    container_chroot.enterRootfs(spec.mount_dir) catch return error.ExecFailed;
    _ = std.c.chdir("/");
    if (spec.opts.workdir.len > 0) {
        const wd_z = std.heap.page_allocator.allocSentinel(u8, spec.opts.workdir.len, 0) catch return error.ExecFailed;
        @memcpy(wd_z, spec.opts.workdir);
        _ = std.c.chdir(wd_z);
    }
    const log_fd = openLogAppend(spec.log_path);
    if (!spec.use_tty and log_fd >= 0) {
        _ = std.c.dup2(log_fd, std.c.STDOUT_FILENO);
        _ = std.c.dup2(log_fd, std.c.STDERR_FILENO);
        _ = std.c.close(log_fd);
    }
    var argv_z: std.ArrayList([*:0]const u8) = .empty;
    defer {
        for (argv_z.items) |a| std.heap.page_allocator.free(std.mem.span(a));
        argv_z.deinit(std.heap.page_allocator);
    }
    const a0 = allocZ(spec.vfs_argv0) catch return error.ExecFailed;
    try argv_z.append(std.heap.page_allocator, a0.ptr);
    for (spec.cmd_argv[1..]) |arg| {
        const z = allocZ(arg) catch return error.ExecFailed;
        try argv_z.append(std.heap.page_allocator, z.ptr);
    }
    var cargv = try std.heap.page_allocator.alloc(?[*:0]const u8, argv_z.items.len + 1);
    defer std.heap.page_allocator.free(cargv);
    for (argv_z.items, 0..) |a, i| cargv[i] = a;
    cargv[argv_z.items.len] = null;
    _ = std.c.execve(a0.ptr, @ptrCast(cargv.ptr), std.c.environ);
    return error.ExecFailed;
}

pub fn spawnAndWait(_: std.Io, allocator: std.mem.Allocator, spec: Spec) !u8 {
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
        closeInheritedFds(-1, -1, -1);
        _ = std.c.execve(zargs.items[0].ptr, @ptrCast(cargv.ptr), std.c.environ);
        std.c._exit(127);
    }
    var status: i32 = 0;
    while (std.c.waitpid(pid, &status, 0) < 0 and std.c.errno(-1) == .INTR) {}
    const st: u32 = @bitCast(status);
    if (!std.c.W.IFEXITED(st)) return 1;
    const code: u8 = @intCast(std.c.W.EXITSTATUS(st));
    if (code == 127) return error.UserNamespacesRequired;
    return code;
}

pub fn parseCliArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !Spec {
    var mount_dir: ?[]const u8 = null;
    var log_path: ?[]const u8 = null;
    var vfs_argv0: ?[]const u8 = null;
    var workdir: ?[]const u8 = null;
    var env_list: std.ArrayList(run_cli_parse.EnvPair) = .empty;
    var vol_list: std.ArrayList(run_cli_parse.Volume) = .empty;
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
            const pair = try run_cli_parse.parseEnvArg(e);
            try env_list.append(allocator, .{
                .key = try allocator.dupe(u8, pair.key),
                .value = try allocator.dupe(u8, pair.value),
            });
            continue;
        }
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--volume")) {
            const v = args.next() orelse return error.BadArgs;
            const vol = try run_cli_parse.parseVolumeSpec(v);
            try vol_list.append(allocator, .{
                .host = try allocator.dupe(u8, vol.host),
                .container = try allocator.dupe(u8, vol.container),
                .read_only = vol.read_only,
            });
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
        .use_tty = false,
    };
}

fn selfExePath(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [4096]u8 = undefined;
    const n = std.c.readlink("/proc/self/exe", &buf, buf.len);
    if (n <= 0) return error.ExecFailed;
    return allocator.dupe(u8, buf[0..@intCast(n)]);
}

fn closeInheritedFds(log_fd: std.posix.fd_t, pty_master: std.posix.fd_t, pty_slave: std.posix.fd_t) void {
    var fd: i32 = 3;
    while (fd < 512) : (fd += 1) {
        if (fd == log_fd or fd == pty_master or fd == pty_slave) continue;
        _ = std.c.close(fd);
    }
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
    ExecFailed,
    ForkFailed,
};
