const std = @import("std");
const container_store = @import("container_store.zig");
const posix_util = @import("posix_util.zig");

pub fn ps(allocator: std.mem.Allocator, voila_root: []const u8) !void {
    const states = try container_store.listStates(allocator, voila_root);
    defer {
        for (states) |st| container_store.freeState(allocator, st);
        allocator.free(states);
    }
    std.debug.print("ID           NAME                 IMAGE                          STATUS    PID\n", .{});
    for (states) |st| {
        const name = if (st.name.len != 0) st.name else "-";
        std.debug.print("{s:<12} {s:<20} {s:<30} {s:<9} {d}\n", .{
            trimId(st.id),
            trimCol(name, 20),
            trimCol(st.image, 30),
            st.status,
            st.pid,
        });
    }
}

pub fn logs(io: std.Io, allocator: std.mem.Allocator, voila_root: []const u8, context_id: []const u8, follow: bool) !void {
    const id = try container_store.resolveId(allocator, voila_root, context_id);
    defer allocator.free(id);
    const log_path = blk: {
        const st = try container_store.readState(allocator, voila_root, id);
        defer container_store.freeState(allocator, st);
        break :blk try allocator.dupe(u8, st.log_path);
    };
    defer allocator.free(log_path);
    try dumpLog(log_path);
    if (!follow) return;
    var offset: i64 = fileLen(log_path) catch 0;
    while (containerRunning(allocator, voila_root, id)) {
        const n = try dumpLogFrom(log_path, offset);
        offset += n;
        try io.sleep(std.Io.Duration.fromMilliseconds(50), .awake);
    }
    _ = try dumpLogFrom(log_path, offset);
}

fn containerRunning(allocator: std.mem.Allocator, voila_root: []const u8, id: []const u8) bool {
    const st = container_store.readState(allocator, voila_root, id) catch return false;
    defer container_store.freeState(allocator, st);
    return isRunning(st);
}

pub fn stop(allocator: std.mem.Allocator, voila_root: []const u8, context_id: []const u8) !void {
    const id = try container_store.resolveId(allocator, voila_root, context_id);
    defer allocator.free(id);
    const st0 = try container_store.readState(allocator, voila_root, id);
    defer container_store.freeState(allocator, st0);
    terminateWorker(allocator, st0.pid, st0.mount_dir, std.c.SIG.TERM);
    var st = try container_store.readState(allocator, voila_root, id);
    defer container_store.freeState(allocator, st);
    allocator.free(st.status);
    st.status = try allocator.dupe(u8, "exited");
    st.pid = 0;
    try container_store.writeState(allocator, voila_root, st);
}

pub fn kill(allocator: std.mem.Allocator, voila_root: []const u8, context_id: []const u8, signal: i32) !void {
    const id = try container_store.resolveId(allocator, voila_root, context_id);
    defer allocator.free(id);
    const st = try container_store.readState(allocator, voila_root, id);
    defer container_store.freeState(allocator, st);
    if (st.pid <= 0) return;
    const sig: std.c.SIG = if (signal != 0) @enumFromInt(signal) else std.c.SIG.KILL;
    terminateWorker(allocator, st.pid, st.mount_dir, sig);
}

pub fn rm(allocator: std.mem.Allocator, voila_root: []const u8, context_id: []const u8) !void {
    const id = try container_store.resolveId(allocator, voila_root, context_id);
    defer allocator.free(id);
    const st = try container_store.readState(allocator, voila_root, id);
    defer container_store.freeState(allocator, st);
    terminateWorker(allocator, st.pid, st.mount_dir, std.c.SIG.KILL);
    ensureUnmounted(allocator, st.mount_dir);
    container_store.removeContainer(allocator, voila_root, id);
}

pub fn ensureNameFree(allocator: std.mem.Allocator, voila_root: []const u8, name: []const u8) !void {
    if (name.len == 0) return;
    const ids = try container_store.listIds(allocator, voila_root);
    defer {
        for (ids) |i| allocator.free(i);
        allocator.free(ids);
    }
    for (ids) |cid| {
        const st = container_store.readState(allocator, voila_root, cid) catch continue;
        defer container_store.freeState(allocator, st);
        if (st.name.len != 0 and std.mem.eql(u8, st.name, name)) return error.NameInUse;
    }
}

fn terminateWorker(allocator: std.mem.Allocator, worker_pid: i32, mount_dir: []const u8, sig: std.c.SIG) void {
    if (worker_pid > 0 and isPidAlive(worker_pid)) {
        _ = std.c.kill(worker_pid, sig);
        waitPid(worker_pid);
    }
    ensureUnmounted(allocator, mount_dir);
}

