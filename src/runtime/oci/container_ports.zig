//! Host port publishing via socat (rootless; shares host network namespace).
const std = @import("std");
const run_flags = @import("../run_flags.zig");
const posix_util = @import("sys").posix_util;

pub const Forwarder = struct {
    pid: i32,

    pub fn stop(self: *Forwarder) void {
        if (self.pid > 0) {
            _ = std.c.kill(self.pid, std.c.SIG.TERM);
            var status: i32 = 0;
            _ = std.c.waitpid(self.pid, &status, 0);
            self.pid = 0;
        }
    }

    fn alive(self: *Forwarder) bool {
        if (self.pid <= 0) return false;
        var status: i32 = 0;
        const r = std.c.waitpid(self.pid, &status, std.c.W.NOHANG);
        if (r == self.pid) {
            self.pid = 0;
            return false;
        }
        return true;
    }
};

pub fn start(io: std.Io, ports: []const run_flags.PortMap, log_path: []const u8) ![]Forwarder {
    if (ports.len == 0) return &.{};
    for (ports) |p| {
        if (p.host == p.container) return error.SamePort;
    }
    const socat = findSocat() orelse return error.SocatMissing;
    var out: std.ArrayList(Forwarder) = .empty;
    errdefer {
        for (out.items) |*f| f.stop();
        out.deinit(std.heap.page_allocator);
    }
    const log_file = openLog(log_path);
    defer {
        if (log_file) |f| _ = std.c.close(f.handle);
    }
    for (ports) |p| {
        const listen = try std.fmt.allocPrint(std.heap.page_allocator, "TCP-LISTEN:{d},fork,reuseaddr", .{p.host});
        defer std.heap.page_allocator.free(listen);
        const connect = try std.fmt.allocPrint(std.heap.page_allocator, "TCP:127.0.0.1:{d}", .{p.container});
        defer std.heap.page_allocator.free(connect);
        var fwd: Forwarder = .{ .pid = try spawnSocat(io, socat, listen, connect, log_file) };
        try io.sleep(std.Io.Duration.fromMilliseconds(50), .awake);
        if (!fwd.alive()) return error.ForwarderFailed;
        try out.append(std.heap.page_allocator, fwd);
    }
    return try out.toOwnedSlice(std.heap.page_allocator);
}

pub fn stopAll(forwarders: []Forwarder) void {
    for (forwarders) |*f| f.stop();
}

fn spawnSocat(io: std.Io, socat: []const u8, listen: []const u8, connect: []const u8, log_file: ?std.Io.File) !i32 {
    const argv = [_][]const u8{ socat, listen, connect };
    const child = if (log_file) |f|
        try std.process.spawn(io, .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .{ .file = f },
        })
    else
        try std.process.spawn(io, .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
    return if (child.id) |id| @intCast(id) else -1;
}

fn openLog(path: []const u8) ?std.Io.File {
    if (path.len == 0) return null;
    const path_z = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return null;
    defer std.heap.page_allocator.free(path_z);
    @memcpy(path_z, path);
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return null;
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

fn findSocat() ?[]const u8 {
    const paths = [_][]const u8{ "/usr/bin/socat", "/bin/socat", "socat" };
    for (paths) |p| {
        if (posix_util.access(p)) return p;
    }
    return null;
}

pub const Error = error{ SocatMissing, SamePort, ForwarderFailed };

test "same host and container port is rejected" {
    try std.testing.expectError(error.SamePort, start(std.testing.io, &.{.{ .host = 8080, .container = 8080 }}, ""));
}

test "empty port list starts nothing" {
    const fwd = try start(std.testing.io, &.{}, "");
    try std.testing.expectEqual(@as(usize, 0), fwd.len);
}
