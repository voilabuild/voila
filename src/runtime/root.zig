//! The `runtime` layer. Container runtime, build and the image loader.

pub const iface = @import("iface.zig");
pub const local = @import("local.zig");
pub const open = @import("open.zig");
pub const remote = @import("remote.zig");
pub const run_flags = @import("run_flags.zig");
pub const types = @import("types.zig");
pub const voila_loader = @import("voila_loader.zig");
pub const build = struct {
    pub const copy_from = @import("build/copy_from.zig");
    pub const copy_sources = @import("build/copy_sources.zig");
    pub const driver = @import("build/driver.zig");
    pub const image_store = @import("build/image_store.zig");
    pub const run_step = @import("build/run_step.zig");
    pub const steps = @import("build/steps.zig");
};
pub const oci = struct {
    pub const container_bind = @import("oci/container_bind.zig");
    pub const container_exec = @import("oci/container_exec.zig");
    pub const container_fuse_sibling = @import("oci/container_fuse_sibling.zig");
    pub const container_isolated_exec = @import("oci/container_isolated_exec.zig");
    pub const container_lifecycle = @import("oci/container_lifecycle.zig");
    pub const container_map_handshake = @import("oci/container_map_handshake.zig");
    pub const container_ports = @import("oci/container_ports.zig");
    pub const container_pty = @import("oci/container_pty.zig");
    pub const container_root = @import("oci/container_root.zig");
    pub const container_run = @import("oci/container_run.zig");
    pub const container_run_opts = @import("oci/container_run_opts.zig");
    pub const container_store = @import("oci/container_store.zig");
    pub const container_user = @import("oci/container_user.zig");
    pub const container_userns = @import("oci/container_userns.zig");
    pub const userns_ids = @import("oci/userns_ids.zig");
    pub const voila_image_run_config = @import("oci/voila_image_run_config.zig");
};

test {
    _ = @import("build/copy_from.zig");
    _ = @import("build/copy_sources.zig");
    _ = @import("build/driver.zig");
    _ = @import("build/driver_test.zig");
    _ = @import("build/image_store.zig");
    _ = @import("build/run_step.zig");
    _ = @import("build/steps.zig");
    _ = @import("iface.zig");
    _ = @import("local.zig");
    _ = @import("oci/container_bind.zig");
    _ = @import("oci/container_exec.zig");
    _ = @import("oci/container_fuse_sibling.zig");
    _ = @import("oci/container_isolated_exec.zig");
    _ = @import("oci/container_lifecycle.zig");
    _ = @import("oci/container_map_handshake.zig");
    _ = @import("oci/container_ports.zig");
    _ = @import("oci/container_pty.zig");
    _ = @import("oci/container_root.zig");
    _ = @import("oci/container_run.zig");
    _ = @import("oci/container_run_opts.zig");
    _ = @import("oci/container_store.zig");
    _ = @import("oci/container_user.zig");
    _ = @import("oci/container_userns.zig");
    _ = @import("oci/userns_ids.zig");
    _ = @import("oci/voila_image_run_config.zig");
    _ = @import("open.zig");
    _ = @import("remote.zig");
    _ = @import("run_flags.zig");
    _ = @import("types.zig");
    _ = @import("voila_loader.zig");
    _ = @import("voila_loader_test.zig");
}
