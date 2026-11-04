//! `voila tag`: a second local name for an image (manifest copy with a new `image_ref`).
const std = @import("std");
const posix_util = @import("sys").posix_util;
const fs = @import("sys").fs;
const voila_refkey = @import("core").voila_refkey;
const voila_manifest_json = @import("codec").voila_manifest_json;
const voila_resolve = @import("./voila_resolve.zig");
const voila_manifest_cache = @import("./voila_manifest_cache.zig");
const voila_image_pull = @import("./voila_image_pull.zig");
const registry_ref = @import("./voila_registry_ref.zig");

pub const Error = error{NoManifest};

pub fn tagImage(allocator: std.mem.Allocator, voila_root: []const u8, source: []const u8, target: []const u8) !void {
    const rec = try voila_resolve.resolveImage(allocator, voila_root, source);
    defer {
        allocator.free(rec.ref);
        allocator.free(rec.image_digest);
        allocator.free(rec.merged_root_manifest);
    }
    const dst = try registry_ref.normalizeUserRef(allocator, target);
    defer allocator.free(dst);
    const body = voila_manifest_cache.load(allocator, voila_root, rec.ref) catch return error.NoManifest;
    defer allocator.free(body);
    const new_body = try withImageRef(allocator, body, dst);
    defer allocator.free(new_body);
    const man = try voila_manifest_json.parse(allocator, new_body);
    defer {
        allocator.free(man.image_ref);
        allocator.free(man.image_digest);
        allocator.free(man.merged_root);
    }
    try voila_image_pull.persistManifest(allocator, voila_root, dst, new_body, man);
    try voila_manifest_cache.save(allocator, voila_root, dst, new_body);
    // Imported and built images keep a full ImageManifest; the stub from persistManifest only has the config.
    try copySidecar(allocator, voila_root, rec.ref, dst);
}

fn copySidecar(allocator: std.mem.Allocator, voila_root: []const u8, from_ref: []const u8, to_ref: []const u8) !void {
    const from_key = try voila_refkey.refKey(allocator, from_ref);
    defer allocator.free(from_key);
    const to_key = try voila_refkey.refKey(allocator, to_ref);
    defer allocator.free(to_key);
    const from = try std.fmt.allocPrint(allocator, "{s}/images/{s}.pb", .{ voila_root, from_key });
    defer allocator.free(from);
    const to = try std.fmt.allocPrint(allocator, "{s}/images/{s}.pb", .{ voila_root, to_key });
    defer allocator.free(to);
    const pb = posix_util.readFileAlloc(allocator, from, 64 * 1024 * 1024) catch return; // no sidecar: the stub stands
    defer allocator.free(pb);
    try fs.writeFile(to, pb, 0o644);
}

/// The manifest JSON with `image_ref` set to `ref`; other fields are kept.
pub fn withImageRef(allocator: std.mem.Allocator, body: []const u8, ref: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.NoManifest;
    try parsed.value.object.put(parsed.arena.allocator(), "image_ref", .{ .string = ref });
    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
}

test "withImageRef replaces only image_ref" {
    const a = std.testing.allocator;
    const out = try withImageRef(a, "{\"image_ref\":\"alpine:3.20\",\"total_size\":7}", "acme/alpine:3.20");
    defer a.free(out);
    const p = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer p.deinit();
    try std.testing.expectEqualStrings("acme/alpine:3.20", p.value.object.get("image_ref").?.string);
    try std.testing.expectEqual(@as(i64, 7), p.value.object.get("total_size").?.integer);
}
