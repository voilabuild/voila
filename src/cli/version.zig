const std = @import("std");
const voila_version = @import("voila_version");
const posix_util = @import("sys").posix_util;

pub fn line() []const u8 {
    return std.fmt.comptimePrint("voila {s} ({s})", .{ voila_version.version, voila_version.commit });
}

pub fn print() void {
    posix_util.printOut("{s}\n", .{line()});
}

test "version line names the binary" {
    try std.testing.expect(std.mem.startsWith(u8, line(), "voila "));
}
