const command = @import("command.zig");
const fuse_vfs_mod = @import("mount").fuse.fuse_vfs;
const voila_vfs_mod = @import("mount").fuse.voila_vfs;
const fuse_linux = @import("mount").fuse.fuse_linux;

pub fn execute(ctx: command.Ctx) !void {
    const gpa = ctx.gpa();
    const index_path = ctx.args.next() orelse return error.NeedIndex;
    const mountpoint = ctx.args.next() orelse return error.NeedMountpoint;
    var voila_vfs = try voila_vfs_mod.VoilaVfs.load(gpa, index_path);
    defer voila_vfs.deinit();
    var fuse_vfs: fuse_vfs_mod.FuseVfs = .{ .voila = voila_vfs };
    try fuse_linux.mountAndServe(ctx.io, gpa, &fuse_vfs, mountpoint);
}
