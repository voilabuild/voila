//! Generated /etc/resolv.conf, /etc/hosts and /etc/hostname, bind-mounted into a container.
const std = @import("std");
const fs = @import("sys").fs;
const posix_util = @import("sys").posix_util;

/// pasta answers DNS on this address and forwards it to the host's resolver.
pub const pasta_dns = "169.254.1.1";

pub const files = [_][]const u8{ "resolv.conf", "hosts", "hostname" };

/// Writes the files into `dir` (created if needed).
pub fn write(allocator: std.mem.Allocator, dir: []const u8, hostname: []const u8, via_pasta: bool) !void {
    try fs.makePath(dir);
    const host_resolv = posix_util.readFileAlloc(allocator, "/etc/resolv.conf", 1 << 16) catch try allocator.dupe(u8, "");
    defer allocator.free(host_resolv);
    const resolv = try resolvConf(allocator, host_resolv, via_pasta);
    defer allocator.free(resolv);
    const hosts = try hostsFile(allocator, hostname);
    defer allocator.free(hosts);
    const name = try std.fmt.allocPrint(allocator, "{s}\n", .{hostname});
    defer allocator.free(name);
    const contents = [_][]const u8{ resolv, hosts, name };
    for (files, contents) |f, body| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, f });
        defer allocator.free(path);
        try fs.writeFile(path, body, 0o644);
    }
}

/// The host's resolv.conf with loopback nameservers (unreachable from the container's
/// netns) dropped. With pasta, its forwarder replaces all nameservers.
pub fn resolvConf(allocator: std.mem.Allocator, host: []const u8, via_pasta: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (via_pasta) try out.print(allocator, "nameserver {s}\n", .{pasta_dns});
    var lines = std.mem.splitScalar(u8, host, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        var cols = std.mem.tokenizeAny(u8, line, " \t");
        const key = cols.next() orelse continue;
        if (std.mem.eql(u8, key, "nameserver")) {
            if (via_pasta) continue;
            const addr = cols.next() orelse continue;
            if (std.mem.startsWith(u8, addr, "127.") or std.mem.eql(u8, addr, "::1")) continue;
        }
        try out.print(allocator, "{s}\n", .{line});
    }
    return out.toOwnedSlice(allocator);
}

pub fn hostsFile(allocator: std.mem.Allocator, hostname: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "127.0.0.1\tlocalhost\n::1\tlocalhost ip6-localhost ip6-loopback\n127.0.1.1\t{s}\n",
        .{hostname},
    );
}

test "resolvConf points at pasta and keeps search and options" {
    const a = std.testing.allocator;
    const host = "# managed\nnameserver 127.0.0.53\noptions edns0 trust-ad\nsearch example.net\n";
    const got = try resolvConf(a, host, true);
    defer a.free(got);
    try std.testing.expectEqualStrings("nameserver 169.254.1.1\noptions edns0 trust-ad\nsearch example.net\n", got);
}

test "resolvConf without pasta drops only loopback nameservers" {
    const a = std.testing.allocator;
    const got = try resolvConf(a, "nameserver 127.0.0.53\nnameserver 1.1.1.1\nnameserver ::1\n", false);
    defer a.free(got);
    try std.testing.expectEqualStrings("nameserver 1.1.1.1\n", got);
}
