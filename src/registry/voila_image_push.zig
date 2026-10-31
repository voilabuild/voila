const std = @import("std");
const voila_http = @import("./voila_http.zig");
const voila_registry_hub = @import("./voila_registry_hub.zig");
const voila_resolve = @import("./voila_resolve.zig");
const voila_manifest_cache = @import("./voila_manifest_cache.zig");
const voila_reachable = @import("./voila_reachable.zig");
const voila_chunk_upload = @import("./voila_chunk_upload.zig");
const voila_manifest_json = @import("codec").voila_manifest_json;

const missing_batch = 16384;

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

    var http = voila_http.Session.init(io, allocator);
    defer http.deinit();

    const manifest_body = voila_manifest_cache.load(allocator, voila_root, rec.ref) catch blk: {
        const escaped = try voila_http.pathEscape(allocator, rec.ref);
        defer allocator.free(escaped);
        const url = try std.fmt.allocPrint(allocator, "{s}/v1/images/{s}", .{ cfg.base_url, escaped });
        defer allocator.free(url);
        break :blk try http.get(allocator, url, cfg.token);
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

    std.debug.print("checking {d} chunks…\n", .{ids.len});
    const missing = try missingChunks(&http, allocator, cfg, ids);
    defer {
        for (missing) |id| allocator.free(id);
        allocator.free(missing);
    }

    const uploaded = try voila_chunk_upload.uploadMissing(io, allocator, voila_root, cfg, missing);

    const escaped_put = try voila_http.pathEscape(allocator, man.image_ref);
    defer allocator.free(escaped_put);
    const put_url = try std.fmt.allocPrint(allocator, "{s}/v1/images/{s}", .{ cfg.base_url, escaped_put });
    defer allocator.free(put_url);
    const put_code = http.put(put_url, cfg.token, manifest_body, "application/json", null) catch return error.ManifestPut;
    if (put_code != 200 and put_code != 201) return error.ManifestPut;

    const already = ids.len - missing.len;
    std.debug.print(
        "pushed {s}: {d} chunks uploaded, {d} already present, {d} MiB\n",
        .{ man.image_ref, uploaded.uploaded, already, uploaded.bytes / (1024 * 1024) },
    );
}

fn missingChunks(
    http: *voila_http.Session,
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
        const resp = http.postJson(allocator, url, cfg.token, body) catch return error.MissingNegotiation;
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
