const std = @import("std");
const voila_manifest_proto = @import("codec").voila_manifest_proto;
const voila_store = @import("store").voila_store;
const voila_chunk_load = @import("store").voila_chunk_load;
const voila_registry_fetch = @import("./voila_registry_fetch.zig");
const voila_chunk_index = @import("store").voila_chunk_index;
const hex_util = @import("core").hex_util;

fn hexToId(hex: []const u8, out: *[32]u8) !void {
    if (hex.len != 64) return error.BadHex;
    _ = try std.fmt.hexToBytes(out, hex);
}

fn addHex(set: *std.StringHashMap(void), allocator: std.mem.Allocator, hex: []const u8) !void {
    if (hex.len != 64) return;
    const k = try allocator.dupe(u8, hex);
    const gop = try set.getOrPut(k);
    if (gop.found_existing) allocator.free(k);
}

fn walkManifestChunk(
    io: ?std.Io,
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    id: [32]u8,
    reachable: *std.StringHashMap(void),
    manifest_queue: *std.ArrayList([32]u8),
) !void {
    var hex_buf: [64]u8 = undefined;
    hex_util.encodeHexLower(&hex_buf, &id);
    const hex = hex_buf[0..];
    if (reachable.contains(hex)) return;
    try addHex(reachable, allocator, hex);

    const algo = voila_chunk_index.compAlgoForChunk(voila_root, &id) catch voila_store.AlgoRaw;
    const hex_owned = try allocator.dupe(u8, hex);
    defer allocator.free(hex_owned);
    const raw = if (io) |i|
        voila_chunk_load.loadChunkRaw(voila_registry_fetch.fetcher(i), allocator, voila_root, hex_owned, algo) catch return error.MissingChunk
    else
        voila_store.loadChunkRaw(allocator, voila_root, hex_owned, algo) catch return error.MissingChunk;
    defer allocator.free(raw);

    var m = voila_manifest_proto.decodeManifest(allocator, raw) catch return error.BadManifest;
    defer m.deinit();

    var fit = m.files.iterator();
    while (fit.next()) |e| {
        for (e.value_ptr.blocks) |b| {
            if (b.chunk_id.len != 32) continue;
            var block_hex: [64]u8 = undefined;
            hex_util.encodeHexLower(&block_hex, b.chunk_id);
            try addHex(reachable, allocator, &block_hex);
        }
    }
    var ext = m.external_subtrees.iterator();
    while (ext.next()) |e| {
        if (e.value_ptr.*.len != 32) continue;
        var child: [32]u8 = undefined;
        @memcpy(&child, e.value_ptr.*);
        try manifest_queue.append(allocator, child);
    }
}

pub fn reachableHexes(
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    manifest_json: []const u8,
) ![]const []const u8 {
    return reachableHexesIo(null, allocator, voila_root, manifest_json);
}

pub fn reachableHexesIo(
    io: ?std.Io,
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    manifest_json: []const u8,
) ![]const []const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.BadJson;
    const obj = root.object;

    var reachable: std.StringHashMap(void) = .init(allocator);
    defer reachable.deinit();
    errdefer {
        var kit = reachable.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
    }
    var manifest_queue: std.ArrayList([32]u8) = .empty;
    defer manifest_queue.deinit(allocator);

    // Manifests are only queued: walkManifestChunk records them and skips any already seen.
    if (obj.get("config_chunk")) |v| {
        if (v == .string) try addHex(&reachable, allocator, v.string);
    }
    if (obj.get("merged_root_manifest_chunk")) |v| {
        if (v == .string and v.string.len == 64) {
            var id: [32]u8 = undefined;
            try hexToId(v.string, &id);
            try manifest_queue.append(allocator, id);
        }
    }

    if (obj.get("provenance_layers")) |layers| {
        if (layers == .array) {
            for (layers.array.items) |layer| {
                if (layer != .object) continue;
                const rv = layer.object.get("root_manifest_chunk") orelse continue;
                if (rv != .string or rv.string.len != 64) continue;
                var id: [32]u8 = undefined;
                try hexToId(rv.string, &id);
                try manifest_queue.append(allocator, id);
            }
        }
    }

    while (manifest_queue.pop()) |id| {
        try walkManifestChunk(io, allocator, voila_root, id, &reachable, &manifest_queue);
    }

    // The returned slice takes ownership of the keys.
    const out = try allocator.alloc([]const u8, reachable.count());
    var it = reachable.keyIterator();
    var n: usize = 0;
    while (it.next()) |k| : (n += 1) out[n] = k.*;
    return out;
}

pub const Error = error{
    BadJson,
    BadHex,
    BadManifest,
    MissingChunk,
};

test "reachable walks the merged root manifest down to file chunks" {
    const fs = @import("sys").fs;
    const ingest = @import("store").ingest;
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try fs.makeTempDir(gpa, "voila-reachable-test");
    defer gpa.free(tmp);
    defer fs.removeTree(gpa, tmp) catch {};

    const store = try std.fmt.allocPrint(a, "{s}/store", .{tmp});
    try fs.makePath(store);
    const src = try std.fmt.allocPrint(a, "{s}/src", .{tmp});
    try fs.makePath(src);
    try fs.writeFile(try std.fmt.allocPrint(a, "{s}/a.txt", .{src}), "alpha", 0o644);
    try fs.writeFile(try std.fmt.allocPrint(a, "{s}/b.txt", .{src}), "bravo", 0o644);

    var w = try ingest.ingest_dir_walk.Walker.init(a, store, .{ .mode = .copy });
    defer w.deinit();
    try w.add(src, "");
    const tree = (try w.finish()).tree;
    const root = try ingest.ingest_manifest.buildAndStoreManifest(a, store, tree, false);

    const root_hex = std.fmt.bytesToHex(root, .lower);
    const json = try std.fmt.allocPrint(a, "{{\"merged_root_manifest_chunk\":\"{s}\"}}", .{&root_hex});
    const ids = try reachableHexes(gpa, store, json);
    defer {
        for (ids) |id| gpa.free(id);
        gpa.free(ids);
    }
    // The root manifest plus one data chunk per file.
    try std.testing.expectEqual(@as(usize, 3), ids.len);
}
