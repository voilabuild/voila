const build_options = @import("build_options");

test {
    if (build_options.privileged) _ = @import("privileged_tests.zig");
    _ = @import("codec/oci_image_config.zig");
    _ = @import("core/build_cache_key.zig");
    _ = @import("core/dockerfile.zig");
    _ = @import("core/glob.zig");
    _ = @import("core/idmap.zig");
    _ = @import("core/passwd.zig");
    _ = @import("sys/fs.zig");
    _ = @import("store/build_cache.zig");
    _ = @import("store/voila_store.zig");
    _ = @import("store/voila_loader_test.zig");
    _ = @import("store/ingest/ingest_dir_walk_test.zig");
    _ = @import("store/ingest/ingest_merge.zig");
    _ = @import("store/ingest/ingest_registry.zig");
    _ = @import("store/ingest/ingest_tar.zig");
    _ = @import("registry/ocireg_client.zig");
    _ = @import("registry/voila_registry_ref_test.zig");
    _ = @import("mount/fuse/fuse_abi_test.zig");
    _ = @import("mount/fuse/fuse_conf_test.zig");
    _ = @import("mount/fuse/read_walker.zig");
    _ = @import("mount/erofs_nbd/backend.zig");
    _ = @import("mount/erofs_nbd/capacity_wait.zig");
    _ = @import("runtime/build/copy_sources.zig");
    _ = @import("runtime/build/driver_test.zig");
    _ = @import("runtime/build/steps.zig");
    _ = @import("cli/run_cli_parse.zig");
}
