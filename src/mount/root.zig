//! The `mount` layer. Mount backends that expose an image as a filesystem.

pub const mount_exec = @import("mount_exec.zig");
pub const erofs_nbd = struct {
    pub const backend = @import("erofs_nbd/backend.zig");
    pub const capacity_wait = @import("erofs_nbd/capacity_wait.zig");
    pub const constants = @import("erofs_nbd/constants.zig");
    pub const erofs_build = @import("erofs_nbd/erofs_build.zig");
    pub const fixture_build = @import("erofs_nbd/fixture_build.zig");
    pub const hex_util = @import("erofs_nbd/hex_util.zig");
    pub const image_resolve = @import("erofs_nbd/image_resolve.zig");
    pub const main = @import("erofs_nbd/main.zig");
    pub const nbd_blocking = @import("erofs_nbd/nbd_blocking.zig");
    pub const nbd_linux = @import("erofs_nbd/nbd_linux.zig");
    pub const posix_util = @import("erofs_nbd/posix_util.zig");
    pub const voila_store = @import("erofs_nbd/voila_store.zig");
    pub const voila_tree = @import("erofs_nbd/voila_tree.zig");
    pub const voilad_bundle = @import("erofs_nbd/voilad_bundle.zig");
    pub const manifest = struct {
        pub const proto_wire = @import("erofs_nbd/manifest/proto_wire.zig");
        pub const voila_manifest_proto = @import("erofs_nbd/manifest/voila_manifest_proto.zig");
    };
};
pub const fuse = struct {
    pub const fuse_abi = @import("fuse/fuse_abi.zig");
    pub const fuse_libfuse = @import("fuse/fuse_libfuse.zig");
    pub const fuse_linux = @import("fuse/fuse_linux.zig");
    pub const fuse_vfs = @import("fuse/fuse_vfs.zig");
    pub const read_walker = @import("fuse/read_walker.zig");
    pub const vfs = @import("fuse/vfs.zig");
    pub const voila_vfs = @import("fuse/voila_vfs.zig");
};

test {
    _ = @import("erofs_nbd/backend.zig");
    _ = @import("erofs_nbd/capacity_wait.zig");
    _ = @import("erofs_nbd/constants.zig");
    _ = @import("erofs_nbd/erofs_build.zig");
    _ = @import("erofs_nbd/fixture_build.zig");
    _ = @import("erofs_nbd/hex_util.zig");
    _ = @import("erofs_nbd/image_resolve.zig");
    _ = @import("erofs_nbd/main.zig");
    _ = @import("erofs_nbd/manifest/proto_wire.zig");
    _ = @import("erofs_nbd/manifest/voila_manifest_proto.zig");
    _ = @import("erofs_nbd/nbd_blocking.zig");
    _ = @import("erofs_nbd/nbd_linux.zig");
    _ = @import("erofs_nbd/posix_util.zig");
    _ = @import("erofs_nbd/voila_store.zig");
    _ = @import("erofs_nbd/voila_tree.zig");
    _ = @import("erofs_nbd/voilad_bundle.zig");
    _ = @import("fuse/fuse_abi.zig");
    _ = @import("fuse/fuse_abi_test.zig");
    _ = @import("fuse/fuse_conf_test.zig");
    _ = @import("fuse/fuse_libfuse.zig");
    _ = @import("fuse/fuse_linux.zig");
    _ = @import("fuse/fuse_vfs.zig");
    _ = @import("fuse/read_walker.zig");
    _ = @import("fuse/vfs.zig");
    _ = @import("fuse/voila_vfs.zig");
    _ = @import("fuse/voila_vfs_test.zig");
    _ = @import("mount_exec.zig");
}
