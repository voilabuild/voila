const std = @import("std");
const fuse_linux = @import("fuse_linux.zig");
const fuse_vfs_mod = @import("fuse_vfs.zig");
const voila_vfs_mod = @import("voila_vfs.zig");
const voila_loader = @import("voila_loader.zig");
const voila_registry = @import("voila_registry.zig");
const voila_registry_creds = @import("voila_registry_creds.zig");
const voila_login_creds = @import("voila_login_creds.zig");
const posix_util = @import("posix_util.zig");
const container_store = @import("container_store.zig");
const container_lifecycle = @import("container_lifecycle.zig");
const mount_exec = @import("mount_exec.zig");
const types = @import("runtime/types.zig");
const container_run_opts = @import("container_run_opts.zig");
const container_bind = @import("container_bind.zig");
const container_chroot = @import("container_chroot.zig");
const container_userns = @import("container_userns.zig");
const container_isolated_exec = @import("container_isolated_exec.zig");
const container_ports = @import("container_ports.zig");
const container_pty = @import("container_pty.zig");
const run_cli_parse = @import("run_cli_parse.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const ServeCtx = struct {
    session: fuse_linux.Session,
    err: ?anyerror,
};

fn markExited(allocator: std.mem.Allocator, st: *container_store.State) void {
    allocator.free(st.status);
    st.status = allocator.dupe(u8, "exited") catch "exited";
    st.pid = 0;
}

fn setStatus(allocator: std.mem.Allocator, st: *container_store.State, status: []const u8) void {
    allocator.free(st.status);
    st.status = allocator.dupe(u8, status) catch status;
}

fn needsIsolation(spec: types.RunSpec) bool {
    return spec.workdir.len > 0 or spec.volumes.len > 0 or spec.tty or spec.interactive or spec.ports.len > 0;
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, voila_root: []const u8, spec: types.RunSpec) !u8 {
    if (needsIsolation(spec) and !container_userns.probeNow(io, allocator)) {
        std.debug.print(
            "voila: -w, -v, -it, and -p require user namespaces on this host (often blocked by AppArmor on Ubuntu 24.04+). Re-run install.sh to install the voila AppArmor profile, then try again.\n",
            .{},
        );
        return error.UserNamespacesRequired;
    }
    try container_lifecycle.ensureNameFree(allocator, voila_root, spec.name);
    if (spec.detach) return runDetached(io, allocator, voila_root, spec);
    return runForeground(io, allocator, voila_root, spec);
}

pub fn runOptsFromSpec(allocator: std.mem.Allocator, spec: types.RunSpec) !container_run_opts.RunOpts {
    var env: std.ArrayList(run_cli_parse.EnvPair) = .empty;
    for (spec.env) |e| {
        try env.append(allocator, .{
            .key = try allocator.dupe(u8, e.key),
            .value = try allocator.dupe(u8, e.value),
        });
    }
    var volumes: std.ArrayList(run_cli_parse.Volume) = .empty;
    for (spec.volumes) |v| {
        try volumes.append(allocator, .{
            .host = try allocator.dupe(u8, v.host),
            .container = try allocator.dupe(u8, v.container),
            .read_only = v.read_only,
        });
    }
    const ports = try allocator.alloc(run_cli_parse.PortMap, spec.ports.len);
    @memcpy(ports, spec.ports);
    return .{
        .env = try env.toOwnedSlice(allocator),
        .workdir = try allocator.dupe(u8, spec.workdir),
        .volumes = try volumes.toOwnedSlice(allocator),
        .ports = ports,
        .tty = spec.tty,
        .interactive = spec.interactive,
    };
}

