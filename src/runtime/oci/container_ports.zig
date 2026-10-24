//! Host port publishing via socat (rootless; shares host network namespace).
const std = @import("std");
const run_flags = @import("../run_flags.zig");
const posix_util = @import("../../sys/posix_util.zig");

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
};

pub fn start(io: std.Io, ports: []const run_flags.PortMap) ![]Forwarder {
    if (ports.len == 0) return &.{};
    var out: std.ArrayList(Forwarder) = .empty;
    for (ports) |p| {
        const spec = try std.fmt.allocPrint(std.heap.page_allocator, "TCP-LISTEN:{d},fork,reuseaddr TCP:127.0.0.1:{d}", .{
            p.host,
            p.container,
        });
        defer std.heap.page_allocator.free(spec);
        const socat = findSocat() orelse return error.SocatMissing;
        const child = try std.process.spawn(io, .{
            .argv = &[_][]const u8{ socat, spec },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        const pid: i32 = if (child.id) |id| @intCast(id) else -1;
        try out.append(std.heap.page_allocator, .{ .pid = pid });
        try io.sleep(std.Io.Duration.fromMilliseconds(50), .awake);
    }
    return try out.toOwnedSlice(std.heap.page_allocator);
}

pub fn stopAll(forwarders: []Forwarder) void {
    for (forwarders) |*f| f.stop();
}

fn findSocat() ?[]const u8 {
    const paths = [_][]const u8{ "/usr/bin/socat", "/bin/socat", "socat" };
    for (paths) |p| {
        if (posix_util.access(p)) return p;
    }
    return null;
}

pub const Error = error{SocatMissing};
