const std = @import("std");
const voila_http = @import("./voila_http.zig");
const voila_registry_hub = @import("./voila_registry_hub.zig");
const voila_resolve = @import("./voila_resolve.zig");
const voila_manifest_cache = @import("./voila_manifest_cache.zig");
const voila_reachable = @import("./voila_reachable.zig");
const voila_store = @import("../store/voila_store.zig");
const voila_manifest_json = @import("../codec/voila_manifest_json.zig");

const missing_batch = 16384;
const zstd_magic: [4]u8 = .{ 0x28, 0xb5, 0x2f, 0xfd };

pub fn pushImage(
    io: std.Io,
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    cfg: voila_registry_hub.Config,
    query: []const u8,
) !void {
    const rec = try voila_resolve.resolveImage(allocator, voila_root, query);
    defer {
        allocator.free(rec.ref);
        allocator.free(rec.image_digest);
        allocator.free(rec.merged_root_manifest);
    }

    const manifest_body = voila_manifest_cache.load(allocator, voila_root, rec.ref) catch blk: {
        const escaped = try voila_http.queryEscape(allocator, rec.ref);
        defer allocator.free(escaped);
        const url = try std.fmt.allocPrint(allocator, "{s}/v1/images/{s}", .{ cfg.base_url, escaped });
        defer allocator.free(url);
        break :blk try voila_http.httpGet(io, allocator, url, cfg.token);
    };
    defer allocator.free(manifest_body);

    const man = try voila_manifest_json.parse(allocator, manifest_body);
    defer {
        allocator.free(man.image_ref);
        allocator.free(man.image_digest);
        allocator.free(man.merged_root);
    }

    const ids = try voila_reachable.reachableHexes(allocator, voila_root, manifest_body);
    defer {
        for (ids) |id| allocator.free(id);
        allocator.free(ids);
    }

    const missing = try missingChunks(io, allocator, cfg, ids);
    defer {
        for (missing) |id| allocator.free(id);
        allocator.free(missing);
    }

    var uploaded: usize = 0;
    var upload_bytes: u64 = 0;
    for (missing) |chunk_hex| {
        const wire = try chunkWireBody(allocator, voila_root, chunk_hex);
        defer allocator.free(wire);
        const url = try std.fmt.allocPrint(allocator, "{s}/v1/chunks/{s}", .{ cfg.base_url, chunk_hex });
        defer allocator.free(url);
        const code = voila_http.httpPut(io, allocator, url, cfg.token, wire, "application/octet-stream", "zstd") catch return error.ChunkPut;
        if (code != 200 and code != 201) return error.ChunkPut;
        uploaded += 1;
        const cid = chunkIdFromHex(chunk_hex);
        const algo = @import("../store/voila_chunk_index.zig").compAlgoForChunk(voila_root, &cid) catch voila_store.AlgoRaw;
        const raw = voila_store.loadChunkRaw(allocator, voila_root, chunk_hex, algo) catch return error.MissingChunk;
        defer allocator.free(raw);
        upload_bytes += raw.len;
    }

    const escaped_put = try voila_http.queryEscape(allocator, man.image_ref);
    defer allocator.free(escaped_put);
    const put_url = try std.fmt.allocPrint(allocator, "{s}/v1/images/{s}", .{ cfg.base_url, escaped_put });
    defer allocator.free(put_url);
    const put_code = voila_http.httpPut(io, allocator, put_url, cfg.token, manifest_body, "application/json", null) catch return error.ManifestPut;
    if (put_code != 200 and put_code != 201) return error.ManifestPut;

    const already = ids.len - missing.len;
    std.debug.print(
        "pushed {s}: {d} chunks uploaded, {d} already present, {d} MiB\n",
        .{ man.image_ref, uploaded, already, upload_bytes / (1024 * 1024) },
    );
}

fn chunkIdFromHex(hex: []const u8) [32]u8 {
    var id: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&id, hex) catch return @splat(0);
    return id;
}

fn chunkWireBody(allocator: std.mem.Allocator, voila_root: []const u8, chunk_hex: []const u8) ![]u8 {
    const stored = try voila_store.loadStoredBytes(allocator, voila_root, chunk_hex);
    defer allocator.free(stored);
    if (stored.len >= 4 and std.mem.eql(u8, stored[0..4], &zstd_magic)) {
        return allocator.dupe(u8, stored);
    }
    const cid = chunkIdFromHex(chunk_hex);
    const algo = @import("../store/voila_chunk_index.zig").compAlgoForChunk(voila_root, &cid) catch voila_store.AlgoRaw;
    const raw = voila_store.loadChunkRaw(allocator, voila_root, chunk_hex, algo) catch return error.MissingChunk;
    defer allocator.free(raw);
    return voila_store.compressZstdPublic(allocator, raw);
}

fn missingChunks(
    io: std.Io,
    allocator: std.mem.Allocator,
    cfg: voila_registry_hub.Config,
    ids: []const []const u8,
) ![]const []const u8 {
    var missing: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < ids.len) {
        const end = @min(i + missing_batch, ids.len);
        const batch = ids[i..end];
        const body = try encodeMissingRequest(allocator, batch);
        defer allocator.free(body);
        const url = try std.fmt.allocPrint(allocator, "{s}/v1/chunks/missing", .{cfg.base_url});
        defer allocator.free(url);
        const resp = voila_http.httpPostJson(io, allocator, url, cfg.token, body) catch return error.MissingNegotiation;
        defer allocator.free(resp);
        try parseMissingResponse(allocator, resp, &missing);
        i = end;
    }
    return missing.toOwnedSlice(allocator);
}

fn encodeMissingRequest(allocator: std.mem.Allocator, ids: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "{\"ids\":[");
    for (ids, 0..) |id, n| {
        if (n > 0) try out.append(allocator, ',');
        try out.append(allocator, '"');
        try out.appendSlice(allocator, id);
        try out.append(allocator, '"');
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn parseMissingResponse(allocator: std.mem.Allocator, json: []const u8, out: *std.ArrayList([]const u8)) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const missing = parsed.value.object.get("missing") orelse return;
    if (missing != .array) return;
    for (missing.array.items) |item| {
        if (item != .string) continue;
        try out.append(allocator, try allocator.dupe(u8, item.string));
    }
}

pub const Error = error{
    ChunkPut,
    ManifestPut,
    MissingNegotiation,
    MissingChunk,
};
