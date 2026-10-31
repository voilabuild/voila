//! Parent writes uid/gid maps with newuidmap after the child unshares.
const std = @import("std");
const ns = @import("sys").ns;
const container_bind = @import("container_bind.zig");
const userns_ids = @import("userns_ids.zig");

pub fn parentApply(
    allocator: std.mem.Allocator,
    pid: std.posix.pid_t,
    up: std.posix.fd_t,
    down: std.posix.fd_t,
) userns_ids.Applied {
    const ids = userns_ids.detect(allocator, .{});
    var byte: u8 = 0;
    if (std.c.read(up, @ptrCast(&byte), 1) != 1) {
        return .{ .written = 0, .ids = userns_ids.effective(ids, 0) };
    }
    var written: u8 = 0;
    var applied: userns_ids.Applied = .{ .written = 0, .ids = userns_ids.effective(ids, 0) };
    if (ids.isRange()) {
        applied = userns_ids.applyHelpers(pid, ids, .{});
        written = applied.written;
    }
    _ = std.c.write(down, @ptrCast(&written), 1);
    return applied;
}

pub fn childEnter(up: std.posix.fd_t, down: std.posix.fd_t) bool {
    const host_uid = std.c.getuid();
    const host_gid = std.c.getgid();
    ns.unshare(ns.CLONE.NEWUSER) catch return false;
    ns.unshare(ns.CLONE.NEWNET) catch return false;
    if (std.c.write(up, "u", 1) != 1) return false;
    var written: u8 = 0;
    if (std.c.read(down, @ptrCast(&written), 1) != 1) return false;
    if (written & userns_ids.uid_written == 0 and !container_bind.writeUidMapFor(host_uid)) return false;
    if (written & userns_ids.gid_written == 0) container_bind.writeGidMapFor(host_gid);
    return true;
}