fn ensureUnmounted(allocator: std.mem.Allocator, mount_dir: []const u8) void {
    if (mount_dir.len == 0) return;
    for (0..40) |_| {
        if (!mountActive(mount_dir)) return;
        fusermountU(allocator, mount_dir);
        sleepMs(50);
    }
}

fn sleepMs(ms: u64) void {
    var ts: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    while (std.c.nanosleep(&ts, &ts) == -1 and std.c.errno(-1) == .INTR) {}
}

fn isRunning(st: container_store.State) bool {
    if (std.mem.eql(u8, st.status, "exited")) return false;
    if (st.pid > 0 and isPidAlive(st.pid)) return true;
    if (st.mount_dir.len != 0 and mountActive(st.mount_dir)) return true;
    return std.mem.eql(u8, st.status, "created");
}

fn isPidAlive(pid: i32) bool {
    if (pid <= 0) return false;
    return std.c.kill(pid, @enumFromInt(0)) == 0;
}

fn waitPid(pid: i32) void {
    if (pid <= 0) return;
    for (0..200) |_| {
        var status: i32 = 0;
        const rc = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (rc == pid) return;
        if (rc < 0) break;
        if (!isPidAlive(pid)) return;
        sleepMs(50);
    }
    if (isPidAlive(pid)) _ = std.c.kill(pid, std.c.SIG.KILL);
    _ = std.c.waitpid(pid, null, 0);
}

fn mountActive(mount_dir: []const u8) bool {
    const cmd = std.fmt.allocPrint(std.heap.page_allocator, "mountpoint -q {s}", .{mount_dir}) catch return false;
    defer std.heap.page_allocator.free(cmd);
    const cmd_z = std.heap.page_allocator.allocSentinel(u8, cmd.len, 0) catch return false;
    defer std.heap.page_allocator.free(cmd_z);
    @memcpy(cmd_z, cmd);
    return posix_util.shell(cmd_z) == 0;
}

fn dumpLog(path: []const u8) !void {
    const data = posix_util.readFileAlloc(std.heap.page_allocator, path, 16 * 1024 * 1024) catch return;
    defer std.heap.page_allocator.free(data);
    const stdout_fd = std.c.STDOUT_FILENO;
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(stdout_fd, data[off..].ptr, data.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
}

fn dumpLogFrom(path: []const u8, offset: i64) !i64 {
    const path_z = try std.heap.page_allocator.allocSentinel(u8, path.len, 0);
    defer std.heap.page_allocator.free(path_z);
    @memcpy(path_z, path);
    const fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return 0;
    defer _ = std.c.close(fd);
    _ = std.c.lseek(fd, offset, std.c.SEEK.SET);
    var buf: [4096]u8 = undefined;
    var written: i64 = 0;
    const stdout_fd = std.c.STDOUT_FILENO;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        const slice = buf[0..@intCast(n)];
        var off: usize = 0;
        while (off < slice.len) {
            const w = std.c.write(stdout_fd, slice[off..].ptr, slice.len - off);
            if (w <= 0) break;
            off += @intCast(w);
        }
        written += n;
    }
    return written;
}

fn fileLen(path: []const u8) !i64 {
    const path_z = try std.heap.page_allocator.allocSentinel(u8, path.len, 0);
    defer std.heap.page_allocator.free(path_z);
    @memcpy(path_z, path);
    const fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return 0;
    defer _ = std.c.close(fd);
    const off = std.c.lseek(fd, 0, std.c.SEEK.END);
    if (off < 0) return 0;
    return off;
}

fn fusermountU(allocator: std.mem.Allocator, mount_dir: []const u8) void {
    const cmd = std.fmt.allocPrint(allocator, "fusermount3 -u {s} 2>/dev/null || umount {s} 2>/dev/null", .{ mount_dir, mount_dir }) catch return;
    defer allocator.free(cmd);
    const cmd_z = allocator.allocSentinel(u8, cmd.len, 0) catch return;
    defer allocator.free(cmd_z);
    @memcpy(cmd_z, cmd);
    _ = posix_util.shell(cmd_z);
}

fn trimId(id: []const u8) []const u8 {
    return if (id.len > 12) id[0..12] else id;
}

fn trimCol(s: []const u8, max: usize) []const u8 {
    return if (s.len > max) s[0..max] else s;
}

pub const Error = error{NameInUse};
