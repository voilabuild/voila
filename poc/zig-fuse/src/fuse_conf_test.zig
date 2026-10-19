const std = @import("std");
const fuse_linux = @import("fuse_linux.zig");

test "fuse.conf user_allow_other parsing" {
    try std.testing.expect(!fuse_linux.fuseConfUserAllowOtherFromBytes("# user_allow_other\n"));
    try std.testing.expect(fuse_linux.fuseConfUserAllowOtherFromBytes("user_allow_other\n"));
    try std.testing.expect(fuse_linux.fuseConfUserAllowOtherFromBytes("  user_allow_other  \n# mount_max = 1000\n"));
}
