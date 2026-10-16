const std = @import("std");
const voila_resolve = @import("voila_resolve.zig");
const voila_tree = @import("voila_tree.zig");
const voila_index = @import("voila_index.zig");

pub fn loadIndex(allocator: std.mem.Allocator, voila_root: []const u8, image_ref: []const u8) !voila_index.Index {
    const rec = try voila_resolve.resolveImage(allocator, voila_root, image_ref);
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
pub fn loadTreeRoot(allocator: std.mem.Allocator, voila_root: []const u8, image_ref: []const u8) !voila_tree.Tree {
    const rec = try voila_resolve.resolveImage(allocator, voila_root, image_ref);
    defer {
        allocator.free(rec.ref);
        allocator.free(rec.image_digest);
        allocator.free(rec.merged_root_manifest);
    }
    if (rec.merged_root_manifest.len != 32) return error.BadRootManifest;
    return voila_tree.openTree(allocator, voila_root, rec.merged_root_manifest);
}

pub const Error = error{ BadRootManifest };
