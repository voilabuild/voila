const std = @import("std");
const fuse_linux = @import("fuse_linux.zig");
const fuse_vfs_mod = @import("fuse_vfs.zig");
const voila_vfs_mod = @import("voila_vfs.zig");
const voila_loader = @import("voila_loader.zig");
const voila_registry = @import("voila_registry.zig");
const voila_registry_creds = @import("voila_registry_creds.zig");
const posix_util = @import("posix_util.zig");
const container_store = @import("container_store.zig");
const container_lifecycle = @import("container_lifecycle.zig");
const types = @import("runtime/types.zig");

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

pub fn run(io: std.Io, allocator: std.mem.Allocator, voila_root: []const u8, spec: types.RunSpec) !u8 {
    try container_lifecycle.ensureNameFree(allocator, voila_root, spec.name);
    if (spec.detach) return runDetached(io, allocator, voila_root, spec);
    return runForeground(io, allocator, voila_root, spec);
}

pub fn runWorker(io: std.Io, allocator: std.mem.Allocator, voila_root: []const u8, container_id: []const u8) !u8 {
    _ = std.c.setpgid(0, 0);
    var st = try container_store.readState(allocator, voila_root, container_id);
    defer container_store.freeState(allocator, st);
    const argv = try readCmdArgv(allocator, voila_root, container_id);
    defer freeArgv(allocator, argv);
    st.pid = @intCast(std.c.getpid());
    setStatus(allocator, &st, "running");
    try container_store.writeState(allocator, voila_root, st);
    const code = runMounted(io, allocator, voila_root, st.image, st.mount_dir, st.log_path, argv, false, container_id, voila_root) catch 1;
    st = try container_store.readState(allocator, voila_root, container_id);
    defer container_store.freeState(allocator, st);
    markExited(allocator, &st);
    try container_store.writeState(allocator, voila_root, st);
    if (st.rm_on_exit) container_store.removeContainer(allocator, voila_root, container_id);
    return code;
}

fn runForeground(io: std.Io, allocator: std.mem.Allocator, voila_root: []const u8, spec: types.RunSpec) !u8 {
    const id = try container_store.newId(allocator);
    defer allocator.free(id);
    const mount_dir = try std.fmt.allocPrint(allocator, "/tmp/voila-run-mnt-{s}", .{id});
    defer allocator.free(mount_dir);
    const log_path = try container_store.logPath(allocator, voila_root, id);
    defer allocator.free(log_path);
    const st = try ownedState(allocator, id, spec.name, spec.image, "running", @intCast(std.c.getpid()), mount_dir, log_path, spec.rm_on_exit);
    defer container_store.freeState(allocator, st);
    try container_store.writeState(allocator, voila_root, st);
    try writeCmdArgv(allocator, voila_root, id, spec.argv);
    const code = runMounted(io, allocator, voila_root, spec.image, mount_dir, log_path, spec.argv, true, id, voila_root) catch 1;
    var st_exit = try container_store.readState(allocator, voila_root, id);
    defer container_store.freeState(allocator, st_exit);
    markExited(allocator, &st_exit);
    try container_store.writeState(allocator, voila_root, st_exit);
    if (spec.rm_on_exit) container_store.removeContainer(allocator, voila_root, id);
    return code;
}

