//! Resolve a Dockerfile `USER user[:group]` against an image's /etc/passwd and /etc/group.
const std = @import("std");

pub const Cred = struct {
    uid: u32,
    gid: u32,
    /// Supplementary groups, primary gid first.
    groups: []const u32,
    home: ?[]const u8 = null,
};

pub const Error = error{ UnknownUser, UnknownGroup, OutOfMemory };

const Entry = struct { name: []const u8, id: u32, gid: u32, home: []const u8, members: []const u8 };

/// passwd: `name:pw:uid:gid:gecos:home:shell`; group: `name:pw:gid:members`.
fn entries(text: []const u8, comptime is_group: bool) EntryIter(is_group) {
    return .{ .lines = std.mem.tokenizeScalar(u8, text, '\n') };
}

fn EntryIter(comptime is_group: bool) type {
    return struct {
        lines: std.mem.TokenIterator(u8, .scalar),

        fn next(self: *@This()) ?Entry {
            while (self.lines.next()) |raw| {
                const line = std.mem.trimEnd(u8, raw, "\r");
                if (line.len == 0 or line[0] == '#') continue;
                var f = std.mem.splitScalar(u8, line, ':');
                const name = f.next() orelse continue;
                _ = f.next() orelse continue;
                const id = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
                if (is_group) return .{ .name = name, .id = id, .gid = id, .home = "", .members = f.next() orelse "" };
                const gid = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
                _ = f.next();
                return .{ .name = name, .id = id, .gid = gid, .home = f.next() orelse "", .members = "" };
            }
            return null;
        }
    };
}

fn findUser(passwd: []const u8, spec: []const u8, numeric: ?u32) ?Entry {
    var it = entries(passwd, false);
    while (it.next()) |e| {
        if (numeric) |n| {
            if (e.id == n) return e;
        } else if (std.mem.eql(u8, e.name, spec)) return e;
    }
    return null;
}

pub fn nameForUid(passwd: []const u8, uid: u32) ?[]const u8 {
    const e = findUser(passwd, "", uid) orelse return null;
    return e.name;
}

fn resolveGroup(group: []const u8, spec: []const u8) Error!u32 {
    if (std.fmt.parseInt(u32, spec, 10)) |n| return n else |_| {}
    var it = entries(group, true);
    while (it.next()) |e| if (std.mem.eql(u8, e.name, spec)) return e.id;
    return error.UnknownGroup;
}

fn isMember(members: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, members, ", ");
    while (it.next()) |m| if (std.mem.eql(u8, m, name)) return true;
    return false;
}

/// Docker semantics: numeric ids need no passwd entry (gid then defaults to 0); names must
/// exist. Without an explicit group, the user's /etc/group memberships are added.
pub fn resolve(a: std.mem.Allocator, spec: []const u8, passwd: []const u8, group: []const u8) Error!Cred {
    const colon = std.mem.indexOfScalar(u8, spec, ':');
    const user_part = spec[0 .. colon orelse spec.len];
    const numeric = std.fmt.parseInt(u32, user_part, 10) catch null;
    const entry = findUser(passwd, user_part, numeric);
    if (entry == null and numeric == null) return error.UnknownUser;
    const uid = numeric orelse entry.?.id;
    var groups: std.ArrayList(u32) = .empty;
    if (colon) |c| {
        try groups.append(a, try resolveGroup(group, spec[c + 1 ..]));
    } else {
        try groups.append(a, if (entry) |e| e.gid else 0);
        if (entry) |e| {
            var it = entries(group, true);
            while (it.next()) |g| {
                if (std.mem.indexOfScalar(u32, groups.items, g.id) != null) continue;
                if (isMember(g.members, e.name)) try groups.append(a, g.id);
            }
        }
    }
    return .{
        .uid = uid,
        .gid = groups.items[0],
        .groups = try groups.toOwnedSlice(a),
        .home = if (entry) |e| if (e.home.len > 0) e.home else null else null,
    };
}

const testing = std.testing;

const passwd_fixture =
    \\root:x:0:0:root:/root:/bin/sh
    \\# comment
    \\app:x:1000:1000::/home/app:/bin/sh
    \\_apt:x:42:65534::/nonexistent:/usr/sbin/nologin
;
const group_fixture =
    \\root:x:0:
    \\app:x:1000:
    \\audio:x:29:app,other
    \\staff:x:50:other
;

test "resolve names, numbers and groups like Docker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const app = try resolve(a, "app", passwd_fixture, group_fixture);
    try testing.expectEqual(@as(u32, 1000), app.uid);
    try testing.expectEqual(@as(u32, 1000), app.gid);
    try testing.expectEqualSlices(u32, &.{ 1000, 29 }, app.groups);
    try testing.expectEqualStrings("/home/app", app.home.?);

    const num = try resolve(a, "1234", passwd_fixture, group_fixture);
    try testing.expectEqual(@as(u32, 1234), num.uid);
    try testing.expectEqual(@as(u32, 0), num.gid);
    try testing.expectEqual(@as(?[]const u8, null), num.home);

    const by_uid = try resolve(a, "1000", passwd_fixture, group_fixture);
    try testing.expectEqual(@as(u32, 1000), by_uid.gid);

    const explicit = try resolve(a, "app:staff", passwd_fixture, group_fixture);
    try testing.expectEqualSlices(u32, &.{50}, explicit.groups);
    try testing.expectEqual(@as(u32, 7), (try resolve(a, "1234:7", "", "")).gid);

    try testing.expectError(error.UnknownUser, resolve(a, "nobody", passwd_fixture, group_fixture));
    try testing.expectError(error.UnknownGroup, resolve(a, "app:nogroup", passwd_fixture, group_fixture));
    try testing.expectEqualStrings("_apt", nameForUid(passwd_fixture, 42).?);
    try testing.expectEqual(@as(?[]const u8, null), nameForUid(passwd_fixture, 7));
}
