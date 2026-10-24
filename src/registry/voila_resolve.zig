const std = @import("std");
const sqlite = @import("sqlite_c");
const ocireg = @import("./voila_ocireg.zig");
const hex_util = @import("../core/hex_util.zig");
const registry_ref = @import("./voila_registry_ref.zig");
const voila_login_creds = @import("./voila_login_creds.zig");
const voila_refkey = @import("../core/voila_refkey.zig");
const voila_manifest_cache = @import("./voila_manifest_cache.zig");

pub const Error = error{
    SqliteOpen,
    SqlitePrepare,
    SqliteStep,
    NoImageMatch,
    AmbiguousDigest,
};

pub const ImageRecord = struct {
    ref: []const u8,
    image_digest: []const u8,
    merged_root_manifest: []const u8,
};

pub fn refKey(allocator: std.mem.Allocator, ref: []const u8) ![]const u8 {
    var sanitized: std.ArrayList(u8) = .empty;
    for (ref) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or
            c == '.' or c == '_' or c == '-';
        try sanitized.append(allocator, if (ok) c else '_');
    }
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(ref, &hash, .{});
    var hex8: [8]u8 = undefined;
    hex_util.encodeHexLower(&hex8, hash[0..4]);
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ sanitized.items, &hex8 });
}

fn stripDigestScheme(s: []const u8) []const u8 {
    const prefixes = [_][]const u8{ "sha256:", "sha512:", "sha:", "blake3:" };
    for (prefixes) |p| {
        if (s.len > p.len and std.mem.startsWith(u8, s, p)) return s[p.len..];
    }
    return s;
}

pub fn resolveImage(allocator: std.mem.Allocator, voila_root: []const u8, query: []const u8) !ImageRecord {
    const query_norm = try registry_ref.normalizeUserRef(allocator, query);
    defer allocator.free(query_norm);
    const db_path = try std.fmt.allocPrint(allocator, "{s}/images.db", .{voila_root});
    defer allocator.free(db_path);
    const db_path_z = try allocator.allocSentinel(u8, db_path.len, 0);
    defer allocator.free(db_path_z);
    @memcpy(db_path_z, db_path);

    var db: ?*sqlite.sqlite3 = null;
    if (sqlite.sqlite3_open(db_path_z, &db) != sqlite.SQLITE_OK) return Error.SqliteOpen;
    const db_ptr = db orelse return Error.SqliteOpen;
    defer _ = sqlite.sqlite3_close(db_ptr);

    const rows = try listImages(allocator, db_ptr);
    defer {
        for (rows) |r| {
            allocator.free(r.ref);
            allocator.free(r.image_digest);
            allocator.free(r.merged_root_manifest);
        }
        allocator.free(rows);
    }

    for (rows) |r| {
        if (std.mem.eql(u8, r.ref, query_norm)) return dupRecord(allocator, r);
    }
    if (!std.mem.eql(u8, query, query_norm)) {
        for (rows) |r| {
            if (std.mem.eql(u8, r.ref, query)) return dupRecord(allocator, r);
        }
    }

    if (try ocireg.canonical(allocator, query_norm)) |canon| {
        defer allocator.free(canon);
        if (!std.mem.eql(u8, canon, query_norm)) {
            for (rows) |r| {
                if (std.mem.eql(u8, r.ref, canon)) return dupRecord(allocator, r);
            }
        }
    }

    var org_slice: []const u8 = "";
    var login_creds: ?voila_login_creds.LoginCreds = null;
    if (try voila_login_creds.loadLoginCreds(allocator)) |lc| {
        login_creds = lc;
        org_slice = lc.org;
    }
    defer if (login_creds) |lc| {
        allocator.free(lc.registry);
        allocator.free(lc.token);
        allocator.free(lc.org);
    };
    if (registry_ref.registryPullCandidates(allocator, query_norm, org_slice)) |pull_candidates| {
        defer {
            for (pull_candidates) |c| allocator.free(c);
            allocator.free(pull_candidates);
        }
        for (pull_candidates) |candidate| {
            for (rows) |r| {
                if (std.mem.eql(u8, r.ref, candidate)) return dupRecord(allocator, r);
            }
        }
    } else |_| {}

    const stripped = stripDigestScheme(query_norm);
    var query_hex = try allocator.alloc(u8, stripped.len);
    defer allocator.free(query_hex);
    for (stripped, 0..) |c, i| query_hex[i] = std.ascii.toLower(c);
    if (query_hex.len == 0) return Error.NoImageMatch;

    var hits: std.ArrayList(ImageRecord) = .empty;
    for (rows) |r| {
        var dig_hex: [128]u8 = undefined;
        if (r.image_digest.len * 2 > dig_hex.len) continue;
        hex_util.encodeHexLower(dig_hex[0 .. r.image_digest.len * 2], r.image_digest);
        const dig = dig_hex[0 .. r.image_digest.len * 2];
        if (query_hex.len > dig.len) continue;
        if (std.mem.eql(u8, dig[0..query_hex.len], query_hex))
            try hits.append(allocator, r);
    }
    switch (hits.items.len) {
        0 => return Error.NoImageMatch,
        1 => return dupRecord(allocator, hits.items[0]),
        else => return Error.AmbiguousDigest,
    }
}

