//! Configure registry hub from store creds + environment (no secrets logged).
const std = @import("std");
const voila_registry = @import("./voila_registry.zig");
const voila_registry_creds = @import("./voila_registry_creds.zig");
const voila_login_creds = @import("./voila_login_creds.zig");
const fs = @import("sys").fs;

pub fn prepare(io: std.Io, allocator: std.mem.Allocator, voila_root: []const u8) !void {
    try fs.makePath(voila_root);
    voila_registry.setIo(io, allocator);
    try voila_login_creds.loadIntoHub(allocator);
    try voila_registry_creds.loadFromCredsFile(allocator, voila_root);
    try voila_registry.loadFromEnv(allocator);
    const cfg = voila_registry.getConfigCopy(allocator) orelse return error.NoRegistry;
    allocator.free(cfg.base_url);
    allocator.free(cfg.token);
    allocator.free(cfg.org);
}

pub const Error = error{NoRegistry};
