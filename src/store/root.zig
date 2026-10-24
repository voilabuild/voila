//! The `store` layer. Local chunk store, manifests and ingest.

pub const build_cache = @import("build_cache.zig");
pub const fixture = @import("fixture.zig");
pub const voila_chunk_index = @import("voila_chunk_index.zig");
pub const voila_chunk_load = @import("voila_chunk_load.zig");
pub const voila_store = @import("voila_store.zig");
pub const voila_tree = @import("voila_tree.zig");
pub const ingest = struct {
    pub const ingest_build = @import("ingest/ingest_build.zig");
    pub const ingest_chunk_store = @import("ingest/ingest_chunk_store.zig");
    pub const ingest_dir_walk = @import("ingest/ingest_dir_walk.zig");
    pub const ingest_from_manifest = @import("ingest/ingest_from_manifest.zig");
    pub const ingest_layer_walk = @import("ingest/ingest_layer_walk.zig");
    pub const ingest_manifest = @import("ingest/ingest_manifest.zig");
    pub const ingest_merge = @import("ingest/ingest_merge.zig");
    pub const ingest_tar = @import("ingest/ingest_tar.zig");
    pub const ingest_tree = @import("ingest/ingest_tree.zig");
    pub const ingest_whiteouts = @import("ingest/ingest_whiteouts.zig");
};

test {
    _ = @import("build_cache.zig");
    _ = @import("fixture.zig");
    _ = @import("ingest/ingest_build.zig");
    _ = @import("ingest/ingest_chunk_store.zig");
    _ = @import("ingest/ingest_dir_walk.zig");
    _ = @import("ingest/ingest_dir_walk_test.zig");
    _ = @import("ingest/ingest_from_manifest.zig");
    _ = @import("ingest/ingest_layer_walk.zig");
    _ = @import("ingest/ingest_manifest.zig");
    _ = @import("ingest/ingest_merge.zig");
    _ = @import("ingest/ingest_tar.zig");
    _ = @import("ingest/ingest_tree.zig");
    _ = @import("ingest/ingest_whiteouts.zig");
    _ = @import("voila_chunk_index.zig");
    _ = @import("voila_chunk_load.zig");
    _ = @import("voila_store.zig");
    _ = @import("voila_tree.zig");
}
