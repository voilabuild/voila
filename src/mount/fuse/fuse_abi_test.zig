const std = @import("std");
const abi = @import("./fuse_abi.zig");

test "fuse opcodes match linux uapi" {
    try std.testing.expectEqual(@as(u32, 5), abi.FUSE_READLINK);
    try std.testing.expectEqual(@as(u32, 15), abi.FUSE_READ);
}

test "fuse struct sizes match linux uapi" {
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(abi.Attr));
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(abi.EntryOut));
    try std.testing.expectEqual(@as(usize, 256), @sizeOf(abi.Statx));
    try std.testing.expectEqual(@as(usize, 288), @sizeOf(abi.StatxOut));
}
