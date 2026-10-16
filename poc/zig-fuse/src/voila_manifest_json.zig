const std = @import("std");
pub const Manifest = struct {
    image_ref: []const u8,
    image_digest: []u8,
    merged_root: []u8,
    total_size: u64,
    chunk_count: u64,
};

/// Parse registry manifest JSON (subset of fields).
pub fn parse(allocator: std.mem.Allocator, json: []const u8) !Manifest {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.BadJson;
    const obj = root.object;

    const image_ref = try dupStr(allocator, obj.get("image_ref"));
    const image_digest = try decodeHexField(allocator, obj.get("image_digest"));
    const merged_root = try decodeHexField(allocator, obj.get("merged_root_manifest_chunk"));
    if (merged_root.len != 32) return error.BadRoot;

    var total_size: u64 = 0;
    if (obj.get("total_size")) |v| {
        if (v == .integer) total_size = @intCast(v.integer);
        if (v == .float) total_size = @intFromFloat(v.float);
    }
    var chunk_count: u64 = 0;
    if (obj.get("chunk_count")) |v| {
        if (v == .integer) chunk_count = @intCast(v.integer);
        if (v == .float) chunk_count = @intFromFloat(v.float);
    }

    return .{
        .image_ref = image_ref,
        .image_digest = image_digest,
        .merged_root = merged_root,
        .total_size = total_size,
        .chunk_count = chunk_count,
    };
}

fn dupStr(allocator: std.mem.Allocator, v: ?std.json.Value) ![]const u8 {
    const val = v orelse return error.MissingField;
    if (val != .string) return error.BadJson;
    return allocator.dupe(u8, val.string);
}

fn decodeHexField(allocator: std.mem.Allocator, v: ?std.json.Value) ![]u8 {
    const val = v orelse return allocator.alloc(u8, 0);
    if (val != .string) return error.BadJson;
    if (val.string.len == 0) return allocator.alloc(u8, 0);
    const n = val.string.len / 2;
    const out = try allocator.alloc(u8, n);
    _ = try std.fmt.hexToBytes(out, val.string);
    return out;
}

pub const Error = error{
    BadJson,
    MissingField,
    BadRoot,
};
