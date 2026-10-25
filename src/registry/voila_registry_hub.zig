const std = @import("std");
const HubMod = @import("Hub.zig");

pub const Config = HubMod.Config;
pub const Hub = HubMod.Hub;

var default_hub: Hub = .{};

/// Process-wide hub until call sites take an explicit `*Hub` or `app.Ctx`.
pub fn defaultHub() *Hub {
    return &default_hub;
}

pub var g_io: ?std.Io = null;

pub fn setIo(io: std.Io, allocator: std.mem.Allocator) void {
    default_hub.setIo(io, allocator);
    g_io = io;
}

pub fn configure(allocator: std.mem.Allocator, base_url: []const u8, token: []const u8, org: []const u8) !void {
    return default_hub.configure(allocator, base_url, token, org);
}

pub fn loadFromEnv(allocator: std.mem.Allocator) !void {
    return default_hub.loadFromEnv(allocator);
}

pub fn getConfigCopy(allocator: std.mem.Allocator) ?Config {
    return default_hub.getConfigCopy(allocator);
}

pub fn withConfig(f: *const fn (Config) void) void {
    default_hub.withConfig(f);
}
