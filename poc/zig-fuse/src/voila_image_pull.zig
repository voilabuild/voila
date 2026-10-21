const std = @import("std");
const sqlite = @import("sqlite_c");
const voila_http = @import("voila_http.zig");
const voila_manifest_json = @import("voila_manifest_json.zig");
const voila_refkey = @import("voila_refkey.zig");
const registry_ref = @import("voila_registry_ref.zig");
const voila_registry_hub = @import("voila_registry_hub.zig");
const voila_registry = @import("voila_registry.zig");
const ocireg = @import("voila_ocireg.zig");
const posix_util = @import("posix_util.zig");

pub fn pullManifestOnce(
    io: std.Io,
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    cfg: voila_registry_hub.Config,
    ref: []const u8,
) !voila_manifest_json.Manifest {
    const escaped = try voila_http.queryEscape(allocator, ref);
    defer allocator.free(escaped);
    const url = try std.fmt.allocPrint(allocator, "{s}/v1/images/{s}", .{ cfg.base_url, escaped });
    defer allocator.free(url);
    const body = try voila_http.httpGet(io, allocator, url, cfg.token);
    defer allocator.free(body);
    const man = try voila_manifest_json.parse(allocator, body);
    try persistManifest(allocator, voila_root, ref, man);
    return man;
}

pub fn pullManifest(
    io: std.Io,
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    cfg: voila_registry_hub.Config,
    ref: []const u8,
) !voila_manifest_json.Manifest {
    const candidates = try registry_ref.registryPullCandidates(allocator, ref, cfg.org);
    defer {
        for (candidates) |c| allocator.free(c);
        allocator.free(candidates);
    }
    var last_err: ?anyerror = null;
    for (candidates) |candidate| {
        const man = pullManifestOnce(io, allocator, voila_root, cfg, candidate) catch |e| {
            last_err = e;
            continue;
        };
        return man;
    }
    if (last_err) |e| return e;
    return error.HttpStatus;
}

pub fn autoPull(
    io: std.Io,
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    query: []const u8,
) !voila_manifest_json.Manifest {
    const cfg = voila_registry.getConfigCopy(allocator) orelse return error.NoRegistry;
    defer {
        allocator.free(cfg.base_url);
        allocator.free(cfg.token);
        allocator.free(cfg.org);
    }
    if (query.len == 0) return error.Skip;
    if (!voila_refkey.looksLikeRef(query)) return error.Skip;
    return pullManifest(io, allocator, voila_root, cfg, query);
}

fn persistManifest(
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    ref: []const u8,
    man: voila_manifest_json.Manifest,
) !void {
    var store_ref = man.image_ref;
    if (store_ref.len == 0) store_ref = ref;

    try upsertImagesDb(allocator, voila_root, store_ref, man);
    try writeManifestPbStub(allocator, voila_root, store_ref, man);
}

fn upsertImagesDb(
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    store_ref: []const u8,
    man: voila_manifest_json.Manifest,
) !void {
    const db_path = try std.fmt.allocPrint(allocator, "{s}/images.db", .{voila_root});
    defer allocator.free(db_path);
    const db_path_z = try allocator.allocSentinel(u8, db_path.len, 0);
    defer allocator.free(db_path_z);
    @memcpy(db_path_z, db_path);

    var db: ?*sqlite.sqlite3 = null;
    if (sqlite.sqlite3_open(db_path_z, &db) != sqlite.SQLITE_OK) return error.SqliteOpen;
    const db_ptr = db orelse return error.SqliteOpen;
    defer _ = sqlite.sqlite3_close(db_ptr);

    const schema =
        \\CREATE TABLE IF NOT EXISTS images (
        \\  ref TEXT PRIMARY KEY,
        \\  image_digest BLOB NOT NULL,
        \\  merged_root_manifest_chunk BLOB NOT NULL,
        \\  total_size INTEGER NOT NULL,
        \\  chunk_count INTEGER NOT NULL,
        \\  ingested_ns INTEGER NOT NULL,
        \\  last_used_ns INTEGER NOT NULL
        \\);
    ;
    _ = sqlite.sqlite3_exec(db_ptr, schema, null, null, null);

    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const now: i64 = @as(i64, ts.sec) * 1_000_000_000 + @as(i64, ts.nsec);
    const sql =
        \\INSERT INTO images (ref, image_digest, merged_root_manifest_chunk, total_size, chunk_count, ingested_ns, last_used_ns)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(ref) DO UPDATE SET
        \\  image_digest=excluded.image_digest,
        \\  merged_root_manifest_chunk=excluded.merged_root_manifest_chunk,
        \\  total_size=excluded.total_size,
        \\  chunk_count=excluded.chunk_count,
        \\  ingested_ns=excluded.ingested_ns,
        \\  last_used_ns=excluded.last_used_ns
    ;
    var stmt: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(db_ptr, sql, -1, &stmt, null) != sqlite.SQLITE_OK) return error.SqlitePrepare;
    defer _ = sqlite.sqlite3_finalize(stmt);

    const ref_z = try allocator.allocSentinel(u8, store_ref.len, 0);
    defer allocator.free(ref_z);
    @memcpy(ref_z, store_ref);
    _ = sqlite.sqlite3_bind_text(stmt, 1, ref_z, -1, sqlite.SQLITE_STATIC);
    _ = sqlite.sqlite3_bind_blob(stmt, 2, man.image_digest.ptr, @intCast(man.image_digest.len), sqlite.SQLITE_STATIC);
    _ = sqlite.sqlite3_bind_blob(stmt, 3, man.merged_root.ptr, @intCast(man.merged_root.len), sqlite.SQLITE_STATIC);
    _ = sqlite.sqlite3_bind_int64(stmt, 4, @intCast(man.total_size));
    _ = sqlite.sqlite3_bind_int64(stmt, 5, @intCast(man.chunk_count));
    _ = sqlite.sqlite3_bind_int64(stmt, 6, now);
    _ = sqlite.sqlite3_bind_int64(stmt, 7, now);
    if (sqlite.sqlite3_step(stmt) != sqlite.SQLITE_DONE) return error.SqliteStep;
}

/// Best-effort empty images dir + ref key path (CLI may read .pb later).
fn writeManifestPbStub(
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    store_ref: []const u8,
    _: voila_manifest_json.Manifest,
) !void {
    const img_dir = try std.fmt.allocPrint(allocator, "{s}/images", .{voila_root});
    defer allocator.free(img_dir);
    const mkdir_cmd = try std.fmt.allocPrint(allocator, "mkdir -p {s}", .{img_dir});
    defer allocator.free(mkdir_cmd);
    const mkdir_z = try allocator.allocSentinel(u8, mkdir_cmd.len, 0);
    defer allocator.free(mkdir_z);
    @memcpy(mkdir_z, mkdir_cmd);
    _ = posix_util.shell(mkdir_z);
    const key = try voila_refkey.refKey(allocator, store_ref);
    defer allocator.free(key);
}

pub const Error = error{
    NoRegistry,
    Skip,
    SqliteOpen,
    SqlitePrepare,
    SqliteStep,
};
