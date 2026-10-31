//! Apply image `USER` after pivot: `/etc/passwd` lookup and `setresuid`.
const std = @import("std");
const passwd = @import("core").passwd;
const process = @import("sys").process;
const posix_util = @import("sys").posix_util;

pub fn resolve(user: []const u8) ?passwd.Cred {
    if (user.len == 0) return null;
    const a = std.heap.page_allocator;
    const pw = posix_util.readFileAlloc(a, "/etc/passwd", 1 << 20) catch "";
    const gr = posix_util.readFileAlloc(a, "/etc/group", 1 << 20) catch "";
    return passwd.resolveCred(a, user, pw, gr) catch {
        std.debug.print("voila: warning: USER {s} is missing from the image; running as root\n", .{user});
        return null;
    };
}

pub fn apply(cred: ?passwd.Cred) void {
    const c = cred orelse return;
    var buf: [64]u32 = undefined;
    const n = @min(c.groups.len, buf.len);
    @memcpy(buf[0..n], c.groups[0..n]);
    process.switchUser(c.uid, c.gid, buf[0..n]) catch {
        std.debug.print("voila: warning: USER is not mapped; running as root\n", .{});
    };
}
