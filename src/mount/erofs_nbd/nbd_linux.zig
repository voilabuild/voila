const std = @import("std");
const posix_util = @import("./posix_util.zig");
const nbd_blocking = @import("./nbd_blocking.zig");
const backend = @import("./backend.zig");
const constants = @import("./constants.zig");

pub fn attachAndServe(io: std.Io, dev: *backend.Device, nbd_path: []const u8, connected: ?*std.atomic.Value(bool)) !void {
    return nbd_blocking.attachAndServe(io, dev, nbd_path, connected);
}

pub fn disconnect(nbd_path: []const u8) void {
    nbd_blocking.disconnect(nbd_path);
}

pub fn canUseNBD(nbd_path: []const u8) bool {
    if (std.os.linux.getuid() != 0) return false;
    return posix_util.access(nbd_path);
}
