//! Enter the FUSE rootfs (rootless user+mount namespace) so image ELF loaders resolve.
const std = @import("std");

const MS_BIND: usize = 4096;
const MS_REC: usize = 16384;

extern "c" fn mount(
    source: ?[*:0]const u8,
    target: [*:0]const u8,
    filesystemtype: ?[*:0]const u8,
    mountflags: usize,
    data: ?*anyopaque,
) c_int;

extern "c" fn chroot(path: [*:0]const u8) c_int;

pub fn enterRootfs(mount_dir: []const u8) !void {
    try bindHost("/proc", mount_dir, "/proc");
    bindHost("/dev", mount_dir, "/dev") catch {};
    bindHost("/sys", mount_dir, "/sys") catch {};
    const root_z = try allocZ(mount_dir);
    defer std.heap.page_allocator.free(root_z);
    if (chroot(root_z) != 0) return error.ChrootFailed;
    _ = std.c.chdir("/");
}

fn bindHost(host_src: []const u8, mount_dir: []const u8, in_image: []const u8) !void {
    const target = try std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}", .{ mount_dir, in_image });
    defer std.heap.page_allocator.free(target);
    try ensureDir(target);
    const src_z = try allocZ(host_src);
    defer std.heap.page_allocator.free(src_z);
    const tgt_z = try allocZ(target);
    defer std.heap.page_allocator.free(tgt_z);
    if (mount(src_z, tgt_z, null, MS_BIND | MS_REC, null) != 0) return error.BindMountFailed;
}

fn ensureDir(path: []const u8) !void {
    const path_z = try allocZ(path);
    defer std.heap.page_allocator.free(path_z);
    const rc = std.c.mkdir(path_z, 0o755);
    if (rc == 0 or std.c.errno(-1) == .EXIST) return;
    return error.MkdirFailed;
}

fn allocZ(s: []const u8) ![:0]const u8 {
    const out = try std.heap.page_allocator.allocSentinel(u8, s.len, 0);
    @memcpy(out, s);
    return out;
}

pub const Error = error{
    BindMountFailed,
    ChrootFailed,
    MkdirFailed,
};
