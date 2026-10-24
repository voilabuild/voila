const std = @import("std");
const fuse_linux = @import("../../mount/fuse/fuse_linux.zig");
const fuse_vfs_mod = @import("../../mount/fuse/fuse_vfs.zig");
const voila_vfs_mod = @import("../../mount/fuse/voila_vfs.zig");
const voila_loader = @import("../voila_loader.zig");
const voila_registry = @import("../../registry/voila_registry.zig");
const voila_registry_creds = @import("../../registry/voila_registry_creds.zig");
const voila_login_creds = @import("../../registry/voila_login_creds.zig");
const posix_util = @import("../../sys/posix_util.zig");
const ns = @import("../../sys/ns.zig");
const container_store = @import("./container_store.zig");
const container_lifecycle = @import("./container_lifecycle.zig");
const mount_exec = @import("../../mount/mount_exec.zig");
const types = @import("../types.zig");
const container_run_opts = @import("./container_run_opts.zig");
const container_userns = @import("./container_userns.zig");
const container_isolated_exec = @import("./container_isolated_exec.zig");
const container_fuse_sibling = @import("./container_fuse_sibling.zig");
const container_ports = @import("./container_ports.zig");
const userns_ids = @import("./userns_ids.zig");
const run_flags = @import("../run_flags.zig");

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

const userns_hint = "voila: run needs unprivileged user namespaces to enter the image root (often blocked by AppArmor on Ubuntu 24.04+). Re-run install.sh to install the voila AppArmor profile, then try again.\n";

pub fn run(io: std.Io, allocator: std.mem.Allocator, voila_root: []const u8, spec: types.RunSpec) !u8 {
    if (!container_userns.probeNow(io, allocator)) {
        std.debug.print(userns_hint, .{});
        return error.UserNamespacesRequired;
    }
    try container_lifecycle.ensureNameFree(allocator, voila_root, spec.name);
    if (spec.detach) return runDetached(io, allocator, voila_root, spec);
    return runForeground(io, allocator, voila_root, spec);
}

pub fn runOptsFromSpec(allocator: std.mem.Allocator, spec: types.RunSpec) !container_run_opts.RunOpts {
    var env: std.ArrayList(run_flags.EnvPair) = .empty;
    for (spec.env) |e| {
        try env.append(allocator, .{
            .key = try allocator.dupe(u8, e.key),
            .value = try allocator.dupe(u8, e.value),
        });
    }
    var volumes: std.ArrayList(run_flags.Volume) = .empty;
    for (spec.volumes) |v| {
        try volumes.append(allocator, .{
            .host = try allocator.dupe(u8, v.host),
            .container = try allocator.dupe(u8, v.container),
            .read_only = v.read_only,
        });
    }
    const ports = try allocator.alloc(run_flags.PortMap, spec.ports.len);
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
    const rw_dir = try rwDir(allocator, voila_root, container_id);
    defer allocator.free(rw_dir);
    const code = runMounted(io, allocator, voila_root, image, mount_dir, log_path, rw_dir, argv, opts) catch |e| {
        std.debug.print("voila: run failed: {}\n", .{e});
        return 1;
    };
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
    const code = try spawnContainerWorkerAndWait(io, allocator, voila_root, id, log_path, spec.tty or spec.interactive, &st);
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
    use_tty: bool,
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
    var took_terminal = false;
    if (worker.id) |wp| {
        // The worker has its own process group; it must own the terminal to read it.
        if (use_tty and ns.setForeground(std.c.STDIN_FILENO, @intCast(wp))) {
            took_terminal = true;
            _ = std.c.kill(-@as(std.c.pid_t, @intCast(wp)), std.c.SIG.CONT);
        }
        st.pid = @intCast(wp);
        setStatus(allocator, st, "running");
        try container_store.writeState(allocator, voila_root, st.*);
    }
    const term = try worker.wait(io);
    if (took_terminal) _ = ns.setForeground(std.c.STDIN_FILENO, ns.processGroup());
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
    rw_dir: []const u8,
    cmd_argv: []const []const u8,
    opts: container_run_opts.RunOpts,
) !u8 {
    if (!fuse_linux.canUseFuse()) return error.NeedFuse;
    voila_registry.setIo(io, allocator);
    try voila_login_creds.loadIntoHub(allocator);
    try voila_registry_creds.loadFromCredsFile(allocator, voila_root);
    try voila_registry.loadFromEnv(allocator);
    const root_ref = try voila_loader.resolveRootRef(io, allocator, voila_root, image);
    defer allocator.free(root_ref);
    const tree = try voila_loader.loadTreeRoot(io, allocator, voila_root, root_ref);
    var fuse_vfs: fuse_vfs_mod.FuseVfs = .{ .voila = voila_vfs_mod.VoilaVfs.initFromTree(allocator, tree) };
    defer fuse_vfs.deinit();
    const vfs_exec = try mount_exec.resolveArgv0VfsPath(allocator, &fuse_vfs, cmd_argv[0]);
    defer allocator.free(vfs_exec);
    const ids = userns_ids.detect(allocator, .{});
    var fuse_server = try container_fuse_sibling.startWith(io, allocator, voila_root, root_ref, mount_dir, .{
        .map_root = true,
        .subuid = ids.uid.sub,
        .subgid = ids.gid.sub,
    });
    defer fuse_server.deinit();
    const forwarders = try container_ports.start(io, opts.ports);
    defer container_ports.stopAll(forwarders);
    try mount_exec.waitMountRootReady(mount_dir, io);
    if (!fuse_server.alive()) return error.FuseServerFailed;

    defer releaseRwDir(allocator, rw_dir);
    return container_isolated_exec.spawnAndWait(io, allocator, .{
        .mount_dir = mount_dir,
        .log_path = log_path,
        .vfs_argv0 = vfs_exec,
        .cmd_argv = cmd_argv,
        .opts = opts,
        .rw_dir = rw_dir,
        .use_tty = opts.tty or opts.interactive,
    }, 0);
}

/// Disk-backed overlay upper for the container's writable root; removed with the container.
fn rwDir(allocator: std.mem.Allocator, voila_root: []const u8, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/containers/{s}/rw", .{ voila_root, id });
}

/// overlayfs leaves `work/work` mode 000; make it removable by `voila rm`.
fn releaseRwDir(allocator: std.mem.Allocator, rw_dir: []const u8) void {
    const path = std.fmt.allocPrintSentinel(allocator, "{s}/work/work", .{rw_dir}, 0) catch return;
    defer allocator.free(path);
    _ = std.c.chmod(path, 0o700);
}

pub fn execInMount(
    io: std.Io,
    allocator: std.mem.Allocator,
    mount_dir: []const u8,
    vfs_argv0: []const u8,
    cmd_argv: []const []const u8,
    use_tty: bool,
    opts: container_run_opts.RunOpts,
) !u8 {
    return container_isolated_exec.spawnAndWait(io, allocator, .{
        .mount_dir = mount_dir,
        .log_path = "",
        .vfs_argv0 = vfs_argv0,
        .cmd_argv = cmd_argv,
        .opts = opts,
        .use_tty = use_tty,
    }, 120_000);
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
