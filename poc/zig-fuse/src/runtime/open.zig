const std = @import("std");
const iface = @import("iface.zig");
const local = @import("local.zig");
const remote = @import("remote.zig");

pub const Runtime = iface.Runtime;
pub const Config = iface.Config;
pub const Kind = iface.Kind;
pub const RunSpec = iface.RunSpec;
pub const LogsOptions = iface.LogsOptions;
pub const KillSpec = iface.KillSpec;
pub const Error = iface.Error;

pub fn open(allocator: std.mem.Allocator, cfg: Config) !Runtime {
    return switch (cfg.kind) {
        .local => local.open(allocator, cfg.store_root),
        .remote => remote.open(allocator, cfg),
    };
}

pub fn kindFromEnv() Kind {
    if (std.c.getenv("VOILA_RUNTIME")) |v| {
        const s = std.mem.span(v);
        if (std.ascii.eqlIgnoreCase(s, "remote")) return .remote;
    }
    return .local;
}