pub fn runWorker(io: std.Io, allocator: std.mem.Allocator, voila_root: []const u8, container_id: []const u8) !u8 {
    _ = std.c.setpgid(0, 0);
    var st = try container_store.readState(allocator, voila_root, container_id);
    const argv = try readCmdArgv(allocator, voila_root, container_id);
    defer freeArgv(allocator, argv);
    st.pid = @intCast(std.c.getpid());
    setStatus(allocator, &st, "running");
    try container_store.writeState(allocator, voila_root, st);
    const image = try allocator.dupe(u8, st.image);
    const mount_dir = try allocator.dupe(u8, st.mount_dir);
    const log_path = try allocator.dupe(u8, st.log_path);
    container_store.freeState(allocator, st);
    defer allocator.free(image);
    defer allocator.free(mount_dir);
    defer allocator.free(log_path);
    const opts = try container_run_opts.readRunOpts(allocator, voila_root, container_id);
    defer opts.deinit(allocator);
    const code = runMounted(io, allocator, voila_root, image, mount_dir, log_path, argv, opts) catch 1;
    var st_exit = try container_store.readState(allocator, voila_root, container_id);
    defer container_store.freeState(allocator, st_exit);
    markExited(allocator, &st_exit);
    try container_store.writeState(allocator, voila_root, st_exit);
    return code;
}

fn runForeground(io: std.Io, allocator: std.mem.Allocator, voila_root: []const u8, spec: types.RunSpec) !u8 {
    const id = try container_store.newId(allocator);
    defer allocator.free(id);
    const mount_dir = try std.fmt.allocPrint(allocator, "/tmp/zig-fuse-run-mnt-{s}", .{id});
    defer allocator.free(mount_dir);
    const log_path = try container_store.logPath(allocator, voila_root, id);
    defer allocator.free(log_path);
    var st = try ownedState(allocator, id, spec.name, spec.image, "created", 0, mount_dir, log_path, spec.rm_on_exit);
    defer container_store.freeState(allocator, st);
    try container_store.writeState(allocator, voila_root, st);
    try writeCmdArgv(allocator, voila_root, id, spec.argv);
    const opts = try runOptsFromSpec(allocator, spec);
    defer opts.deinit(allocator);
    try container_run_opts.writeRunOpts(allocator, voila_root, id, opts);
    const code = try spawnContainerWorkerAndWait(io, allocator, voila_root, id, log_path, &st);
    var st_exit = try container_store.readState(allocator, voila_root, id);
    defer container_store.freeState(allocator, st_exit);
    markExited(allocator, &st_exit);
    try container_store.writeState(allocator, voila_root, st_exit);
    if (spec.rm_on_exit) container_store.removeContainer(allocator, voila_root, id);
    return code;
}

fn spawnContainerWorkerAndWait(
    io: std.Io,
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    id: []const u8,
    log_path: []const u8,
    st: *container_store.State,
) !u8 {
    const exe = try selfExePath(allocator);
    defer allocator.free(exe);
    const root_z = try allocator.dupe(u8, voila_root);
    defer allocator.free(root_z);
    const id_z = try allocator.dupe(u8, id);
    defer allocator.free(id_z);
    var worker = try std.process.spawn(io, .{
        .argv = &[_][]const u8{
            exe,
            "container-worker",
            "-root",
            root_z,
            "-id",
            id_z,
        },
        .pgid = 0,
    });
    if (worker.id) |wp| {
        st.pid = @intCast(wp);
        setStatus(allocator, st, "running");
        try container_store.writeState(allocator, voila_root, st.*);
    }
    const term = try worker.wait(io);
    try printLogFile(log_path);
    return switch (term) {
        .exited => |c| c,
        else => 1,
    };
}

fn printLogFile(path: []const u8) !void {
    const data = posix_util.readFileAlloc(std.heap.page_allocator, path, 16 * 1024 * 1024) catch return;
    defer std.heap.page_allocator.free(data);
    writeAllFd(std.c.STDOUT_FILENO, data);
}

