const std = @import("std");
const ocireg = @import("voila_ocireg.zig");

/// Docker-style refs without an explicit tag default to `:latest`.
pub fn normalizeUserRef(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyRef;
    if (std.mem.indexOfScalar(u8, trimmed, '@') != null) return allocator.dupe(u8, trimmed);
    if (std.mem.indexOfScalar(u8, trimmed, ':') != null) return allocator.dupe(u8, trimmed);
    return std.fmt.allocPrint(allocator, "{s}:latest", .{trimmed});
}

/// Drift refs are org-scoped (`org/name:tag`). Try the user ref, canonical
/// Docker Hub form, then org-prefixed short names and the shared `test/` catalog.
pub fn registryPullCandidates(
    allocator: std.mem.Allocator,
    user_ref: []const u8,
    org: []const u8,
) ![]const []const u8 {
    const normalized = try normalizeUserRef(allocator, user_ref);
    defer allocator.free(normalized);

    var list: std.ArrayList([]const u8) = .empty;
    try pushUnique(allocator, &list, normalized);

    if (try ocireg.canonical(allocator, normalized)) |canon| {
        defer allocator.free(canon);
        try pushUnique(allocator, &list, canon);
        if (org.len != 0) {
            if (try dockerShortFromCanonical(allocator, canon)) |short| {
                defer allocator.free(short);
                const org_ref = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ org, short });
                defer allocator.free(org_ref);
                try pushUnique(allocator, &list, org_ref);
            }
        }
        const catalog_ref = try catalogRef(allocator, canon);
        defer allocator.free(catalog_ref);
        try pushUnique(allocator, &list, catalog_ref);
    } else if (org.len != 0 and std.mem.indexOfScalar(u8, normalized, '/') == null) {
        const org_ref = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ org, normalized });
        defer allocator.free(org_ref);
        try pushUnique(allocator, &list, org_ref);
        const catalog_ref = try std.fmt.allocPrint(allocator, "test/{s}", .{normalized});
        defer allocator.free(catalog_ref);
        try pushUnique(allocator, &list, catalog_ref);
    } else if (std.mem.indexOfScalar(u8, normalized, '/') == null) {
        const catalog_ref = try std.fmt.allocPrint(allocator, "test/{s}", .{normalized});
        defer allocator.free(catalog_ref);
        try pushUnique(allocator, &list, catalog_ref);
    }

    return try list.toOwnedSlice(allocator);
}

fn catalogRef(allocator: std.mem.Allocator, canon: []const u8) ![]const u8 {
    if (try dockerShortFromCanonical(allocator, canon)) |short| {
        defer allocator.free(short);
        return std.fmt.allocPrint(allocator, "test/{s}", .{short});
    }
    return allocator.dupe(u8, canon);
}

/// `registry-1.docker.io/library/python:3.13` → `python:3.13`
fn dockerShortFromCanonical(allocator: std.mem.Allocator, canon: []const u8) !?[]const u8 {
    const prefix = "registry-1.docker.io/library/";
    if (!std.mem.startsWith(u8, canon, prefix)) return null;
    return try allocator.dupe(u8, canon[prefix.len..]);
}

fn pushUnique(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), ref: []const u8) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, ref)) return;
    }
    try list.append(allocator, try allocator.dupe(u8, ref));
}

/// `{org}/nginx:latest` for Docker-style `nginx` / `nginx:latest`.
pub fn hubPushRef(allocator: std.mem.Allocator, hub_ref: []const u8, org: []const u8) ![]const u8 {
    if (org.len == 0) return allocator.dupe(u8, hub_ref);
    if (std.mem.indexOfScalar(u8, hub_ref, '/')) |slash| {
        const prefix = hub_ref[0..slash];
        if (std.mem.eql(u8, prefix, org)) return allocator.dupe(u8, hub_ref);
        if (std.mem.indexOfScalar(u8, prefix, '.') != null or std.mem.eql(u8, prefix, "localhost")) {
            if (try dockerShortFromCanonical(allocator, hub_ref)) |short| {
                defer allocator.free(short);
                return std.fmt.allocPrint(allocator, "{s}/{s}", .{ org, short });
            }
        }
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ org, hub_ref });
}

pub const Error = error{EmptyRef};
