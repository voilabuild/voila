const std = @import("std");
const voila_http = @import("./voila_http.zig");
const voila_store = @import("../store/voila_store.zig");
const voila_chunk_load = @import("../store/voila_chunk_load.zig");
const voila_fetch_stats = @import("./voila_fetch_stats.zig");
const hub = @import("./voila_registry_hub.zig");

var g_chunk_origin: ?[]const u8 = null;
var g_origin_loaded: bool = false;

fn trimRightSlash(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and s[end - 1] == '/') end -= 1;
    return s[0..end];
}

fn ensureOrigin(io: std.Io, allocator: std.mem.Allocator, cfg: hub.Config) !void {
    if (g_origin_loaded) return;
    g_origin_loaded = true;
    const url = try std.fmt.allocPrint(allocator, "{s}/v1/registry/config", .{cfg.base_url});
    defer allocator.free(url);
    const body = voila_http.httpGet(io, allocator, url, cfg.token) catch return;
    defer allocator.free(body);
    const needle = "\"chunk_endpoint\"";
    if (std.mem.indexOf(u8, body, needle)) |i| {
        var rest = body[i + needle.len ..];
        if (std.mem.indexOf(u8, rest, "\"")) |q| rest = rest[q + 1 ..];
        if (std.mem.indexOf(u8, rest, "\"")) |end| {
            const ep = trimRightSlash(rest[0..end]);
            if (ep.len != 0) g_chunk_origin = try allocator.dupe(u8, ep);
        }
    }
}

pub fn fetchChunkRaw(
    io: std.Io,
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    chunk_hex: []const u8,
) ![]u8 {
    const cfg = hub.getConfigCopy(allocator) orelse return error.RegistryUnset;
    defer {
        allocator.free(cfg.base_url);
        allocator.free(cfg.token);
        allocator.free(cfg.org);
    }

    try ensureOrigin(io, allocator, cfg);

    const url = if (g_chunk_origin) |o|
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ o, chunk_hex })
    else
        try std.fmt.allocPrint(allocator, "{s}/v1/chunks/{s}", .{ cfg.base_url, chunk_hex });
    defer allocator.free(url);

    const stored = voila_http.httpGet(io, allocator, url, "") catch return error.RegistryFetch;
    defer allocator.free(stored);

    var raw: []u8 = stored;
    var owned_decompress = false;
    if (stored.len >= 4 and std.mem.eql(u8, stored[0..4], "\x28\xb5\x2f\xfd")) {
        raw = voila_store.decompressZstdPublic(allocator, stored) catch return error.RegistryFetch;
        owned_decompress = true;
    }

    voila_store.verifyChunkIdPublic(chunk_hex, raw) catch {
        if (owned_decompress) allocator.free(raw);
        return error.ChunkIntegrity;
    };

    try voila_store.putChunkRaw(allocator, voila_root, chunk_hex, raw);
    voila_fetch_stats.recordChunk(chunk_hex, raw.len);
    if (owned_decompress) allocator.free(raw);
    return voila_store.loadChunkRaw(allocator, voila_root, chunk_hex, voila_store.AlgoRaw);
}

/// Store fallback that fetches missing chunks from the configured registry.
pub fn fetcher(io: std.Io) voila_chunk_load.Fetcher {
    return .{ .io = io, .fetchFn = fetchForStore };
}

fn fetchForStore(io: std.Io, allocator: std.mem.Allocator, voila_root: []const u8, chunk_hex: []const u8) voila_chunk_load.FetchError![]u8 {
    return fetchChunkRaw(io, allocator, voila_root, chunk_hex) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.FetchFailed,
    };
}

pub const Error = error{
    RegistryUnset,
    RegistryFetch,
    ChunkIntegrity,
};
