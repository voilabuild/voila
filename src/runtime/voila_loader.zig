const std = @import("std");
const voila_resolve = @import("registry").voila_resolve;
const voila_tree = @import("store").voila_tree;
const voila_index = @import("core").voila_index;
const voila_image_pull = @import("registry").voila_image_pull;
const registry_ref = @import("registry").voila_registry_ref;
const voila_registry_fetch = @import("registry").voila_registry_fetch;
const voila_chunk_load = @import("store").voila_chunk_load;

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

    var tree = try voila_tree.openTreeEager(allocator, voila_root, rec.merged_root_manifest, fetcherFor(io));
    defer tree.deinit();
    return tree.buildIndex();
}

/// Lazy tree (root manifest only) for serve-store; subtrees load on FUSE access.
fn normalizeImageRef(allocator: std.mem.Allocator, image_ref: []const u8) ![]const u8 {
    return registry_ref.normalizeUserRef(allocator, image_ref);
}

/// `image_ref` may also be `@<64 hex>`: a merged root manifest chunk with no ref (build steps).
pub fn loadTreeRoot(io: ?std.Io, allocator: std.mem.Allocator, voila_root: []const u8, image_ref: []const u8) !voila_tree.Tree {
    if (rootChunkRef(image_ref)) |root| return voila_tree.openTree(allocator, voila_root, &root, fetcherFor(io));
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
    return voila_tree.openTree(allocator, voila_root, rec.merged_root_manifest, fetcherFor(io));
}

/// Resolves `image_ref` once (auto-pulling the manifest) to `@<root hex>`, which later
/// loads, including the FUSE server's, take without touching the registry.
pub fn resolveRootRef(io: ?std.Io, allocator: std.mem.Allocator, voila_root: []const u8, image_ref: []const u8) ![]const u8 {
    if (rootChunkRef(image_ref) != null) return allocator.dupe(u8, image_ref);
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
    const hex = std.fmt.bytesToHex(rec.merged_root_manifest[0..32].*, .lower);
    return std.fmt.allocPrint(allocator, "@{s}", .{&hex});
}

/// Chunks missing locally come from the registry when `io` is set.
pub fn fetcherFor(io: ?std.Io) ?voila_chunk_load.Fetcher {
    return if (io) |i| voila_registry_fetch.fetcher(i) else null;
}

pub fn rootChunkRef(image_ref: []const u8) ?[32]u8 {
    if (image_ref.len != 65 or image_ref[0] != '@') return null;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, image_ref[1..]) catch return null;
    return out;
}

pub const Error = error{BadRootManifest};
