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
    if (!shouldImportFromDockerHub(user_ref, cfg.org)) return error.SkipDockerImport;
    const hub_ref = try registry_ref.normalizeUserRef(allocator, user_ref);
    defer allocator.free(hub_ref);
    try voila_image_import.importImage(io, allocator, voila_root, cfg, hub_ref, hub_ref, .{});
}

fn shouldImportFromDockerHub(user_ref: []const u8, org: []const u8) bool {
    if (org.len == 0) return true;
    if (user_ref.len > org.len + 1 and std.mem.startsWith(u8, user_ref, org) and user_ref[org.len] == '/') return false;
    if (std.mem.startsWith(u8, user_ref, "test/")) return false;
    return true;
}

/// Images are private to their org by default, so a 404 can also mean "not yours".
pub fn formatMissingImageHelp(
    allocator: std.mem.Allocator,
    user_ref: []const u8,
    logged_in: bool,
) ![]const u8 {
    const hub_ref = try registry_ref.normalizeUserRef(allocator, user_ref);
    defer allocator.free(hub_ref);
    const private_hint: []const u8 = if (logged_in)
        "or it is private to an org you are not a member of"
    else
        "or it is private (run `voila login` to pull your org's images)";
    return std.fmt.allocPrint(
        allocator,
        "image \"{s}\" not found on the voila registry, {s}.\nIf it is a Docker Hub image, import it instead: voila import {s}",
        .{ user_ref, private_hint, hub_ref },
    );
}

test "formatMissingImageHelp mentions login only when logged out" {
    const a = std.testing.allocator;
    const out = try formatMissingImageHelp(a, "acme/app:1", false);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "voila login") != null);
    const in = try formatMissingImageHelp(a, "acme/app:1", true);
    defer a.free(in);
    try std.testing.expect(std.mem.indexOf(u8, in, "voila login") == null);
}

pub const Error = error{
    NoOrg,
    SkipDockerImport,
};
