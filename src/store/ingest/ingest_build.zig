const std = @import("std");
const tree_mod = @import("ingest_tree.zig");
const chunk_store = @import("ingest_chunk_store.zig");
const manifest_mod = @import("ingest_manifest.zig");
const merge_mod = @import("ingest_merge.zig");

pub const LayerResult = struct {
    root_manifest_chunk: chunk_store.ChunkId,
    whiteouts_count: u64,
};

pub const Result = struct {
    ref: []const u8,
    image_digest: []const u8,
    config_chunk: chunk_store.ChunkId,
    merged_root_manifest_chunk: chunk_store.ChunkId,
    layers: []LayerResult,
    bytes_in: u64,
    chunk_count: u64,
    chunks_deduped: u64,
    stored_bytes: u64,
    layers_reused: u64,
};

pub const ParsedLayout = struct {
    ref: []const u8,
    image_digest: []const u8,
    config_digest: []const u8,
    layers: []LayerDesc,
};

pub const LayerDesc = struct {
    digest: []const u8,
    media_type: []const u8,
    index: usize,
};

pub fn buildIngestResult(
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    pl: ParsedLayout,
    layer_trees: []*tree_mod.LayerTree,
    config_chunk: chunk_store.ChunkId,
    agg_bytes_in: u64,
    agg_chunk_count: u64,
    agg_deduped: u64,
    agg_stored: u64,
    ref_override: ?[]const u8,
) !Result {
    const merged = try merge_mod.mergeTrees(allocator, layer_trees);
    defer merged.deinit();

    var layers: std.ArrayList(LayerResult) = .empty;
    for (layer_trees) |lt| {
        const chunk = try manifest_mod.buildAndStoreManifest(allocator, voila_root, lt, true);
        try layers.append(allocator, .{
            .root_manifest_chunk = chunk,
            .whiteouts_count = lt.whiteouts_n + lt.opaque_n,
        });
    }

    const root_chunk = try manifest_mod.buildAndStoreManifest(allocator, voila_root, merged, false);

    const ref = if (ref_override) |r| r else pl.ref;

    return .{
        .ref = try allocator.dupe(u8, ref),
        .image_digest = try allocator.dupe(u8, pl.image_digest),
        .config_chunk = config_chunk,
        .merged_root_manifest_chunk = root_chunk,
        .layers = try layers.toOwnedSlice(allocator),
        .bytes_in = agg_bytes_in,
        .chunk_count = agg_chunk_count,
        .chunks_deduped = agg_deduped,
        .stored_bytes = agg_stored,
        .layers_reused = 0,
    };
}
