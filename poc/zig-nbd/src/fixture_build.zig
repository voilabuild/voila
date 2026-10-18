//! In-memory manifest matching poc/zig-nbd/fixture/main.go (E2E boundary tree).
const std = @import("std");
const voila_manifest_proto = @import("manifest/voila_manifest_proto.zig");
const voila_tree = @import("voila_tree.zig");
const erofs_build = @import("erofs_build.zig");

const ChunkSize = erofs_build.ChunkSize;

pub fn buildBoundaryFixture(allocator: std.mem.Allocator) !erofs_build.BuildResult {
    var tree: voila_tree.Tree = .{
        .voila_root = try allocator.dupe(u8, ""),
        .allocator = allocator,
        .manifest_hex_loaded = std.StringHashMap(void).init(allocator),
        .manifest_hex_failed = std.StringHashMap(void).init(allocator),
        .dir_by_inode = std.AutoHashMap(u64, voila_manifest_proto.DirMsg).init(allocator),
        .file_by_inode = std.AutoHashMap(u64, voila_manifest_proto.FileMsg).init(allocator),
        .symlink_by_inode = std.AutoHashMap(u64, voila_manifest_proto.SymlinkMsg).init(allocator),
        .device_by_inode = std.AutoHashMap(u64, voila_manifest_proto.DeviceMsg).init(allocator),
        .external_subtrees = std.AutoHashMap(u64, []const u8).init(allocator),
        .root_ino = 1,
    };
    defer tree.deinit();

    var root_entries = std.StringHashMap(u64).init(allocator);
    try root_entries.put(try allocator.dupe(u8, "a.bin"), 2);
    try root_entries.put(try allocator.dupe(u8, "b.bin"), 3);
    try root_entries.put(try allocator.dupe(u8, "c.bin"), 4);

    try tree.dir_by_inode.put(1, .{
        .inode = 1,
        .mode = 0o755,
        .uid = 0,
        .gid = 0,
        .mtime_ns = 0,
        .entries = root_entries,
    });

    const id_a = chunkId(0xAA);
    const id_b = chunkId(0xBB);
    const id_c = chunkId(0xCC);

    try putFile(&tree, 2, id_a, ChunkSize);
    try putFile(&tree, 3, id_b, ChunkSize);
    try putFileTwoBlocks(&tree, 4, id_a, id_c);

    return erofs_build.build(allocator, &tree);
}

fn chunkId(fill: u8) []const u8 {
    // Deterministic fake ids (32 bytes); slot assignment only needs uniqueness.
    const ids = [_][]const u8{
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "cccccccccccccccccccccccccccccccc",
    };
    return if (fill == 0xAA) ids[0] else if (fill == 0xBB) ids[1] else ids[2];
}

fn putFile(tree: *voila_tree.Tree, ino: u64, cid: []const u8, size: u64) !void {
    const owned = try tree.allocator.dupe(u8, cid);
    const blocks = try tree.allocator.alloc(voila_manifest_proto.BlockMsg, 1);
    blocks[0] = .{
        .offset = 0,
        .chunk_id = owned,
        .logical_len = size,
    };
    try tree.file_by_inode.put(ino, .{
        .inode = ino,
        .mode = 0o644,
        .uid = 0,
        .gid = 0,
        .size = size,
        .mtime_ns = 0,
        .nlink = 1,
        .blocks = blocks,
    });
}

fn putFileTwoBlocks(tree: *voila_tree.Tree, ino: u64, cid0: []const u8, cid1: []const u8) !void {
    const o0 = try tree.allocator.dupe(u8, cid0);
    const o1 = try tree.allocator.dupe(u8, cid1);
    const blocks = try tree.allocator.alloc(voila_manifest_proto.BlockMsg, 2);
    blocks[0] = .{ .offset = 0, .chunk_id = o0, .logical_len = ChunkSize };
    blocks[1] = .{ .offset = ChunkSize, .chunk_id = o1, .logical_len = ChunkSize };
    try tree.file_by_inode.put(ino, .{
        .inode = ino,
        .mode = 0o644,
        .uid = 0,
        .gid = 0,
        .size = 2 * ChunkSize,
        .mtime_ns = 0,
        .nlink = 1,
        .blocks = blocks,
    });
}
