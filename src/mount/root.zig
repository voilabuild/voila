//! The `mount` layer. Mount backends that expose an image as a filesystem.

pub const Backend = @import("Backend.zig");
pub const mount_exec = @import("mount_exec.zig");
pub const fuse = struct {
    pub const chunk_fetch_pool = @import("fuse/chunk_fetch_pool.zig");
    pub const fuse_abi = @import("fuse/fuse_abi.zig");
    pub const fuse_libfuse = @import("fuse/fuse_libfuse.zig");
    pub const fuse_linux = @import("fuse/fuse_linux.zig");
    pub const fuse_vfs = @import("fuse/fuse_vfs.zig");
    pub const read_walker = @import("fuse/read_walker.zig");
    pub const vfs = @import("fuse/vfs.zig");
    pub const voila_vfs = @import("fuse/voila_vfs.zig");
};

test {
    _ = @import("Backend.zig");
    _ = @import("fuse/chunk_fetch_pool.zig");
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
