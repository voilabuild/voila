const std = @import("std");
const posix_util = @import("posix_util.zig");
const registry_ref = @import("voila_registry_ref.zig");
const voila_registry_hub = @import("voila_registry_hub.zig");

/// Import a Docker Hub image into drift via the Go `voila-import` helper (or
/// `go run` against a local voila checkout when developing).
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

    if (try runGoCheckoutImport(allocator, cfg, hub_ref, push_ref, voila_root)) return;

    const helper = try findImportHelper(allocator) orelse return error.ImportHelperMissing;
    defer allocator.free(helper);

    try runImportHelper(io, allocator, cfg, helper, hub_ref, push_ref, voila_root);
}

fn shouldImportFromDockerHub(user_ref: []const u8, org: []const u8) bool {
    if (org.len == 0) return true;
    if (user_ref.len > org.len + 1 and std.mem.startsWith(u8, user_ref, org) and user_ref[org.len] == '/') return false;
    if (std.mem.startsWith(u8, user_ref, "test/")) return false;
    return true;
}

fn runImportHelper(
    _: std.Io,
    allocator: std.mem.Allocator,
    cfg: voila_registry_hub.Config,
    helper: []const u8,
    hub_ref: []const u8,
    push_ref: []const u8,
    root: []const u8,
) !void {
    const cmd = try std.fmt.allocPrint(
        allocator,
        "VOILA_REGISTRY={s} VOILA_REGISTRY_TOKEN='{s}' VOILA_ORG={s} {s} import {s} -push {s} -root {s} -registry {s}",
        .{ cfg.base_url, cfg.token, cfg.org, helper, hub_ref, push_ref, root, cfg.base_url },
    );
    defer allocator.free(cmd);
    const cmd_z = try allocator.allocSentinel(u8, cmd.len, 0);
    defer allocator.free(cmd_z);
    @memcpy(cmd_z, cmd);
    if (posix_util.shell(cmd_z) != 0) return error.ImportFailed;
}

fn runGoCheckoutImport(
    allocator: std.mem.Allocator,
    cfg: voila_registry_hub.Config,
    hub_ref: []const u8,
    push_ref: []const u8,
    root: []const u8,
) !bool {
    const repo_z = std.c.getenv("VOILA_IMPORT_REPO") orelse return false;
    const repo = std.mem.span(repo_z);
    const go_mod = try std.fmt.allocPrint(allocator, "{s}/go.mod", .{repo});
    defer allocator.free(go_mod);
    if (!posix_util.access(go_mod)) return false;

    const cmd = try std.fmt.allocPrint(
        allocator,
        "cd {s} && VOILA_REGISTRY={s} VOILA_REGISTRY_TOKEN={s} go run ./cmd/voila import {s} -push {s} -root {s} -registry {s}",
        .{ repo, cfg.base_url, cfg.token, hub_ref, push_ref, root, cfg.base_url },
    );
    defer allocator.free(cmd);
    const cmd_z = try allocator.allocSentinel(u8, cmd.len, 0);
    defer allocator.free(cmd_z);
    @memcpy(cmd_z, cmd);
    if (posix_util.shell(cmd_z) != 0) return error.ImportFailed;
    return true;
}

fn findImportHelper(allocator: std.mem.Allocator) !?[]const u8 {
    if (std.c.getenv("VOILA_IMPORT_HELPER")) |p| return try allocator.dupe(u8, std.mem.span(p));

    const exe = try selfExePath(allocator);
    defer allocator.free(exe);
    const dir = std.fs.path.dirname(exe) orelse return null;
    const sibling = try std.fmt.allocPrint(allocator, "{s}/voila-import", .{dir});
    if (posix_util.access(sibling)) return sibling;
    allocator.free(sibling);

    const home = std.c.getenv("HOME") orelse return null;
    const lib = try std.fmt.allocPrint(allocator, "{s}/.local/lib/voila/voila-import", .{std.mem.span(home)});
    if (posix_util.access(lib)) return lib;
    allocator.free(lib);

    return null;
}

fn selfExePath(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [4096]u8 = undefined;
    const n = std.c.readlink("/proc/self/exe", &buf, buf.len);
    if (n <= 0) return error.ExePathFailed;
    return allocator.dupe(u8, buf[0..@intCast(n)]);
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
        "image not found on the voila registry. Import from Docker Hub, then retry:\n  voila-import import {s} -push {s}\n(Install voila-import via install.sh, or set VOILA_IMPORT_HELPER to the Go voila binary.)",
        .{ hub_ref, push_ref },
    );
}

pub const Error = error{
    NoOrg,
    SkipDockerImport,
    ImportHelperMissing,
    ImportFailed,
    ExePathFailed,
};
