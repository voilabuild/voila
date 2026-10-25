const std = @import("std");
const fs = @import("sys").fs;
const voila_registry_hub = @import("registry").voila_registry_hub;
const RegistryMod = @import("registry").Registry;
const voila_login_creds = @import("registry").voila_login_creds;
const voila_registry_creds = @import("registry").voila_registry_creds;
const voila_registry = @import("registry").voila_registry;
const voila_fetch_stats = @import("registry").voila_fetch_stats;
const voila_registry_fetch = @import("registry").voila_registry_fetch;
const StoreMod = @import("store").Store;
const voila_chunk_load = @import("store").voila_chunk_load;

/// CLI/runtime bundle: I/O, memory, registry hub, and store root (explicit context instead of globals).
pub const Ctx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    hub: *voila_registry_hub.Hub,
    registry: RegistryMod.Registry,
    store_root: ?[]const u8 = null,
    local_store: ?StoreMod.Local = null,

    pub fn init(io: std.Io, gpa: std.mem.Allocator, store_root: ?[]const u8) Ctx {
        const hub = voila_registry_hub.defaultHub();
        hub.setIo(io, gpa);
        return .{
            .io = io,
            .gpa = gpa,
            .hub = hub,
            .registry = RegistryMod.http(hub),
            .store_root = store_root,
            .local_store = if (store_root) |r| StoreMod.local(r) else null,
        };
    }

    /// Load login creds, per-store registry.creds, and VOILA_REGISTRY* env into the hub.
    pub fn prepareRegistry(self: *Ctx, voila_root: []const u8) !void {
        try fs.makePath(voila_root);
        try voila_login_creds.loadIntoHub(self.gpa);
        try voila_registry_creds.loadFromCredsFile(self.gpa, voila_root);
        try voila_registry.loadFromEnv(self.gpa);
    }

    pub fn store(self: *Ctx) ?StoreMod.Store {
        if (self.local_store) |*l| return l.store();
        return null;
    }

    pub fn chunkFetcher(self: *const Ctx) voila_chunk_load.Fetcher {
        return voila_registry_fetch.fetcherForHub(self.hub, self.io);
    }

    pub fn initFetchStats(self: *Ctx, stats_path: ?[]const u8) void {
        voila_fetch_stats.init(self.gpa, stats_path);
    }
};
