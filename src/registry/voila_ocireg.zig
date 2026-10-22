const std = @import("std");

pub const default_host = "registry-1.docker.io";
const docker_hub_alias = "docker.io";

pub const Ref = struct {
    host: []const u8,
    repo: []const u8,
    tag: []const u8,
    digest: []const u8,
    is_digest: bool,
};

fn isHexDigit(b: u8) bool {
    return (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f') or (b >= 'A' and b <= 'F');
}

fn normalizeHost(h: []const u8) []const u8 {
    if (std.mem.eql(u8, h, docker_hub_alias)) return default_host;
    return h;
}

fn libraryIfHub(host: []const u8, repo: []const u8) []const u8 {
    if (std.mem.eql(u8, host, default_host) and std.mem.indexOfScalar(u8, repo, '/') == null)
        return "library/";
    return repo;
}

fn splitName(name: []const u8, allocator: std.mem.Allocator) !struct { host: []const u8, repo: []const u8 } {
    var n = name;
    if (std.mem.startsWith(u8, n, "/")) n = n[1..];
    if (std.mem.indexOfScalar(u8, n, '/')) |i| {
        const first = n[0..i];
        const rest = n[i + 1 ..];
        if (std.mem.indexOfScalar(u8, first, '.') != null or std.mem.indexOfScalar(u8, first, ':') != null or std.mem.eql(u8, first, "localhost")) {
            const h = normalizeHost(first);
            const r = if (std.mem.eql(u8, h, default_host) and std.mem.indexOfScalar(u8, rest, '/') == null)
                try std.fmt.allocPrint(allocator, "library/{s}", .{rest})
            else
                try allocator.dupe(u8, rest);
            return .{ .host = try allocator.dupe(u8, h), .repo = r };
        }
        const r = try allocator.dupe(u8, n);
        return .{ .host = try allocator.dupe(u8, default_host), .repo = r };
    }
    const r = try std.fmt.allocPrint(allocator, "library/{s}", .{n});
    return .{ .host = try allocator.dupe(u8, default_host), .repo = r };
}

pub fn parseRef(allocator: std.mem.Allocator, s: []const u8) !Ref {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyRef;

    if (std.mem.indexOfScalar(u8, trimmed, '@')) |i| {
        const name = trimmed[0..i];
        const digest = std.mem.trim(u8, trimmed[i + 1 ..], " \t");
        if (!std.mem.startsWith(u8, digest, "sha256:") or digest.len != "sha256:".len + 64)
            return error.BadDigest;
        for (digest["sha256:".len..]) |c| if (!isHexDigit(c)) return error.BadDigest;
        const parts = try splitName(name, allocator);
        return .{
            .host = parts.host,
            .repo = parts.repo,
            .tag = "",
            .digest = try allocator.dupe(u8, digest),
            .is_digest = true,
        };
    }

    var host_part: []const u8 = "";
    var rest: []const u8 = trimmed;
    if (std.mem.indexOfScalar(u8, trimmed, '/')) |i| {
        host_part = trimmed[0..i];
        rest = trimmed[i + 1 ..];
    }
    const has_host_port = std.mem.indexOfScalar(u8, host_part, ':') != null;
    var tag: []const u8 = "";
    if (has_host_port) {
        if (std.mem.indexOfScalar(u8, rest, ':')) |j| {
            tag = rest[j + 1 ..];
            rest = rest[0..j];
        }
        rest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ host_part, rest });
        host_part = "";
    } else if (std.mem.indexOfScalar(u8, rest, ':')) |j| {
        tag = rest[j + 1 ..];
        rest = rest[0..j];
    }
    if (tag.len == 0) tag = "latest";

    var name = rest;
    if (host_part.len != 0) name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ host_part, rest });
    const parts = try splitName(name, allocator);
    return .{
        .host = parts.host,
        .repo = parts.repo,
        .tag = try allocator.dupe(u8, tag),
        .digest = "",
        .is_digest = false,
    };
}

pub fn refString(allocator: std.mem.Allocator, r: Ref) ![]const u8 {
    if (r.is_digest) return std.fmt.allocPrint(allocator, "{s}/{s}@{s}", .{ r.host, r.repo, r.digest });
    return std.fmt.allocPrint(allocator, "{s}/{s}:{s}", .{ r.host, r.repo, r.tag });
}

pub fn canonical(allocator: std.mem.Allocator, s: []const u8) !?[]const u8 {
    const r = parseRef(allocator, s) catch return null;
    defer {
        allocator.free(r.host);
        allocator.free(r.repo);
        if (r.tag.len != 0) allocator.free(r.tag);
        if (r.digest.len != 0) allocator.free(r.digest);
    }
    return try refString(allocator, r);
}

pub const Error = error{ EmptyRef, BadDigest };
