//! Chunk garbage collection after `voila rmi`: mark from images and the build cache, sweep the rest.
const std = @import("std");
const sqlite = @import("sqlite_c");
const fs = @import("sys").fs;
const voila_resolve = @import("./voila_resolve.zig");
const voila_manifest_cache = @import("./voila_manifest_cache.zig");
const voila_reachable = @import("./voila_reachable.zig");

/// Chunks written this recently are kept: an import or build may not have recorded its image yet.
pub const default_grace_ns: u64 = 10 * std.time.ns_per_min;

pub const Result = struct { chunks: u64 = 0, bytes: u64 = 0 };

pub const Error = error{UnknownImageRoots};

pub fn collect(allocator: std.mem.Allocator, voila_root: []const u8, now_ns: u64, grace_ns: u64) !Result {
    var marked: std.StringHashMap(void) = .init(allocator);
    defer {
        var it = marked.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        marked.deinit();
    }
    try mark(allocator, voila_root, &marked);
    return sweep(allocator, voila_root, &marked, now_ns, grace_ns);
}

fn mark(allocator: std.mem.Allocator, voila_root: []const u8, marked: *std.StringHashMap(void)) !void {
    var roots: std.ArrayList([32]u8) = .empty;
    defer roots.deinit(allocator);
    const images = voila_resolve.listImagesInStore(allocator, voila_root) catch &.{};
    defer {
        for (images) |r| {
            allocator.free(r.ref);
            allocator.free(r.image_digest);
            allocator.free(r.merged_root_manifest);
        }
        allocator.free(images);
    }
    for (images) |img| {
        // Without the manifest we cannot see the config and layer chunks: keep everything.
        const body = voila_manifest_cache.load(allocator, voila_root, img.ref) catch return error.UnknownImageRoots;
        defer allocator.free(body);
        try voila_reachable.manifestRoots(allocator, body, &roots, marked);
        if (img.merged_root_manifest.len == 32) try roots.append(allocator, img.merged_root_manifest[0..32].*);
    }
    try buildCacheRoots(allocator, voila_root, &roots);
    try voila_reachable.markLocal(allocator, voila_root, roots.items, marked);
}

/// Each `build-cache/<xx>/<key>` entry is "<root-hex> <layer-hex> <whiteouts>".
fn buildCacheRoots(allocator: std.mem.Allocator, voila_root: []const u8, roots: *std.ArrayList([32]u8)) !void {
    const dir = try std.fmt.allocPrint(allocator, "{s}/build-cache", .{voila_root});
    defer allocator.free(dir);
    const shards = fs.listDir(allocator, dir) catch return;
    defer fs.freeNames(allocator, shards);
    for (shards) |shard| {
        const sub = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, shard });
        defer allocator.free(sub);
        const entries = fs.listDir(allocator, sub) catch continue;
        defer fs.freeNames(allocator, entries);
        for (entries) |e| {
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sub, e });
            defer allocator.free(path);
            var buf: [256]u8 = undefined;
            const f = fs.File.openRead(path) catch continue;
            defer f.close();
            const n = f.readFull(&buf) catch continue;
            var it = std.mem.tokenizeAny(u8, buf[0..n], " \n");
            for (0..2) |_| {
                const hex = it.next() orelse break;
                var id: [32]u8 = undefined;
                _ = std.fmt.hexToBytes(&id, hex) catch break;
                try roots.append(allocator, id);
            }
        }
    }
}

fn sweep(allocator: std.mem.Allocator, voila_root: []const u8, marked: *const std.StringHashMap(void), now_ns: u64, grace_ns: u64) !Result {
    var res: Result = .{};
    var removed: std.ArrayList([32]u8) = .empty;
    defer removed.deinit(allocator);
    const top = try std.fmt.allocPrint(allocator, "{s}/chunks", .{voila_root});
    defer allocator.free(top);
    const l1 = fs.listDir(allocator, top) catch return res;
    defer fs.freeNames(allocator, l1);
    for (l1) |a| {
        const d1 = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ top, a });
        defer allocator.free(d1);
        const l2 = fs.listDir(allocator, d1) catch continue;
        defer fs.freeNames(allocator, l2);
        for (l2) |b| {
            const d2 = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ d1, b });
            defer allocator.free(d2);
            const files = fs.listDir(allocator, d2) catch continue;
            defer fs.freeNames(allocator, files);
            for (files) |hex| {
                if (hex.len != 64 or marked.contains(hex)) continue;
                var id: [32]u8 = undefined;
                _ = std.fmt.hexToBytes(&id, hex) catch continue; // not a chunk blob (e.g. a temp file)
                const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ d2, hex });
                defer allocator.free(path);
                const st = fs.lstat(path) catch continue;
                if (st.kind != .file or st.mtime_ns + grace_ns > now_ns) continue;
                const path_z = try allocator.dupeSentinel(u8, path, 0);
                defer allocator.free(path_z);
                if (std.c.unlink(path_z) != 0) continue;
                res.chunks += 1;
                res.bytes += st.size;
                try removed.append(allocator, id);
            }
        }
    }
    dropIndexRows(allocator, voila_root, removed.items);
    return res;
}

