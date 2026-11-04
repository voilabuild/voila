//! Rootless networking: pasta for outbound, plus `-p` via pasta or a setns TCP proxy.
const std = @import("std");
const linux = std.os.linux;
const run_flags = @import("../run_flags.zig");
const posix_util = @import("sys").posix_util;
const ns = @import("sys").ns;
const container_etc = @import("container_etc.zig");

pub const Forwarder = struct {
    pid: i32,

    pub fn stop(self: *Forwarder) void {
        if (self.pid > 0) {
            _ = std.c.kill(self.pid, std.c.SIG.KILL);
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

/// Attach to `ns_pid`'s netns. Empty `ports` still starts pasta when present (outbound).
pub fn start(io: std.Io, ns_pid: i32, ports: []const run_flags.PortMap) ![]Forwarder {
    if (findPasta()) |pasta| return startPasta(io, pasta, ns_pid, ports);
    if (ports.len == 0) return &.{};
    return startProxy(io, ns_pid, ports);
}

pub fn stopAll(forwarders: []Forwarder) void {
    for (forwarders) |*f| f.stop();
}

pub fn findPasta() ?[]const u8 {
    const paths = [_][]const u8{ "/usr/bin/pasta", "/usr/sbin/pasta", "/bin/pasta" };
    for (paths) |p| {
        if (posix_util.executable(p)) return p;
    }
    return null;
}

pub fn tcpSpec(allocator: std.mem.Allocator, ports: []const run_flags.PortMap) ![]u8 {
    if (ports.len == 0) return allocator.dupe(u8, "none");
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (ports, 0..) |p, i| {
        if (i > 0) try buf.append(allocator, ',');
        if (p.host == p.container) {
            try buf.print(allocator, "{d}", .{p.host});
        } else {
            try buf.print(allocator, "{d}:{d}", .{ p.host, p.container });
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn startPasta(io: std.Io, pasta: []const u8, ns_pid: i32, ports: []const run_flags.PortMap) ![]Forwarder {
    const spec = try tcpSpec(std.heap.page_allocator, ports);
    defer std.heap.page_allocator.free(spec);
    const pid_s = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{ns_pid});
    defer std.heap.page_allocator.free(pid_s);
    const argv = [_][]const u8{
        pasta, "-f",   "-q",  "--config-net", "--dns-forward", container_etc.pasta_dns,
        "-u",  "none", "-T",  "none",         "-U",            "none",
        "-t",  spec,   pid_s,
    };
    var fwd: Forwarder = .{ .pid = try spawnArgv(io, &argv) };
    // --config-net adds the default route last; without one (host offline) give up after 1s.
    var waited: u32 = 0;
    while (waited < 1000 and fwd.alive() and !hasDefaultRoute(ns_pid)) : (waited += 5) {
        try io.sleep(std.Io.Duration.fromMilliseconds(5), .awake);
    }
    if (!fwd.alive()) {
        // Outbound is optional; published ports are not.
        if (ports.len == 0) return &.{};
        return error.ForwarderFailed;
    }
    const out = try std.heap.page_allocator.alloc(Forwarder, 1);
    out[0] = fwd;
    return out;
}

fn hasDefaultRoute(ns_pid: i32) bool {
    const a = std.heap.page_allocator;
    var path_buf: [64]u8 = undefined;
    inline for (.{ "route", "ipv6_route" }) |file| {
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/net/" ++ file, .{ns_pid}) catch return false;
        if (posix_util.readFileAlloc(a, path, 1 << 20)) |data| {
            defer a.free(data);
            if (routesHaveDefault(data, std.mem.eql(u8, file, "ipv6_route"))) return true;
        } else |_| {}
    }
    return false;
}

/// True when a `/proc/net/route` (or `ipv6_route`) table has a default route.
fn routesHaveDefault(table: []const u8, v6: bool) bool {
    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |line| {
        var cols = std.mem.tokenizeAny(u8, line, " \t");
        if (v6) {
            const dst = cols.next() orelse continue;
            const len = cols.next() orelse continue;
            if (std.mem.allEqual(u8, dst, '0') and std.mem.eql(u8, len, "00")) {
                var last: []const u8 = "";
                while (cols.next()) |c| last = c;
                if (!std.mem.eql(u8, last, "lo")) return true;
            }
        } else {
            _ = cols.next() orelse continue;
            const dst = cols.next() orelse continue;
            if (std.mem.eql(u8, dst, "00000000")) return true;
        }
    }
    return false;
}

fn startProxy(io: std.Io, ns_pid: i32, ports: []const run_flags.PortMap) ![]Forwarder {
    var out: std.ArrayList(Forwarder) = .empty;
    errdefer {
        for (out.items) |*f| f.stop();
        out.deinit(std.heap.page_allocator);
    }
    for (ports) |p| {
        var fwd: Forwarder = .{ .pid = try spawnProxy(p, ns_pid) };
        try io.sleep(std.Io.Duration.fromMilliseconds(50), .awake);
        if (!fwd.alive()) return error.ForwarderFailed;
        try out.append(std.heap.page_allocator, fwd);
    }
    return try out.toOwnedSlice(std.heap.page_allocator);
}

fn spawnProxy(port: run_flags.PortMap, ns_pid: i32) !i32 {
    const listen = try listenHost(port.host);
    errdefer _ = linux.close(listen);
    const pid = std.c.fork();
    if (pid < 0) return error.ForwarderFailed;
    if (pid != 0) {
        _ = linux.close(listen);
        return pid;
    }
    // The worker's no-op SIGTERM handler (SA_RESTART) is inherited across fork and would
    // make stop() wait forever (#153). Default actions, and die with the worker.
    for ([_]std.c.SIG{ .HUP, .INT, .QUIT, .TERM }) |sig| {
        var act: std.c.Sigaction = .{ .handler = .{ .handler = std.c.SIG.DFL }, .mask = std.mem.zeroes(std.c.sigset_t), .flags = 0 };
        _ = std.c.sigaction(sig, &act, null);
    }
    ns.setParentDeathSignal(.KILL) catch std.c._exit(1);
    enterNetns(ns_pid) catch std.c._exit(1);
    proxyAcceptLoop(listen, port.container);
    std.c._exit(0);
}

fn enterNetns(ns_pid: i32) !void {
    var user_buf: [64]u8 = undefined;
    var net_buf: [64]u8 = undefined;
    const user_path = std.fmt.bufPrintSentinel(&user_buf, "/proc/{d}/ns/user", .{ns_pid}, 0) catch return error.ForwarderFailed;
    const net_path = std.fmt.bufPrintSentinel(&net_buf, "/proc/{d}/ns/net", .{ns_pid}, 0) catch return error.ForwarderFailed;
    const user_fd = try ns.openRead(user_path);
    defer ns.close(user_fd);
    const net_fd = try ns.openRead(net_path);
    defer ns.close(net_fd);
    try ns.setns(user_fd, @intCast(ns.CLONE.NEWUSER));
    try ns.setns(net_fd, @intCast(ns.CLONE.NEWNET));
}

fn listenHost(port: u16) !linux.fd_t {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (nsFailed(rc)) return error.ForwarderFailed;
    const fd: linux.fd_t = @intCast(rc);
    const on: c_int = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&on).ptr, @sizeOf(c_int));
    var addr = std.mem.zeroes(linux.sockaddr.in);
    addr.family = linux.AF.INET;
    addr.port = std.mem.nativeToBig(u16, port);
    addr.addr = 0;
    if (nsFailed(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)))) {
        _ = linux.close(fd);
        return error.ForwarderFailed;
    }
    if (nsFailed(linux.listen(fd, 128))) {
        _ = linux.close(fd);
        return error.ForwarderFailed;
    }
    return fd;
}

fn proxyAcceptLoop(listen_fd: linux.fd_t, container_port: u16) void {
    while (true) {
        var addr: linux.sockaddr.in = undefined;
        var addrlen: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        const rc = linux.accept4(listen_fd, @ptrCast(&addr), &addrlen, linux.SOCK.CLOEXEC);
        if (nsFailed(rc)) {
            if (linux.errno(rc) == .INTR) continue;
            return;
        }
        const conn: linux.fd_t = @intCast(rc);
        const child = std.c.fork();
        if (child == 0) {
            _ = linux.close(listen_fd);
            pumpConnection(conn, container_port);
            std.c._exit(0);
        }
        _ = linux.close(conn);
        if (child > 0) {
            var status: i32 = 0;
            _ = std.c.waitpid(-1, &status, std.c.W.NOHANG);
        }
    }
}

fn pumpConnection(conn: linux.fd_t, container_port: u16) void {
    const dest = connectLoopback(container_port) catch {
        _ = linux.close(conn);
        return;
    };
    const copier = std.c.fork();
    if (copier == 0) {
        copyFd(conn, dest);
        std.c._exit(0);
    }
    copyFd(dest, conn);
    if (copier > 0) _ = std.c.kill(copier, std.c.SIG.TERM);
    _ = linux.close(conn);
    _ = linux.close(dest);
}

fn connectLoopback(port: u16) !linux.fd_t {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (nsFailed(rc)) return error.ForwarderFailed;
    const fd: linux.fd_t = @intCast(rc);
    var addr = std.mem.zeroes(linux.sockaddr.in);
    addr.family = linux.AF.INET;
    addr.port = std.mem.nativeToBig(u16, port);
    addr.addr = std.mem.nativeToBig(u32, 0x7f000001);
    if (nsFailed(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)))) {
        _ = linux.close(fd);
        return error.ForwarderFailed;
    }
    return fd;
}