fn runDetached(io: std.Io, allocator: std.mem.Allocator, voila_root: []const u8, spec: types.RunSpec) !u8 {
    const id = try container_store.newId(allocator);
    const mount_dir = try std.fmt.allocPrint(allocator, "/tmp/zig-fuse-run-mnt-{s}", .{id});
    const log_path = try container_store.logPath(allocator, voila_root, id);
    var st = try ownedState(allocator, id, spec.name, spec.image, "created", 0, mount_dir, log_path, spec.rm_on_exit);
    defer container_store.freeState(allocator, st);
    try container_store.writeState(allocator, voila_root, st);
    try writeCmdArgv(allocator, voila_root, id, spec.argv);
    const opts = try runOptsFromSpec(allocator, spec);
    defer opts.deinit(allocator);
    try container_run_opts.writeRunOpts(allocator, voila_root, id, opts);
    const exe = try selfExePath(allocator);
    defer allocator.free(exe);
    const root_z = try allocator.dupe(u8, voila_root);
    defer allocator.free(root_z);
    const id_z = try allocator.dupe(u8, id);
    defer allocator.free(id_z);
    const log_fd = openLogAppend(log_path);
    const log_out = if (log_fd >= 0)
        std.Io.File{ .handle = log_fd, .flags = .{ .nonblocking = false } }
    else
        std.Io.File{ .handle = std.c.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
    const worker = try std.process.spawn(io, .{
        .argv = &[_][]const u8{
            exe,
            "container-worker",
            "-root",
            root_z,
            "-id",
            id_z,
        },
        .stdin = .ignore,
        .stdout = .{ .file = log_out },
        .stderr = .{ .file = log_out },
        .pgid = 0,
    });
    if (worker.id) |wp| {
        st.pid = @intCast(wp);
        setStatus(allocator, &st, "running");
        try container_store.writeState(allocator, voila_root, st);
    }
    const stdout_fd = std.c.STDOUT_FILENO;
    _ = std.c.write(stdout_fd, id.ptr, id.len);
    _ = std.c.write(stdout_fd, "\n", 1);
    allocator.free(id);
    allocator.free(mount_dir);
    allocator.free(log_path);
    return 0;
}

fn runMounted(
    io: std.Io,
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    image: []const u8,
    mount_dir: []const u8,
    log_path: []const u8,
    cmd_argv: []const []const u8,
    opts: container_run_opts.RunOpts,
) !u8 {
    const require_isolation = opts.workdir.len > 0 or opts.volumes.len > 0 or opts.tty or opts.interactive or opts.ports.len > 0;
    if (!fuse_linux.canUseFuse()) return error.NeedFuse;
    voila_registry.setIo(io, allocator);
    try voila_login_creds.loadIntoHub(allocator);
    try voila_registry_creds.loadFromCredsFile(allocator, voila_root);
    try voila_registry.loadFromEnv(allocator);
    const tree = try voila_loader.loadTreeRoot(io, allocator, voila_root, image);
    var fuse_vfs: fuse_vfs_mod.FuseVfs = .{ .voila = voila_vfs_mod.VoilaVfs.initFromTree(allocator, tree) };
    defer fuse_vfs.deinit();
    const vfs_exec = try mount_exec.resolveArgv0VfsPath(allocator, &fuse_vfs, cmd_argv[0]);
    defer allocator.free(vfs_exec);
    try posix_util.makePath(mount_dir);
    var ctx: ServeCtx = .{
        .session = try fuse_linux.mountSession(allocator, mount_dir, &fuse_vfs),
        .err = null,
    };
    const thread = try std.Thread.spawn(.{}, struct {
        fn serve(shared: *ServeCtx) void {
            fuse_linux.serveSession(&shared.session) catch |e| {
                shared.err = e;
            };
        }
    }.serve, .{&ctx});
    const forwarders = try container_ports.start(io, opts.ports);
    defer container_ports.stopAll(forwarders);
    const use_tty = opts.tty or opts.interactive;
    const result = execChild(io, allocator, mount_dir, vfs_exec, log_path, cmd_argv, opts, use_tty, false, require_isolation) catch |e| {
        ctx.session.stop();
        fusermountU(allocator, mount_dir);
        thread.join();
        ctx.session.deinit();
        return e;
    };
    ctx.session.stop();
    fusermountU(allocator, mount_dir);
    thread.join();
    ctx.session.deinit();
    if (ctx.err) |e| return e;
    if (require_isolation and result == 127) {
        std.debug.print(
            "voila: -w, -v, -it, and -p need user namespaces (re-run install.sh for the AppArmor voila profile).\n",
            .{},
        );
        return error.UserNamespacesRequired;
    }
    return result;
}

pub fn execInMount(
    io: std.Io,
    allocator: std.mem.Allocator,
    mount_dir: []const u8,
    vfs_argv0: []const u8,
    log_path: []const u8,
    cmd_argv: []const []const u8,
    use_tty: bool,
    opts: container_run_opts.RunOpts,
) !u8 {
    return execChild(io, allocator, mount_dir, vfs_argv0, log_path, cmd_argv, opts, use_tty, true, true);
}

fn execChild(
    io: std.Io,
    allocator: std.mem.Allocator,
    mount_dir: []const u8,
    vfs_argv0: []const u8,
    log_path: []const u8,
    cmd_argv: []const []const u8,
    opts: container_run_opts.RunOpts,
    use_tty: bool,
    is_exec: bool,
    require_isolation: bool,
) !u8 {
    if (!is_exec) try mount_exec.waitMountRootReady(mount_dir, io);
    if (require_isolation and !use_tty) {
        return container_isolated_exec.spawnAndWait(io, allocator, .{
            .mount_dir = mount_dir,
            .log_path = log_path,
            .vfs_argv0 = vfs_argv0,
            .cmd_argv = cmd_argv,
            .opts = opts,
            .use_tty = false,
        });
    }
    var argv_z: std.ArrayList([*:0]const u8) = .empty;
    defer {
        for (argv_z.items) |a| allocator.free(std.mem.span(a));
        argv_z.deinit(allocator);
    }
    const argv0_z = try allocSentinel(allocator, vfs_argv0);
    try argv_z.append(allocator, argv0_z.ptr);
    for (cmd_argv[1..]) |arg| {
        const z = try allocSentinel(allocator, arg);
        try argv_z.append(allocator, z.ptr);
    }
    var cargv = try allocator.alloc(?[*:0]const u8, argv_z.items.len + 1);
    defer allocator.free(cargv);
    for (argv_z.items, 0..) |a, i| cargv[i] = a;
    cargv[argv_z.items.len] = null;

    const log_fd = openLogAppend(log_path);

    var pty: ?container_pty.Pty = null;
    if (use_tty) pty = try container_pty.Pty.open();

    const pid = std.c.fork();
    if (pid == 0) {
        if (require_isolation) closeInheritedFds(log_fd, if (pty) |p| p.master else -1, if (pty) |p| p.slave else -1);
        const chroot_ok = childBeforeExec(mount_dir, log_fd, opts, use_tty, &pty, is_exec, require_isolation);
        if (require_isolation and !chroot_ok) std.c._exit(127);
        if (chroot_ok) {
            container_chroot.enterRootfs(mount_dir) catch std.c._exit(127);
            _ = std.c.execve(argv0_z.ptr, @ptrCast(cargv.ptr), std.c.environ);
        } else {
            mount_exec.execViaFuseMount(mount_dir, vfs_argv0, cmd_argv);
        }
        std.c._exit(127);
    }
    if (pid < 0) return error.ForkFailed;

    if (pty) |*p| {
        defer p.close();
        container_pty.syncWindowSize(p.master);
        const in_thread = std.Thread.spawn(.{}, container_pty.copyTerminalToMaster, .{p.master}) catch null;
        container_pty.pumpMasterToStdout(p.master);
        if (in_thread) |t| t.join();
    }

    var status: i32 = 0;
    while (std.c.waitpid(pid, &status, 0) < 0 and std.c.errno(-1) == .INTR) {}
    if (log_fd >= 0) _ = std.c.close(log_fd);
    const st: u32 = @bitCast(status);
    if (!std.c.W.IFEXITED(st)) return 1;
    return @intCast(std.c.W.EXITSTATUS(st));
}

fn childBeforeExec(
    mount_dir: []const u8,
    log_fd: std.posix.fd_t,
    opts: container_run_opts.RunOpts,
    use_tty: bool,
    pty: *?container_pty.Pty,
    is_exec: bool,
    require_isolation: bool,
) bool {
    _ = std.c.setpgid(0, 0);
    const chroot_ok = if (require_isolation) blk: {
        if (!container_bind.enterUserNamespaceOnly()) break :blk false;
        if (opts.volumes.len != 0) {
            if (!container_bind.attachPrivateMountRoot(mount_dir)) break :blk false;
            if (!container_bind.applyVolumeBinds(mount_dir, opts.volumes)) break :blk false;
        }
        break :blk true;
    } else false;
    for (opts.env) |e| {
        const key_z = std.heap.page_allocator.allocSentinel(u8, e.key.len, 0) catch std.c._exit(127);
        @memcpy(key_z, e.key);
        const val_z = std.heap.page_allocator.allocSentinel(u8, e.value.len, 0) catch std.c._exit(127);
        @memcpy(val_z, e.value);
        _ = setenv(key_z, val_z, 1);
    }
    if (opts.workdir.len > 0) {
        if (chroot_ok) {
            const cwd_z = std.heap.page_allocator.allocSentinel(u8, opts.workdir.len, 0) catch std.c._exit(127);
            @memcpy(cwd_z, opts.workdir);
            _ = std.c.chdir(cwd_z);
        } else {
            const host_wd = std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}", .{ mount_dir, opts.workdir }) catch std.c._exit(127);
            defer std.heap.page_allocator.free(host_wd);
            const cwd_z = std.heap.page_allocator.allocSentinel(u8, host_wd.len, 0) catch std.c._exit(127);
            @memcpy(cwd_z, host_wd);
            _ = std.c.chdir(cwd_z);
        }
    }
    if (use_tty) {
        if (pty.*) |*p| p.useSlaveInChild() catch std.c._exit(127);
    } else if (!is_exec and log_fd >= 0) {
        _ = std.c.dup2(log_fd, std.c.STDOUT_FILENO);
        _ = std.c.dup2(log_fd, std.c.STDERR_FILENO);
        _ = std.c.close(log_fd);
    }
    return chroot_ok;
}

