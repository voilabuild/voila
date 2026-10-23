const std = @import("std");
const registry_ref = @import("./voila_registry_ref.zig");
const voila_registry_hub = @import("./voila_registry_hub.zig");
const voila_image_import = @import("./voila_image_import.zig");

/// Import a Docker Hub image into drift via native Zig ingest.
pub fn tryImportFromHub(
    io: std.Io,
    allocator: std.mem.Allocator,
    cfg: voila_registry_hub.Config,
    voila_root: []const u8,
    user_ref: []const u8,
) !void {
    if (cfg.org.len == 0) return error.NoOrg;
    if (!shouldImportFromDockerHub(user_ref, cfg.org)) return error.SkipDockerImport;
    const hub_ref = try registry_ref.normalizeUserRef(allocator, user_ref);
    defer allocator.free(hub_ref);
    const push_ref = try registry_ref.hubPushRef(allocator, hub_ref, cfg.org);
    defer allocator.free(push_ref);

    try voila_image_import.importImage(io, allocator, voila_root, cfg, hub_ref, push_ref);
}

fn shouldImportFromDockerHub(user_ref: []const u8, org: []const u8) bool {
    if (org.len == 0) return true;
    if (user_ref.len > org.len + 1 and std.mem.startsWith(u8, user_ref, org) and user_ref[org.len] == '/') return false;
    if (std.mem.startsWith(u8, user_ref, "test/")) return false;
    return true;
}

pub fn formatMissingImageHelp(
    allocator: std.mem.Allocator,
    user_ref: []const u8,
    org: []const u8,
) ![]const u8 {
    const hub_ref = try registry_ref.normalizeUserRef(allocator, user_ref);
    defer allocator.free(hub_ref);
    const push_ref = if (org.len != 0)
        try registry_ref.hubPushRef(allocator, hub_ref, org)
    else
        try allocator.dupe(u8, hub_ref);
    defer allocator.free(push_ref);
    return std.fmt.allocPrint(
        allocator,
        "image not found on the voila registry. Import from Docker Hub, then retry:\n  voila import {s}\n(set VOILA_ORG and VOILA_REGISTRY to push to your org after import)",
        .{hub_ref},
    );
}

pub const Error = error{
    NoOrg,
    SkipDockerImport,
};
