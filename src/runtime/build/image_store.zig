//! Load a build's base image and persist the result as a regular local image.
const std = @import("std");
const tree_mod = @import("../../store/ingest/ingest_tree.zig");
const manifest_mod = @import("../../store/ingest/ingest_manifest.zig");
const ingest_build = @import("../../store/ingest/ingest_build.zig");
const voila_resolve = @import("../../registry/voila_resolve.zig");
const run_config = @import("../oci/voila_image_run_config.zig");
const registry_ref = @import("../../registry/voila_registry_ref.zig");
const voila_image_pull = @import("../../registry/voila_image_pull.zig");
const voila_image_import = @import("../../registry/voila_image_import.zig");
const voila_manifest_cache = @import("../../registry/voila_manifest_cache.zig");
const voila_manifest_json = @import("../../codec/voila_manifest_json.zig");

pub const Base = struct {
    root: [32]u8,
    config_json: []const u8,
};

pub const Error = error{BaseImageNotFound};

/// Resolves a FROM reference locally, pulling it first when a registry is configured.
/// `scratch` is the empty image.
pub fn loadBase(io: std.Io, a: std.mem.Allocator, voila_root: []const u8, ref: []const u8) !Base {
    if (std.mem.eql(u8, ref, "scratch")) {
        const empty = try tree_mod.newTree(a);
        return .{ .root = try manifest_mod.buildAndStoreManifest(a, voila_root, empty, false), .config_json = "" };
    }
    const ref_norm = try registry_ref.normalizeUserRef(a, ref);
    _ = voila_image_pull.autoPull(io, a, voila_root, ref_norm) catch {};
    const rec = voila_resolve.resolveImage(a, voila_root, ref_norm) catch return error.BaseImageNotFound;
    if (rec.merged_root_manifest.len != 32) return error.BaseImageNotFound;
    return .{
        .root = rec.merged_root_manifest[0..32].*,
        .config_json = run_config.loadConfigJson(io, a, voila_root, ref_norm) catch "",
    };
}

pub const Image = struct {
    root: [32]u8,
    config: [32]u8,
    layers: []ingest_build.LayerResult,
    /// Final tree when the build loaded it; used for size totals only.
    tree: ?*tree_mod.LayerTree,
};

pub fn persist(a: std.mem.Allocator, voila_root: []const u8, tag: []const u8, img: Image) !void {
    const ref = try registry_ref.normalizeUserRef(a, tag);
    var h = std.crypto.hash.Blake3.init(.{});
    h.update(&img.root);
    h.update(&img.config);
    const digest = try a.alloc(u8, 32);
    h.final(digest[0..32]);

    var bytes: u64 = 0;
    var chunks: u64 = 0;
    if (img.tree) |t| {
        var it = t.by_path.valueIterator();
        while (it.next()) |n| if (n.*.node_type == .regular) {
            bytes += n.*.size;
            chunks += n.*.blocks.items.len;
        };
    }
    const json = try voila_image_import.buildManifestJson(a, .{
        .ref = ref,
        .image_digest = digest,
        .config_chunk = img.config,
        .merged_root_manifest_chunk = img.root,
        .layers = img.layers,
        .bytes_in = bytes,
        .chunk_count = chunks,
        .chunks_deduped = 0,
        .stored_bytes = 0,
        .layers_reused = 0,
    });
    try voila_manifest_cache.save(a, voila_root, ref, json);
    const man = try voila_manifest_json.parse(a, json);
    try voila_image_pull.persistManifest(a, voila_root, ref, json, man);
}