fn allocSentinel(allocator: std.mem.Allocator, s: []const u8) ![:0]const u8 {
    const out = try allocator.allocSentinel(u8, s.len, 0);
    @memcpy(out, s);
    return out;
}

fn pumpStream(src: std.posix.fd_t, log_fd: std.posix.fd_t, tee_tty: bool, tty_fd: std.posix.fd_t) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(src, &buf, buf.len);
        if (n == 0) break;
        if (n < 0) {
            if (std.c.errno(-1) == .AGAIN) {
                sleepMs(1);
                continue;
            }
            break;
        }
        const slice = buf[0..@intCast(n)];
        if (log_fd >= 0) writeAllFd(log_fd, slice);
        if (tee_tty) writeAllFd(tty_fd, slice);
    }
}

fn closeInheritedFds(log_fd: std.posix.fd_t, pty_master: std.posix.fd_t, pty_slave: std.posix.fd_t) void {
    var fd: i32 = 3;
    while (fd < 512) : (fd += 1) {
        if (fd == log_fd or fd == pty_master or fd == pty_slave) continue;
        _ = std.c.close(fd);
    }
}

fn sleepMs(ms: u64) void {
    var ts: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    while (std.c.nanosleep(&ts, &ts) == -1 and std.c.errno(-1) == .INTR) {}
}

