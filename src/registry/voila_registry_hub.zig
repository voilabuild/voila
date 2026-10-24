const std = @import("std");
const voila_paths = @import("sys").voila_paths;

pub const Config = struct {
    base_url: []const u8,
    token: []const u8,
    org: []const u8,
};

var g_mu: std.Io.Mutex = .init;

fn lockHub() void {
    if (g_io) |io| g_mu.lockUncancelable(io);
}
fn unlockHub() void {
    if (g_io) |io| g_mu.unlock(io);
}
var g_cfg: ?Config = null;
pub var g_io: ?std.Io = null;
var g_allocator: ?std.mem.Allocator = null;

pub fn setIo(io: std.Io, allocator: std.mem.Allocator) void {
    g_io = io;
    g_allocator = allocator;
}

pub fn configure(allocator: std.mem.Allocator, base_url: []const u8, token: []const u8, org: []const u8) !void {
    lockHub();
    defer unlockHub();
    if (g_cfg) |*c| {
        allocator.free(c.base_url);
        allocator.free(c.token);
        allocator.free(c.org);
        g_cfg = null;
    }
    if (base_url.len == 0) return;
    const normalized = try voila_paths.normalizeRegistryUrl(allocator, base_url);
    defer allocator.free(normalized);
    var base = normalized;
    while (base.len > 0 and base[base.len - 1] == '/') base = base[0 .. base.len - 1];
    base = try allocator.dupe(u8, base);
    g_cfg = .{
        .base_url = base,
        .token = try allocator.dupe(u8, token),
        .org = try allocator.dupe(u8, org),
    };
}

pub fn loadFromEnv(allocator: std.mem.Allocator) !void {
    const url_z = std.c.getenv("VOILA_REGISTRY") orelse return;
    const url_slice: []const u8 = std.mem.span(url_z);
    const normalized = try voila_paths.normalizeRegistryUrl(allocator, url_slice);
    defer allocator.free(normalized);
    const token_slice: []const u8 = if (std.c.getenv("VOILA_REGISTRY_TOKEN")) |t| std.mem.span(t) else "";
    const org_slice: []const u8 = if (std.c.getenv("VOILA_ORG")) |o| std.mem.span(o) else "";
    try configure(allocator, normalized, token_slice, org_slice);
}

pub fn getConfigCopy(allocator: std.mem.Allocator) ?Config {
    lockHub();
    defer unlockHub();
    const c = g_cfg orelse return null;
    return .{
        .base_url = allocator.dupe(u8, c.base_url) catch return null,
        .token = allocator.dupe(u8, c.token) catch return null,
        .org = allocator.dupe(u8, c.org) catch return null,
    };
}

pub fn withConfig(f: *const fn (Config) void) void {
    lockHub();
    defer unlockHub();
    if (g_cfg) |c| f(c);
}