fn runDetached(io: std.Io, allocator: std.mem.Allocator, voila_root: []const u8, spec: types.RunSpec) !u8 {
    const id = try container_store.newId(allocator);
    const mount_dir = try std.fmt.allocPrint(allocator, "/tmp/voila-run-mnt-{s}", .{id});
    const log_path = try container_store.logPath(allocator, voila_root, id);
    var st = try ownedState(allocator, id, spec.name, spec.image, "created", 0, mount_dir, log_path, spec.rm_on_exit);
    defer container_store.freeState(allocator, st);
    try container_store.writeState(allocator, voila_root, st);
    try writeCmdArgv(allocator, voila_root, id, spec.argv);
    const exe = try selfExePath(allocator);
    defer allocator.free(exe);
    const root_z = try allocator.dupe(u8, voila_root);
    defer allocator.free(root_z);
    const id_z = try allocator.dupe(u8, id);
    defer allocator.free(id_z);
    const worker = try std.process.spawn(io, .{
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
    tee_tty: bool,
    container_id: []const u8,
    store_root: []const u8,
) !u8 {
    _ = container_id;
    _ = store_root;
    if (!fuse_linux.canUseFuse()) return error.NeedFuse;
    voila_registry.setIo(io, allocator);
    try voila_registry_creds.loadFromCredsFile(allocator, voila_root);
    try voila_registry.loadFromEnv(allocator);
    const tree = try voila_loader.loadTreeRoot(allocator, voila_root, image);
    var fuse_vfs: fuse_vfs_mod.FuseVfs = .{ .voila = voila_vfs_mod.VoilaVfs.initFromTree(allocator, tree) };
    defer fuse_vfs.deinit();
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
    const result = execChild(io, allocator, mount_dir, log_path, cmd_argv, tee_tty);
    ctx.session.stop();
    fusermountU(allocator, mount_dir);
    thread.join();
    ctx.session.deinit();
    if (ctx.err) |e| return e;
    return result;
}

fn execChild(
    io: std.Io,
    allocator: std.mem.Allocator,
    mount_dir: []const u8,
    log_path: []const u8,
    cmd_argv: []const []const u8,
    tee_tty: bool,
) !u8 {
    const host_argv0 = try resolveHostArgv0(allocator, mount_dir, cmd_argv[0]);
    defer allocator.free(host_argv0);
    try waitPath(host_argv0, io);
    var argv_host: std.ArrayList([]const u8) = .empty;
    defer argv_host.deinit(allocator);
    try argv_host.append(allocator, host_argv0);
    for (cmd_argv[1..]) |arg| try argv_host.append(allocator, arg);

    const log_fd = openLogAppend(log_path);
    defer {
        if (log_fd >= 0) _ = std.c.close(log_fd);
    }

    const spawn_stdio: struct { stdout: std.process.SpawnOptions.StdIo, stderr: std.process.SpawnOptions.StdIo } = if (tee_tty) .{
        .stdout = .pipe,
        .stderr = .pipe,
    } else blk: {
        const log_out = std.Io.File{ .handle = log_fd, .flags = .{ .nonblocking = false } };
        const err_fd = std.c.dup(log_fd);
        if (err_fd < 0) return error.FileOpenFailed;
        const log_err = std.Io.File{ .handle = err_fd, .flags = .{ .nonblocking = false } };
        break :blk .{ .stdout = .{ .file = log_out }, .stderr = .{ .file = log_err } };
    };

    var child = try std.process.spawn(io, .{
        .argv = argv_host.items,
        .stdin = .inherit,
        .stdout = spawn_stdio.stdout,
        .stderr = spawn_stdio.stderr,
    });
    defer if (!tee_tty) {
        if (child.stderr) |f| _ = std.c.close(f.handle);
    };

    var stdout_thread: ?std.Thread = null;
    var stderr_thread: ?std.Thread = null;
    if (tee_tty) {
        stdout_thread = std.Thread.spawn(.{}, pumpStream, .{ child.stdout.?.handle, log_fd, true, std.c.STDOUT_FILENO }) catch null;
        stderr_thread = std.Thread.spawn(.{}, pumpStream, .{ child.stderr.?.handle, log_fd, true, std.c.STDERR_FILENO }) catch null;
    }

    const term = try child.wait(io);
    if (stdout_thread) |t| t.join();
    if (stderr_thread) |t| t.join();
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
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

const default_path_dirs = [_][]const u8{
    "/usr/local/sbin",
    "/usr/local/bin",
    "/usr/sbin",
    "/usr/bin",
    "/sbin",
    "/bin",
};

fn resolveHostArgv0(allocator: std.mem.Allocator, mount_dir: []const u8, argv0: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, argv0, '/') != null) return hostPath(allocator, mount_dir, argv0);
    for (default_path_dirs) |dir| {
        const candidate = try std.fmt.allocPrint(allocator, "{s}{s}/{s}", .{ mount_dir, dir, argv0 });
        if (posix_util.access(candidate)) return candidate;
        allocator.free(candidate);
    }
    return hostPath(allocator, mount_dir, argv0);
}

fn hostPath(allocator: std.mem.Allocator, mount_dir: []const u8, argv0: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, argv0, "/")) return std.fmt.allocPrint(allocator, "{s}{s}", .{ mount_dir, argv0 });
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ mount_dir, argv0 });
}

fn waitPath(path: []const u8, io: std.Io) !void {
    for (0..30_000) |_| {
        if (posix_util.access(path)) return;
        try io.sleep(std.Io.Duration.fromMilliseconds(1), .awake);
    }
    return error.MountNotReady;
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

pub const Error = error{NeedFuse, MountNotReady, FileOpenFailed, FileWriteFailed, ExePathFailed};
