const std = @import("std");
const posix_util = @import("posix_util.zig");

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

pub fn parseRootChunk(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
    if (query.len != 64) return error.BadRootHex;
    var out: [32]u8 = undefined;
    for (0..32) |i| {
        const hi = hexVal(query[i * 2]) orelse return error.BadRootHex;
        const lo = hexVal(query[i * 2 + 1]) orelse return error.BadRootHex;
        out[i] = (hi << 4) | lo;
    }
    return allocator.dupe(u8, &out);
}

fn isRootHex(query: []const u8) bool {
    if (query.len != 64) return false;
    for (query) |c| {
        if (hexVal(c) == null) return false;
    }
    return true;
}

pub fn resolveRootFromStore(allocator: std.mem.Allocator, voila_root: []const u8, image_ref: []const u8) ![]u8 {
    const tmp = "/tmp/voila-zig-root-chunk.bin";
    const cmd = try std.fmt.allocPrint(allocator,
        \\python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); r=c.execute("select merged_root_manifest_chunk from images where ref=?", (sys.argv[2],)).fetchone(); sys.exit(2 if r is None else 0); open(sys.argv[3],"wb").write(r[0])' '{s}' '{s}' '{s}'
    , .{ voila_root, image_ref, tmp });
    defer allocator.free(cmd);
    const cmd_z = try allocator.allocSentinel(u8, cmd.len, 0);
    defer allocator.free(cmd_z);
    @memcpy(cmd_z, cmd);
    if (posix_util.shell(cmd_z) != 0) return error.ResolveFailed;
    return posix_util.readFileAlloc(allocator, tmp, 64);
}

pub fn resolveRoot(allocator: std.mem.Allocator, voila_root: []const u8, query: []const u8) ![]u8 {
    if (isRootHex(query)) return parseRootChunk(allocator, query);
    return resolveRootFromStore(allocator, voila_root, query);
}

pub const Error = error{
    BadRootHex,
    ResolveFailed,
};
