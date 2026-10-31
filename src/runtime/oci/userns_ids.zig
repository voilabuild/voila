//! Rootless id ranges: pick the user's /etc/subuid range and write it with newuidmap/newgidmap.
const std = @import("std");
const idmap = @import("core").idmap;
const passwd = @import("core").passwd;
const posix_util = @import("sys").posix_util;
const process = @import("sys").process;

pub const Paths = struct {
    subuid: []const u8 = "/etc/subuid",
    subgid: []const u8 = "/etc/subgid",
    passwd: []const u8 = "/etc/passwd",
    newuidmap: []const u8 = "/usr/bin/newuidmap",
    newgidmap: []const u8 = "/usr/bin/newgidmap",
};

/// The mapping a rootless namespace will get: a subid range where both the helper and
/// an entry exist, else the single invoking id.
pub fn detect(a: std.mem.Allocator, paths: Paths) idmap.Mapping {
    const uid = std.os.linux.getuid();
    const gid = std.os.linux.getgid();
    var m = idmap.Mapping.single(uid, gid);
    const pw = posix_util.readFileAlloc(a, paths.passwd, 4 << 20) catch null;
    defer if (pw) |p| a.free(p);
    const name = if (pw) |p| passwd.nameForUid(p, uid) else null;
    m.uid.sub = lookup(a, paths.newuidmap, paths.subuid, name, uid);
    m.gid.sub = lookup(a, paths.newgidmap, paths.subgid, name, uid);
    return m;
}

fn lookup(a: std.mem.Allocator, helper: []const u8, file: []const u8, name: ?[]const u8, uid: u32) ?idmap.Range {
    if (!posix_util.access(helper)) return null;
    const text = posix_util.readFileAlloc(a, file, 4 << 20) catch return null;
    defer a.free(text);
    return idmap.parseSubid(text, name, uid);
}

/// Bits of `applyHelpers`' result: which maps the helpers wrote.
pub const uid_written: u8 = 1;
pub const gid_written: u8 = 2;

pub const Applied = struct { written: u8, ids: idmap.Mapping };

/// Run from the parent once `pid` has unshared its user namespace. Returns the maps that
/// were written and the mapping now in effect; the child writes single-id maps for the rest.
pub fn applyHelpers(pid: std.posix.pid_t, want: idmap.Mapping, paths: Paths) Applied {
    var written: u8 = 0;
    if (want.uid.sub != null and runHelper(paths.newuidmap, pid, want.uid)) written |= uid_written;
    if (want.gid.sub != null and runHelper(paths.newgidmap, pid, want.gid)) written |= gid_written;
    return .{ .written = written, .ids = effective(want, written) };
}

/// Mapping in effect once the helpers in `written` succeeded; the rest is single-id.
pub fn effective(want: idmap.Mapping, written: u8) idmap.Mapping {
    var got = idmap.Mapping.single(want.uid.host, want.gid.host);
    if (written & uid_written != 0) got.uid = want.uid;
    if (written & gid_written != 0) got.gid = want.gid;
    return got;
}

fn runHelper(helper: []const u8, pid: std.posix.pid_t, m: idmap.IdMap) bool {
    const r = m.sub orelse return false;
    var bufs: [4][16]u8 = undefined;
    const args = [_][]const u8{
        helper,
        std.fmt.bufPrint(&bufs[0], "{d}", .{pid}) catch return false,
        "0",
        std.fmt.bufPrint(&bufs[1], "{d}", .{m.host}) catch return false,
        "1",
        "1",
        std.fmt.bufPrint(&bufs[2], "{d}", .{r.start}) catch return false,
        std.fmt.bufPrint(&bufs[3], "{d}", .{r.count}) catch return false,
    };
    const code = process.run(&args) catch return false;
    return code == 0;
}

test "effective keeps only the ranges whose helper succeeded" {
    const want: idmap.Mapping = .{
        .uid = .{ .host = 1000, .sub = .{ .start = 100000, .count = 65536 } },
        .gid = .{ .host = 1000, .sub = .{ .start = 100000, .count = 65536 } },
    };
    try std.testing.expect(!effective(want, 0).isRange());
    const uid_only = effective(want, uid_written);
    try std.testing.expect(uid_only.uid.sub != null and uid_only.gid.sub == null);
    try std.testing.expectEqual(want, effective(want, uid_written | gid_written));
}
