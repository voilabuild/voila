//! Delete a container directory that holds files owned by subordinate ids.
//! `rm` as the invoking user cannot unlink those. A user namespace where this
//! process is root, with the same subuid map the container used, can.
const std = @import("std");
const fs = @import("sys").fs;
const ns = @import("sys").ns;
const container_bind = @import("container_bind.zig");
const container_map_handshake = @import("container_map_handshake.zig");
const userns_ids = @import("userns_ids.zig");

pub fn removeTree(allocator: std.mem.Allocator, path: []const u8) fs.Error!void {
    fs.removeTree(allocator, path) catch |e| switch (e) {
        error.FileNotFound => return,
        error.AccessDenied => try removeMapped(allocator, path),
        else => return e,
    };
}

fn removeMapped(allocator: std.mem.Allocator, path: []const u8) !void {
    var up: [2]std.posix.fd_t = undefined;
    var down: [2]std.posix.fd_t = undefined;
    if (std.c.pipe2(&up, .{ .CLOEXEC = true }) != 0) return error.AccessDenied;
    if (std.c.pipe2(&down, .{ .CLOEXEC = true }) != 0) {
        closeBoth(up);
        return error.AccessDenied;
    }
    const pid = std.c.fork();
    if (pid < 0) {
        closeBoth(up);
        closeBoth(down);
        return error.AccessDenied;
    }
    if (pid == 0) {
        _ = std.c.close(up[0]);
        _ = std.c.close(down[1]);
        child(path, up[1], down[0]);
    }
    _ = std.c.close(up[1]);
    _ = std.c.close(down[0]);
    defer _ = std.c.close(up[0]);
    defer _ = std.c.close(down[1]);
    _ = container_map_handshake.parentApply(allocator, pid, up[0], down[1]);
    var wst: i32 = 0;
    while (std.c.waitpid(pid, &wst, 0) < 0) {
        if (std.c.errno(-1) != .INTR) return error.AccessDenied;
    }
    const st: u32 = @bitCast(wst);
    if (std.c.W.IFEXITED(st) and std.c.W.EXITSTATUS(st) == 0) return;
    return error.AccessDenied;
}

fn child(path: []const u8, up: std.posix.fd_t, down: std.posix.fd_t) noreturn {
    const host_uid = std.c.getuid();
    const host_gid = std.c.getgid();
    ns.unshare(ns.CLONE.NEWUSER) catch std.c._exit(2);
    if (std.c.write(up, "u", 1) != 1) std.c._exit(2);
    var written: u8 = 0;
    if (std.c.read(down, @ptrCast(&written), 1) != 1) std.c._exit(2);
    if (written & userns_ids.uid_written == 0 and !container_bind.writeUidMapFor(host_uid)) std.c._exit(2);
    if (written & userns_ids.gid_written == 0) container_bind.writeGidMapFor(host_gid);
    fs.removeTree(std.heap.page_allocator, path) catch std.c._exit(3);
    std.c._exit(0);
}

fn closeBoth(fds: [2]std.posix.fd_t) void {
    _ = std.c.close(fds[0]);
    _ = std.c.close(fds[1]);
}
