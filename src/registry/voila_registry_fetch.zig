const std = @import("std");
const voila_http = @import("./voila_http.zig");
const voila_store = @import("store").voila_store;
const voila_chunk_load = @import("store").voila_chunk_load;
const voila_fetch_stats = @import("./voila_fetch_stats.zig");
const hub = @import("./voila_registry_hub.zig");

const log = std.log.scoped(.registry);

fn trimRightSlash(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and s[end - 1] == '/') end -= 1;
    return s[0..end];
}

fn ensureOrigin(h: *hub.Hub, io: std.Io, allocator: std.mem.Allocator, cfg: hub.Config) !void {
    h.origin_mu.lockUncancelable(io);
    defer h.origin_mu.unlock(io);
    if (h.chunk_origin_loaded) return;
    h.chunk_origin_loaded = true;
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
            if (ep.len != 0) h.chunk_origin = try allocator.dupe(u8, ep);
        }
    }
}

pub fn fetchChunkRaw(
    reg_hub: *hub.Hub,
    io: std.Io,
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    chunk_hex: []const u8,
) ![]u8 {
    const cfg = reg_hub.getConfigCopy(allocator) orelse {
        log.err("chunk {s} is not in the local store and no registry is configured", .{chunk_hex});
        return error.RegistryUnset;
    };
    defer {
        allocator.free(cfg.base_url);
        allocator.free(cfg.token);
        allocator.free(cfg.org);
    }

    try ensureOrigin(reg_hub, io, allocator, cfg);

    const url = if (reg_hub.chunk_origin) |o|
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ o, chunk_hex })
    else
        try std.fmt.allocPrint(allocator, "{s}/v1/chunks/{s}", .{ cfg.base_url, chunk_hex });
    defer allocator.free(url);

    const resp = getChunkResponse(reg_hub, io, allocator, url) catch |e| {
        log.err("could not reach the registry for chunk {s} ({s}): {s}", .{ chunk_hex, url, @errorName(e) });
        return error.RegistryFetch;
    };
    const stored = resp.body;
    defer allocator.free(stored);
    if (resp.status != 200) {
        if (resp.status == 404) {
            log.err("chunk missing on registry: {s}", .{chunk_hex});
            return error.ChunkNotInRegistry;
        }
        log.err("registry returned {d} for chunk {s} ({s})", .{ resp.status, chunk_hex, url });
        return error.RegistryFetch;
    }

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

/// GET on a pooled keep-alive session. A pooled connection the server already closed
/// fails, so one transport error retries on a fresh session.
fn getChunkResponse(reg_hub: *hub.Hub, io: std.Io, allocator: std.mem.Allocator, url: []const u8) !voila_http.Response {
    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        const s = reg_hub.acquireSession(io, attempt > 0) orelse return voila_http.httpGetResponse(io, allocator, url, "");
        const resp = s.getResponse(allocator, url, "") catch |e| {
            reg_hub.releaseSession(s, false);
            if (attempt == 0 and e != error.Timeout) continue;
            return e;
        };
        reg_hub.releaseSession(s, true);
        return resp;
    }
}

/// Store fallback that fetches missing chunks from the configured registry.
pub fn fetcher(io: std.Io) voila_chunk_load.Fetcher {
    return fetcherForHub(hub.defaultHub(), io);
}

pub fn fetcherForHub(reg_hub: *hub.Hub, io: std.Io) voila_chunk_load.Fetcher {
    return .{
        .io = io,
        .hub = reg_hub,
        .fetchFn = fetchForStore,
    };
}

fn fetchForStore(f: voila_chunk_load.Fetcher, allocator: std.mem.Allocator, voila_root: []const u8, chunk_hex: []const u8) voila_chunk_load.FetchError![]u8 {
    const reg_hub: *hub.Hub = if (f.hub) |p| @ptrCast(@alignCast(p)) else hub.defaultHub();
    return fetchChunkRaw(reg_hub, f.io, allocator, voila_root, chunk_hex) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.FetchFailed,
    };
}

pub const Error = error{
    RegistryUnset,
    RegistryFetch,
    ChunkNotInRegistry,
    ChunkIntegrity,
};
