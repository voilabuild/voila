const std = @import("std");
const container_store = @import("./container_store.zig");
const container_lifecycle = @import("./container_lifecycle.zig");
const container_run = @import("./container_run.zig");
const container_run_opts = @import("./container_run_opts.zig");
const mount_exec = @import("../../mount/mount_exec.zig");
const fuse_vfs_mod = @import("../../mount/fuse/fuse_vfs.zig");
const voila_loader = @import("../../store/voila_loader.zig");
const voila_vfs_mod = @import("../../mount/fuse/voila_vfs.zig");

pub const ExecSpec = struct {
    context_id: []const u8,
    argv: []const []const u8,
    tty: bool,
    interactive: bool,
};

pub fn exec(io: std.Io, allocator: std.mem.Allocator, voila_root: []const u8, spec: ExecSpec) !u8 {
    const id = try container_store.resolveId(allocator, voila_root, spec.context_id);
    defer allocator.free(id);
    const st = try container_store.readState(allocator, voila_root, id);
    defer container_store.freeState(allocator, st);
    if (!container_lifecycle.isRunning(st)) return error.NotRunning;
    if (!container_lifecycle.mountStillListed(st.mount_dir)) return error.NotRunning;
    const opts = try container_run_opts.readRunOpts(allocator, voila_root, id);
    defer opts.deinit(allocator);
    const tree = try voila_loader.loadTreeRoot(io, allocator, voila_root, st.image);
    var fuse_vfs: fuse_vfs_mod.FuseVfs = .{ .voila = voila_vfs_mod.VoilaVfs.initFromTree(allocator, tree) };
    defer fuse_vfs.deinit();
    const vfs_exec = try mount_exec.resolveArgv0VfsPath(allocator, &fuse_vfs, spec.argv[0]);
    defer allocator.free(vfs_exec);
    const use_tty = spec.tty or spec.interactive or opts.tty or opts.interactive;
    return container_run.execInMount(
        io,
        allocator,
        st.mount_dir,
        vfs_exec,
        spec.argv,
        use_tty,
        opts,
    );
}

pub const Error = error{NotRunning};