fn dupRecord(allocator: std.mem.Allocator, r: ImageRecord) !ImageRecord {
    return .{
        .ref = try allocator.dupe(u8, r.ref),
        .image_digest = try allocator.dupe(u8, r.image_digest),
        .merged_root_manifest = try allocator.dupe(u8, r.merged_root_manifest),
    };
}

pub fn listImagesInStore(allocator: std.mem.Allocator, voila_root: []const u8) ![]ImageRecord {
    const db_path = try std.fmt.allocPrint(allocator, "{s}/images.db", .{voila_root});
    defer allocator.free(db_path);
    const db_path_z = try allocator.allocSentinel(u8, db_path.len, 0);
    defer allocator.free(db_path_z);
    @memcpy(db_path_z, db_path);

    var db: ?*sqlite.sqlite3 = null;
    if (sqlite.sqlite3_open(db_path_z, &db) != sqlite.SQLITE_OK) return Error.SqliteOpen;
    const db_ptr = db orelse return Error.SqliteOpen;
    defer _ = sqlite.sqlite3_close(db_ptr);
    return listImages(allocator, db_ptr);
}

fn listImages(allocator: std.mem.Allocator, db: *sqlite.sqlite3) ![]ImageRecord {
    const sql = "SELECT ref, image_digest, merged_root_manifest_chunk FROM images";
    var stmt: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != sqlite.SQLITE_OK) return Error.SqlitePrepare;
    defer _ = sqlite.sqlite3_finalize(stmt);

    var out: std.ArrayList(ImageRecord) = .empty;
    while (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
        const ref_ptr = sqlite.sqlite3_column_text(stmt, 0);
        const ref_len = sqlite.sqlite3_column_bytes(stmt, 0);
        const dig_ptr = sqlite.sqlite3_column_blob(stmt, 1);
        const dig_len = sqlite.sqlite3_column_bytes(stmt, 1);
        const man_ptr = sqlite.sqlite3_column_blob(stmt, 2);
        const man_len = sqlite.sqlite3_column_bytes(stmt, 2);
        try out.append(allocator, .{
            .ref = try allocator.dupe(u8, ref_ptr[0..@intCast(ref_len)]),
            .image_digest = try allocator.dupe(u8, @as([*]const u8, @ptrCast(dig_ptr))[0..@intCast(dig_len)]),
            .merged_root_manifest = try allocator.dupe(u8, @as([*]const u8, @ptrCast(man_ptr))[0..@intCast(man_len)]),
        });
    }
    return try out.toOwnedSlice(allocator);
}

pub fn removeImage(allocator: std.mem.Allocator, voila_root: []const u8, image_ref: []const u8) !void {
    const db_path = try std.fmt.allocPrint(allocator, "{s}/images.db", .{voila_root});
    defer allocator.free(db_path);
    const db_path_z = try allocator.allocSentinel(u8, db_path.len, 0);
    defer allocator.free(db_path_z);
    @memcpy(db_path_z, db_path);
    var db: ?*sqlite.sqlite3 = null;
    if (sqlite.sqlite3_open(db_path_z, &db) != sqlite.SQLITE_OK) return Error.SqliteOpen;
    const db_ptr = db orelse return Error.SqliteOpen;
    defer _ = sqlite.sqlite3_close(db_ptr);
    const sql = "DELETE FROM images WHERE ref = ?1";
    var stmt: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(db_ptr, sql, -1, &stmt, null) != sqlite.SQLITE_OK) return Error.SqlitePrepare;
    defer _ = sqlite.sqlite3_finalize(stmt);
    const ref_z = try allocator.allocSentinel(u8, image_ref.len, 0);
    defer allocator.free(ref_z);
    @memcpy(ref_z, image_ref);
    _ = sqlite.sqlite3_bind_text(stmt, 1, ref_z, -1, sqlite.SQLITE_STATIC);
    if (sqlite.sqlite3_step(stmt) != sqlite.SQLITE_DONE) return Error.SqliteStep;
    try deleteImageSidecars(allocator, voila_root, image_ref);
}

fn deleteImageSidecars(allocator: std.mem.Allocator, voila_root: []const u8, image_ref: []const u8) !void {
    deleteSidecarsForRef(allocator, voila_root, image_ref);
    const norm = registry_ref.normalizeUserRef(allocator, image_ref) catch return;
    defer allocator.free(norm);
    if (!std.mem.eql(u8, norm, image_ref)) deleteSidecarsForRef(allocator, voila_root, norm);
}

fn deleteSidecarsForRef(allocator: std.mem.Allocator, voila_root: []const u8, store_ref: []const u8) void {
    const key = voila_refkey.refKey(allocator, store_ref) catch return;
    defer allocator.free(key);
    const pb = std.fmt.allocPrint(allocator, "{s}/images/{s}.pb", .{ voila_root, key }) catch return;
    defer allocator.free(pb);
    unlinkQuiet(pb);
    const man = voila_manifest_cache.manifestPath(allocator, voila_root, store_ref) catch return;
    defer allocator.free(man);
    unlinkQuiet(man);
}

fn unlinkQuiet(path: []const u8) void {
    const path_z = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return;
    defer std.heap.page_allocator.free(path_z);
    @memcpy(path_z, path);
    _ = std.c.unlink(path_z);
}
