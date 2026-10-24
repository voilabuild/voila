//! User-namespace id maps: container 0 is the invoking id, 1..N an `/etc/subuid` range.
const std = @import("std");

/// Kernel overflow id: what an unmapped id looks like inside a user namespace.
pub const overflow_id: u32 = 65534;

pub const Range = struct { start: u32, count: u32 };

pub const IdMap = struct {
    /// Host id that is 0 in the namespace.
    host: u32,
    /// Host ids mapped to container ids 1..count.
    sub: ?Range = null,

    pub fn toHost(self: IdMap, id: u32) ?u32 {
        if (id == 0) return self.host;
        const r = self.sub orelse return null;
        if (id - 1 >= r.count) return null;
        const h = @as(u64, r.start) + (id - 1);
        return std.math.cast(u32, h);
    }

    pub fn toContainer(self: IdMap, host_id: u32) ?u32 {
        if (host_id == self.host) return 0;
        const r = self.sub orelse return null;
        if (host_id < r.start or host_id - r.start >= r.count) return null;
        return std.math.cast(u32, @as(u64, host_id - r.start) + 1);
    }

    /// Host id a FUSE lower must report so the namespace sees `id`. A single-id map
    /// passes unmapped ids through unchanged, a range map turns them into `overflow_id`.
    pub fn lowerHostId(self: IdMap, id: u32) u32 {
        return self.toHost(id) orelse if (self.sub == null) id else overflow_id;
    }
};

pub const Mapping = struct {
    uid: IdMap,
    gid: IdMap,

    pub fn single(uid: u32, gid: u32) Mapping {
        return .{ .uid = .{ .host = uid }, .gid = .{ .host = gid } };
    }

    pub fn isRange(self: Mapping) bool {
        return self.uid.sub != null or self.gid.sub != null;
    }
};

/// First `/etc/subuid` (or `/etc/subgid`) range for the user, matched by name or numeric id.
pub fn parseSubid(text: []const u8, name: ?[]const u8, id: u32) ?Range {
    var id_buf: [16]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch unreachable;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.splitScalar(u8, line, ':');
        const owner = f.next() orelse continue;
        const start = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        const count = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        if (count == 0) continue;
        const match = std.mem.eql(u8, owner, id_str) or (name != null and std.mem.eql(u8, owner, name.?));
        if (match) return .{ .start = start, .count = count };
    }
    return null;
}

const testing = std.testing;

test "parseSubid matches by name or uid and skips junk" {
    const text =
        \\# comment
        \\alice:200000:65536
        \\bad:line
        \\1000:100000:65536
        \\nicolas:300000:0
        \\nicolas:400000:1000
    ;
    try testing.expectEqual(Range{ .start = 200000, .count = 65536 }, parseSubid(text, "alice", 1001).?);
    try testing.expectEqual(Range{ .start = 100000, .count = 65536 }, parseSubid(text, "bob", 1000).?);
    try testing.expectEqual(Range{ .start = 400000, .count = 1000 }, parseSubid(text, "nicolas", 1002).?);
    try testing.expectEqual(@as(?Range, null), parseSubid(text, null, 4242));
    try testing.expectEqual(@as(?Range, null), parseSubid("", "x", 0));
}

test "range map translates both ways" {
    const m: IdMap = .{ .host = 1000, .sub = .{ .start = 100000, .count = 65536 } };
    try testing.expectEqual(@as(?u32, 1000), m.toHost(0));
    try testing.expectEqual(@as(?u32, 100000), m.toHost(1));
    try testing.expectEqual(@as(?u32, 101233), m.toHost(1234));
    try testing.expectEqual(@as(?u32, 165535), m.toHost(65536));
    try testing.expectEqual(@as(?u32, null), m.toHost(65537));
    try testing.expectEqual(@as(?u32, 0), m.toContainer(1000));
    try testing.expectEqual(@as(?u32, 1234), m.toContainer(101233));
    try testing.expectEqual(@as(?u32, 65536), m.toContainer(165535));
    try testing.expectEqual(@as(?u32, null), m.toContainer(165536));
    try testing.expectEqual(@as(?u32, null), m.toContainer(99999));
    try testing.expectEqual(@as(u32, overflow_id), m.lowerHostId(70000));
}

test "single map keeps the legacy pass-through" {
    const m: IdMap = .{ .host = 1000 };
    try testing.expectEqual(@as(?u32, 1000), m.toHost(0));
    try testing.expectEqual(@as(?u32, null), m.toHost(1));
    try testing.expectEqual(@as(?u32, 0), m.toContainer(1000));
    try testing.expectEqual(@as(?u32, null), m.toContainer(1001));
    try testing.expectEqual(@as(u32, 33), m.lowerHostId(33));
    try testing.expect(!Mapping.single(1000, 1000).isRange());
}
