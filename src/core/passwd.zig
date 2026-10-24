//! `/etc/passwd` and `/etc/group` lookups for `COPY --chown=user[:group]`.
const std = @import("std");

pub const Ids = struct { uid: u32, gid: u32 };

pub const Error = error{ UnknownUser, UnknownGroup };

/// uid and primary gid of `name`; null when absent or malformed.
pub fn findUser(passwd: []const u8, name: []const u8) ?Ids {
    var lines = std.mem.splitScalar(u8, passwd, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, ':');
        const n = f.next() orelse continue;
        if (!std.mem.eql(u8, n, name)) continue;
        _ = f.next();
        const uid = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        const gid = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        return .{ .uid = uid, .gid = gid };
    }
    return null;
}

pub fn findGroup(group: []const u8, name: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, group, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, ':');
        const n = f.next() orelse continue;
        if (!std.mem.eql(u8, n, name)) continue;
        _ = f.next();
        return std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
    }
    return null;
}

/// Docker semantics: numeric parts are taken as is; `user` alone uses the user's primary
/// group (numeric `uid` alone uses gid = uid); empty means root.
pub fn resolve(spec: []const u8, passwd: []const u8, group: []const u8) Error!Ids {
    if (spec.len == 0) return .{ .uid = 0, .gid = 0 };
    const colon = std.mem.indexOfScalar(u8, spec, ':');
    const user = spec[0 .. colon orelse spec.len];
    var ids: Ids = undefined;
    if (std.fmt.parseInt(u32, user, 10)) |uid| {
        ids = .{ .uid = uid, .gid = uid };
    } else |_| {
        ids = findUser(passwd, user) orelse return error.UnknownUser;
    }
    if (colon) |c| {
        const g = spec[c + 1 ..];
        ids.gid = std.fmt.parseInt(u32, g, 10) catch findGroup(group, g) orelse return error.UnknownGroup;
    }
    return ids;
}

const testing = std.testing;

const sample_passwd =
    \\root:x:0:0:root:/root:/bin/sh
    \\# comment
    \\bad:x:notanumber:1::
    \\app:x:1000:2000:App:/home/app:/bin/sh
    \\short:x
;
const sample_group =
    \\root:x:0:
    \\staff:x:50:app
    \\bad:x:zz:
;

test "resolve names, numbers and mixes" {
    try testing.expectEqual(Ids{ .uid = 0, .gid = 0 }, try resolve("", sample_passwd, sample_group));
    try testing.expectEqual(Ids{ .uid = 1000, .gid = 2000 }, try resolve("app", sample_passwd, sample_group));
    try testing.expectEqual(Ids{ .uid = 1000, .gid = 50 }, try resolve("app:staff", sample_passwd, sample_group));
    try testing.expectEqual(Ids{ .uid = 1000, .gid = 7 }, try resolve("app:7", sample_passwd, sample_group));
    try testing.expectEqual(Ids{ .uid = 5, .gid = 50 }, try resolve("5:staff", sample_passwd, sample_group));
    try testing.expectEqual(Ids{ .uid = 5, .gid = 5 }, try resolve("5", sample_passwd, ""));
    try testing.expectEqual(Ids{ .uid = 0, .gid = 0 }, try resolve("root:root", sample_passwd, sample_group));
}

test "resolve reports unknown or malformed entries" {
    try testing.expectError(error.UnknownUser, resolve("nobody", sample_passwd, sample_group));
    try testing.expectError(error.UnknownUser, resolve("bad", sample_passwd, sample_group));
    try testing.expectError(error.UnknownUser, resolve("short", sample_passwd, sample_group));
    try testing.expectError(error.UnknownGroup, resolve("app:nope", sample_passwd, sample_group));
    try testing.expectError(error.UnknownGroup, resolve("app:bad", sample_passwd, sample_group));
    try testing.expectError(error.UnknownUser, resolve("app", "", ""));
}
