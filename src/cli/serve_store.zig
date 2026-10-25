const std = @import("std");
const command = @import("command.zig");
const flags = @import("flags.zig");
const fuse_vfs_mod = @import("mount").fuse.fuse_vfs;
const voila_vfs_mod = @import("mount").fuse.voila_vfs;
const fuse_linux = @import("mount").fuse.fuse_linux;
const voila_loader = @import("runtime").voila_loader;
const voila_registry = @import("registry").voila_registry;
const voila_registry_creds = @import("registry").voila_registry_creds;
const voila_fetch_stats = @import("registry").voila_fetch_stats;
const voila_login_creds = @import("registry").voila_login_creds;

pub fn execute(ctx: command.Ctx) !void {
    const gpa = ctx.gpa();
    const voila_root = ctx.args.next() orelse return error.NeedVoilaRoot;
    const image = ctx.args.next() orelse return error.NeedImage;
    const mountpoint = ctx.args.next() orelse return error.NeedMountpoint;
    const stats_path_arg = ctx.args.next();
    const voila_root_abs = try flags.resolveAbs(gpa, voila_root);
    defer gpa.free(voila_root_abs);
    voila_registry.setIo(ctx.io, gpa);
    try voila_login_creds.loadIntoHub(gpa);
    try voila_registry_creds.loadFromCredsFile(gpa, voila_root_abs);
    try voila_registry.loadFromEnv(gpa);
    voila_fetch_stats.init(gpa, stats_path_arg);
    defer voila_fetch_stats.writeStatsFile();
    const chunks_arg = ctx.args.next();
    const bytes_arg = ctx.args.next();
    if (chunks_arg) |c| {
        const chunks = std.fmt.parseInt(u64, c, 10) catch 0;
        var bytes: u64 = 0;
        if (bytes_arg) |b| bytes = std.fmt.parseInt(u64, b, 10) catch 0;
        voila_fetch_stats.setImageTotals(chunks, bytes);
    }
    const tree = try voila_loader.loadTreeRoot(ctx.io, gpa, voila_root_abs, image);
    var fuse_vfs: fuse_vfs_mod.FuseVfs = .{ .voila = voila_vfs_mod.VoilaVfs.initFromTree(gpa, tree) };
    defer fuse_vfs.deinit();
    try fuse_linux.mountAndServe(ctx.io, gpa, &fuse_vfs, mountpoint);
}
