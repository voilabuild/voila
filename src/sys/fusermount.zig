//! Unmounting FUSE mounts through the setuid fusermount3 helper, without a shell.
const std = @import("std");
const linux = std.os.linux;
const process = @import("process.zig");

const candidates = [_][]const u8{ "/usr/bin/fusermount3", "/bin/fusermount3", "/usr/local/bin/fusermount3" };

pub const Mode = enum { normal, lazy };

/// Unmounts `mount_dir`; true when the call succeeded. Falls back to umount2, which works
/// for root or inside the mount's own user namespace.
pub fn unmount(mount_dir: []const u8, mode: Mode) bool {
    if (mount_dir.len == 0) return false;
    const flag = switch (mode) {
        .normal => "-u",
        .lazy => "-uz",
    };
    for (candidates) |exe| {
        var zb: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
        @memcpy(zb[0..exe.len], exe);
        zb[exe.len] = 0;
        if (linux.errno(linux.access(zb[0..exe.len :0], linux.X_OK)) != .SUCCESS) continue;
        const rc = process.runQuiet(&.{ exe, flag, "--", mount_dir }) catch return umount2(mount_dir, mode);
        return rc == 0;
    }
    return umount2(mount_dir, mode);
}

fn umount2(mount_dir: []const u8, mode: Mode) bool {
    var zb: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    if (mount_dir.len >= zb.len) return false;
    @memcpy(zb[0..mount_dir.len], mount_dir);
    zb[mount_dir.len] = 0;
    const flags: u32 = if (mode == .lazy) linux.MNT.DETACH else 0;
    return linux.errno(linux.umount2(zb[0..mount_dir.len :0], flags)) == .SUCCESS;
}

test "unmounting a path that is not a mount fails without a shell" {
    try std.testing.expect(!unmount("/nonexistent/voila-fusermount-test", .normal));
    try std.testing.expect(!unmount("", .lazy));
}