/// A stale row would make a re-fetched chunk decode with the old compression.
fn dropIndexRows(allocator: std.mem.Allocator, voila_root: []const u8, ids: []const [32]u8) void {
    if (ids.len == 0) return;
    const db_path = std.fmt.allocPrintSentinel(allocator, "{s}/index.db", .{voila_root}, 0) catch return;
    defer allocator.free(db_path);
    var db: ?*sqlite.sqlite3 = null;
    if (sqlite.sqlite3_open(db_path, &db) != sqlite.SQLITE_OK) {
        if (db) |d| _ = sqlite.sqlite3_close(d);
        return;
    }
    defer _ = sqlite.sqlite3_close(db);
    _ = sqlite.sqlite3_busy_timeout(db, 5000);
    var stmt: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(db, "DELETE FROM chunks WHERE id = ?", -1, &stmt, null) != sqlite.SQLITE_OK) return;
    defer _ = sqlite.sqlite3_finalize(stmt);
    _ = sqlite.sqlite3_exec(db, "BEGIN", null, null, null);
    for (ids) |*id| {
        _ = sqlite.sqlite3_reset(stmt);
        _ = sqlite.sqlite3_bind_blob(stmt, 1, id, 32, sqlite.SQLITE_STATIC);
        _ = sqlite.sqlite3_step(stmt);
    }
    _ = sqlite.sqlite3_exec(db, "COMMIT", null, null, null);
}

test "collect keeps chunks of remaining images and drops the rest" {
    const ingest = @import("store").ingest;
    const voila_image_pull = @import("./voila_image_pull.zig");
    const voila_manifest_json = @import("codec").voila_manifest_json;
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try fs.makeTempDir(gpa, "voila-gc-test");
    defer gpa.free(tmp);
    defer fs.removeTree(gpa, tmp) catch {}; // leftover temp dir is fine
    const store = try std.fmt.allocPrint(a, "{s}/store", .{tmp});
    try fs.makePath(store);

    var roots: [2][32]u8 = undefined;
    for (&roots, [_][]const u8{ "keep", "drop" }) |*r, name| {
        const src = try std.fmt.allocPrint(a, "{s}/{s}", .{ tmp, name });
        try fs.makePath(src);
        try fs.writeFile(try std.fmt.allocPrint(a, "{s}/f.txt", .{src}), name, 0o644);
        var w = try ingest.ingest_dir_walk.Walker.init(a, store, .{ .mode = .copy });
        defer w.deinit();
        try w.add(src, "");
        r.* = try ingest.ingest_manifest.buildAndStoreManifest(a, store, (try w.finish()).tree, false);
    }
    const hex = std.fmt.bytesToHex(roots[0], .lower);
    const json = try std.fmt.allocPrint(a, "{{\"image_ref\":\"acme/keep:1\",\"merged_root_manifest_chunk\":\"{s}\"}}", .{&hex});
    try voila_image_pull.persistManifest(a, store, "acme/keep:1", json, try voila_manifest_json.parse(a, json));
    try voila_manifest_cache.save(a, store, "acme/keep:1", json);

    const now: u64 = std.math.maxInt(u64) / 2;
    const res = try collect(gpa, store, now, 0);
    // "drop": its root manifest and its one data chunk.
    try std.testing.expectEqual(@as(u64, 2), res.chunks);
    var left: std.StringHashMap(void) = .init(gpa);
    defer {
        var it = left.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        left.deinit();
    }
    try voila_reachable.markLocal(gpa, store, &.{roots[0]}, &left);
    try std.testing.expectEqual(@as(u32, 2), left.count());
    // Nothing else is reclaimable now.
    try std.testing.expectEqual(@as(u64, 0), (try collect(gpa, store, now, 0)).chunks);
}