fn copyFd(from: linux.fd_t, to: linux.fd_t) void {
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(from, &buf, buf.len);
        if (n == 0 or nsFailed(n)) break;
        _ = linux.write(to, buf[0..n].ptr, n);
    }
}

fn spawnArgv(io: std.Io, argv: []const []const u8) !i32 {
    const child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    return if (child.id) |id| @intCast(id) else -1;
}

fn nsFailed(rc: usize) bool {
    return linux.errno(rc) != .SUCCESS;
}

pub const Error = error{ForwarderFailed};

test "tcpSpec is none when no ports are published" {
    const a = std.testing.allocator;
    const s = try tcpSpec(a, &.{});
    defer a.free(s);
    try std.testing.expectEqualStrings("none", s);
}

test "tcpSpec maps host to container and keeps same-port as one number" {
    const a = std.testing.allocator;
    const s = try tcpSpec(a, &.{
        .{ .host = 8080, .container = 80 },
        .{ .host = 443, .container = 443 },
    });
    defer a.free(s);
    try std.testing.expectEqualStrings("8080:80,443", s);
}

test "routesHaveDefault finds v4 and v6 default routes" {
    const v4 = "Iface\tDestination\tGateway\nwlo1\t00000000\t0101A8C0\ndocker0\t000011AC\t00000000\n";
    try std.testing.expect(routesHaveDefault(v4, false));
    try std.testing.expect(!routesHaveDefault("Iface\tDestination\nlo\t0000007F\n", false));
    const v6 = "00000000000000000000000000000000 00 00000000000000000000000000000000 00 fe800000000000000000000000000001 00000400 00000000 00000000 00000003 eth0\n";
    try std.testing.expect(routesHaveDefault(v6, true));
    const v6lo = "00000000000000000000000000000000 00 00000000000000000000000000000000 00 00000000000000000000000000000000 ffffffff 00000001 00000000 00200200 lo\n";
    try std.testing.expect(!routesHaveDefault(v6lo, true));
}