fn writeAllFd(fd: std.posix.fd_t, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data[off..].ptr, data.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

fn openLogAppend(path: []const u8) std.posix.fd_t {
    const path_z = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return -1;
    defer std.heap.page_allocator.free(path_z);
    @memcpy(path_z, path);
    return std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(std.c.mode_t, 0o644));
}

fn ownedState(
    allocator: std.mem.Allocator,
    id: []const u8,
    name: []const u8,
    image: []const u8,
    status: []const u8,
    pid: i32,
    mount_dir: []const u8,
    log_path: []const u8,
    rm_on_exit: bool,
) !container_store.State {
    return .{
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
        .image = try allocator.dupe(u8, image),
        .status = try allocator.dupe(u8, status),
        .pid = pid,
        .mount_dir = try allocator.dupe(u8, mount_dir),
        .log_path = try allocator.dupe(u8, log_path),
        .rm_on_exit = rm_on_exit,
    };
}

fn fusermountU(allocator: std.mem.Allocator, mount_dir: []const u8) void {
    const cmd = std.fmt.allocPrint(allocator, "fusermount3 -u {s} 2>/dev/null || umount {s} 2>/dev/null", .{ mount_dir, mount_dir }) catch return;
    defer allocator.free(cmd);
    const cmd_z = allocator.allocSentinel(u8, cmd.len, 0) catch return;
    defer allocator.free(cmd_z);
    @memcpy(cmd_z, cmd);
    _ = posix_util.shell(cmd_z);
}

