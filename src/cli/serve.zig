const command = @import("command.zig");
const flags = @import("flags.zig");
const vfs_mod = @import("mount").fuse.vfs;
const fuse_vfs_mod = @import("mount").fuse.fuse_vfs;
const fuse_linux = @import("mount").fuse.fuse_linux;

pub fn execute(ctx: command.Ctx) !void {
    const gpa = ctx.gpa();
    const fixture_dir = ctx.args.next() orelse "fixture-out";
    const mountpoint = ctx.args.next() orelse return error.NeedMountpoint;
    const fixture_abs = try flags.resolveAbs(gpa, fixture_dir);
    defer gpa.free(fixture_abs);
    var fixture_vfs = try vfs_mod.Vfs.load(gpa, fixture_abs);
    defer fixture_vfs.deinit();
    try fixture_vfs.preloadAllChunks(ctx.io);
    var fuse_vfs: fuse_vfs_mod.FuseVfs = .{ .fixture = fixture_vfs };
    try fuse_linux.mountAndServe(ctx.io, gpa, &fuse_vfs, mountpoint);
}
