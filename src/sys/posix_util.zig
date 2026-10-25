const std = @import("std");

/// Map a raw Linux syscall usize return to `std.posix.E` (uses thread errno when rc is -1).
pub fn syscallErr(rc: usize) std.posix.E {
    const signed: isize = @bitCast(rc);
    if (signed >= 0) return .SUCCESS;
    if (signed == -1) {
        const e: std.posix.E = @fromBackingInt(@intCast(std.c._errno().*));
        if (e != .SUCCESS) return e;
    }
    return std.posix.errno(rc);
}

pub fn syscallFailed(rc: usize) bool {
    return @as(isize, @bitCast(rc)) < 0;
}

fn toZ(allocator: std.mem.Allocator, path: []const u8) ![:0]const u8 {
    const out = try allocator.allocSentinel(u8, path.len, 0);
    @memcpy(out, path);
    return out;
}

pub fn access(path: []const u8) bool {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const rc = std.os.linux.access(buf[0..path.len :0], 0);
    return !syscallFailed(rc);
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    const path_z = try toZ(allocator, path);
    defer allocator.free(path_z);
    const fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) {
        const open_err: std.posix.E = @fromBackingInt(@intCast(std.c._errno().*));
        if (open_err == .SUCCESS) return error.Unexpected;
        if (open_err == .NOENT) return error.FileNotFound;
        return std.posix.unexpectedErrno(open_err);
    }
    defer _ = std.c.close(fd);
    var buf = try allocator.alloc(u8, 0);
    var total: usize = 0;
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, chunk[0..].ptr, chunk.len);
        if (n < 0) {
            const rd_err: std.posix.E = @fromBackingInt(@intCast(std.c._errno().*));
            if (rd_err == .SUCCESS) return error.Unexpected;
            return std.posix.unexpectedErrno(rd_err);
        }
        if (n == 0) break;
        const got: usize = @intCast(n);
        total += got;
        if (total > limit) return error.FileTooLarge;
        buf = try allocator.realloc(buf, total);
        @memcpy(buf[total - got .. total], chunk[0..got]);
    }
    return buf;
}

pub fn unlink(path: []const u8) void {
    const path_z = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return;
    defer std.heap.page_allocator.free(path_z);
    @memcpy(path_z, path);
    _ = std.c.unlink(path_z);
}

pub const EnvPair = struct {
    name: []const u8,
    value: []const u8,
};

pub fn runArgvWithEnv(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    env_pairs: []const EnvPair,
) !void {
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const ptr = std.c.environ;
    var n: usize = 0;
    while (ptr[n] != null) : (n += 1) {}
    const slice: []const [*:0]const u8 = @ptrCast(ptr[0..n]);
    try env.putPosixBlock(.{ .slice = slice });
    for (env_pairs) |pair| {
        try env.put(pair.name, pair.value);
    }
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = &env,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| {
            if (code != 0) return error.CommandFailed;
        },
        else => return error.CommandFailed,
    }
}

/// Sleep for `ms` milliseconds; restarts on `EINTR`.
pub fn sleepMs(ms: u64) void {
    var ts: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    while (std.c.nanosleep(&ts, &ts) == -1 and std.c.errno(-1) == .INTR) {}
}

pub const ExePathError = error{ExePathFailed};

/// Path of the running binary (`/proc/self/exe`).
pub fn selfExePath(allocator: std.mem.Allocator) ExePathError![]const u8 {
    var buf: [4096]u8 = undefined;
    const n = std.c.readlink("/proc/self/exe", &buf, buf.len);
    if (n <= 0) return error.ExePathFailed;
    return allocator.dupe(u8, buf[0..@intCast(n)]);
}

pub fn makePath(path: []const u8) !void {
    if (access(path)) return;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const rc = std.c.mkdir(buf[0..path.len :0], 0o755);
    if (rc == 0) return;
    const err: std.posix.E = @fromBackingInt(@intCast(std.c._errno().*));
    if (err == .EXIST) return;
    if (err == .SUCCESS) return error.Unexpected;
    return std.posix.unexpectedErrno(err);
}