fn cmdPath(allocator: std.mem.Allocator, voila_root: []const u8, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/containers/{s}/cmd.json", .{ voila_root, id });
}

fn writeCmdArgv(allocator: std.mem.Allocator, voila_root: []const u8, id: []const u8, argv: []const []const u8) !void {
    const path = try cmdPath(allocator, voila_root, id);
    defer allocator.free(path);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '[');
    for (argv, 0..) |a, i| {
        if (i > 0) try buf.append(allocator, ',');
        try appendJsonString(allocator, &buf, a);
    }
    try buf.append(allocator, ']');
    try writeFile(path, buf.items);
}

fn readCmdArgv(allocator: std.mem.Allocator, voila_root: []const u8, id: []const u8) ![]const []const u8 {
    const path = try cmdPath(allocator, voila_root, id);
    defer allocator.free(path);
    const data = try posix_util.readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(data);
    const parsed = try std.json.parseFromSlice([][]const u8, allocator, data, .{});
    defer parsed.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    for (parsed.value) |s| try out.append(allocator, try allocator.dupe(u8, s));
    return try out.toOwnedSlice(allocator);
}

fn freeArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |a| allocator.free(a);
    allocator.free(argv);
}

fn selfExePath(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [4096]u8 = undefined;
    const n = std.c.readlink("/proc/self/exe", &buf, buf.len);
    if (n <= 0) return error.ExePathFailed;
    return allocator.dupe(u8, buf[0..@intCast(n)]);
}

fn appendJsonString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"', '\\' => {
                try buf.append(allocator, '\\');
                try buf.append(allocator, c);
            },
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

fn writeFile(path: []const u8, data: []const u8) !void {
    const path_z = try std.heap.page_allocator.allocSentinel(u8, path.len, 0);
    defer std.heap.page_allocator.free(path_z);
    @memcpy(path_z, path);
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.FileOpenFailed;
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data[off..].ptr, data.len - off);
        if (n <= 0) return error.FileWriteFailed;
        off += @intCast(n);
    }
}

pub const Error = error{
    NeedFuse,
    MountNotReady,
    ExecNotFound,
    FileOpenFailed,
    FileWriteFailed,
    ExePathFailed,
    ForkFailed,
};
