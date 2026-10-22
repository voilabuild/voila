const std = @import("std");
const voila_resolve = @import("../runtime/voila_resolve.zig");
const voila_tree = @import("../core/voila_tree.zig");
const voila_index = @import("../core/voila_index.zig");
const voila_image_pull = @import("../registry/voila_image_pull.zig");
const registry_ref = @import("../registry/voila_registry_ref.zig");

pub fn loadIndex(io: ?std.Io, allocator: std.mem.Allocator, voila_root: []const u8, image_ref: []const u8) !voila_index.Index {
    const ref_norm = try normalizeImageRef(allocator, image_ref);
    defer allocator.free(ref_norm);
    if (io) |i| _ = voila_image_pull.autoPull(i, allocator, voila_root, ref_norm) catch {};
    const rec = try voila_resolve.resolveImage(allocator, voila_root, ref_norm);
    defer {
        allocator.free(rec.ref);
        allocator.free(rec.image_digest);
        allocator.free(rec.merged_root_manifest);
    }
    if (rec.merged_root_manifest.len != 32) return error.BadRootManifest;

    var tree = try voila_tree.openTreeEager(allocator, voila_root, rec.merged_root_manifest);
    defer tree.deinit();
    return tree.buildIndex();
}

/// Lazy tree (root manifest only) for serve-store; subtrees load on FUSE access.
fn normalizeImageRef(allocator: std.mem.Allocator, image_ref: []const u8) ![]const u8 {
    return registry_ref.normalizeUserRef(allocator, image_ref);
}

pub fn loadTreeRoot(io: ?std.Io, allocator: std.mem.Allocator, voila_root: []const u8, image_ref: []const u8) !voila_tree.Tree {
    const ref_norm = try normalizeImageRef(allocator, image_ref);
    defer allocator.free(ref_norm);
    if (io) |i| _ = voila_image_pull.autoPull(i, allocator, voila_root, ref_norm) catch {};
    const rec = try voila_resolve.resolveImage(allocator, voila_root, ref_norm);
    defer {
        allocator.free(rec.ref);
        allocator.free(rec.image_digest);
        allocator.free(rec.merged_root_manifest);
    }
    if (rec.merged_root_manifest.len != 32) return error.BadRootManifest;
    return voila_tree.openTree(allocator, voila_root, rec.merged_root_manifest);
}

pub const Error = error{BadRootManifest};
