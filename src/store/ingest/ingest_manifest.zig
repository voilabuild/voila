const std = @import("std");
const tree_mod = @import("ingest_tree.zig");
const chunk_store = @import("ingest_chunk_store.zig");
const proto = @import("codec").voila_manifest_proto;

pub const manifest_split_threshold = 64 * 1024;

pub fn buildAndStoreManifest(
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    tree: *tree_mod.LayerTree,
    per_layer: bool,
) !chunk_store.ChunkId {
    const bytes = try buildManifestBytes(allocator, tree, per_layer);
    defer allocator.free(bytes);
    return chunk_store.putBytes(allocator, voila_root, bytes);
}

fn buildManifestBytes(allocator: std.mem.Allocator, tree: *tree_mod.LayerTree, per_layer: bool) ![]u8 {
    const maps = assignInodes(allocator, tree);
    const inode_of = &maps.inode_of;
    const nlink_of = &maps.nlink_of;

    var msg: proto.ManifestMsg = .{
        .dirs = &.{},
        .files = std.AutoHashMap(u64, proto.FileMsg).init(allocator),
        .symlinks = std.AutoHashMap(u64, proto.SymlinkMsg).init(allocator),
        .devices = std.AutoHashMap(u64, proto.DeviceMsg).init(allocator),
        .external_subtrees = std.AutoHashMap(u64, []const u8).init(allocator),
        .allocator = allocator,
    };
    defer msg.deinit();

    try buildDirSubtree(allocator, tree, tree.root, inode_of, nlink_of, per_layer, &msg);
    return proto.encodeManifest(allocator, msg);
}

fn buildDirSubtree(
    allocator: std.mem.Allocator,
    tree: *tree_mod.LayerTree,
    dir: *tree_mod.Node,
    inode_of: *const std.AutoHashMap(*tree_mod.Node, u64),
    nlink_of: *const std.AutoHashMap(u64, u32),
    per_layer: bool,
    msg: *proto.ManifestMsg,
) !void {
    const ino = inode_of.get(dir) orelse return;
    var entries = std.StringHashMap(u64).init(allocator);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.children.keyIterator();
    while (it.next()) |k| try names.append(allocator, k.*);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    for (names.items) |name| {
        const child = dir.children.get(name) orelse continue;
        const child_ino = inode_of.get(child) orelse continue;
        const owned_name = try allocator.dupe(u8, name);
        try entries.put(owned_name, child_ino);
        switch (child.node_type) {
            .dir => try buildDirSubtree(allocator, tree, child, inode_of, nlink_of, per_layer, msg),
            .regular => {
                var blocks: std.ArrayList(proto.BlockMsg) = .empty;
                for (child.blocks.items) |b| {
                    try blocks.append(allocator, .{
                        .offset = b.offset,
                        .chunk_id = try allocator.dupe(u8, &b.chunk_id),
                        .logical_len = b.logical_len,
                    });
                }
                var xattrs = std.StringHashMap([]const u8).init(allocator);
                var xit = child.xattrs.iterator();
                while (xit.next()) |e| {
                    const k = try allocator.dupe(u8, e.key_ptr.*);
                    const v = try allocator.dupe(u8, e.value_ptr.*);
                    try xattrs.put(k, v);
                }
                try msg.files.put(child_ino, .{
                    .inode = child_ino,
                    .mode = child.mode,
                    .uid = child.uid,
                    .gid = child.gid,
                    .size = child.size,
                    .mtime_ns = child.mtime_ns,
                    .nlink = nlink_of.get(child_ino) orelse 1,
                    .blocks = try blocks.toOwnedSlice(allocator),
                    .xattrs = xattrs,
                });
            },
            .symlink => try msg.symlinks.put(child_ino, .{
                .inode = child_ino,
                .target = try allocator.dupe(u8, child.target),
                .uid = child.uid,
                .gid = child.gid,
            }),
            .device => try msg.devices.put(child_ino, .{
                .inode = child_ino,
                .mode = child.mode,
                .uid = child.uid,
                .gid = child.gid,
                .rdev_major = child.major,
                .rdev_minor = child.minor,
                .is_char = child.char_device,
            }),
            .pending_hardlink => if (!per_layer) return error.UnresolvedHardlink,
        }
    }
    names.deinit(allocator);

    var dirs: std.ArrayList(proto.DirMsg) = .empty;
    try dirs.append(allocator, .{
        .inode = ino,
        .mode = dir.mode,
        .uid = dir.uid,
        .gid = dir.gid,
        .mtime_ns = dir.mtime_ns,
        .entries = entries,
    });
    const old = msg.dirs;
    const merged = try allocator.alloc(proto.DirMsg, old.len + 1);
    @memcpy(merged[0..old.len], old);
    merged[old.len] = dirs.items[0];
    allocator.free(old);
    msg.dirs = merged;
}

fn assignInodes(allocator: std.mem.Allocator, tree: *tree_mod.LayerTree) struct {
    inode_of: std.AutoHashMap(*tree_mod.Node, u64),
    nlink_of: std.AutoHashMap(u64, u32),
} {
    var inode_of: std.AutoHashMap(*tree_mod.Node, u64) = .init(allocator);
    var nlink_of: std.AutoHashMap(u64, u32) = .init(allocator);
    var paths: std.ArrayList([]const u8) = .empty;
    var it = tree.by_path.keyIterator();
    while (it.next()) |p| paths.append(allocator, p.*) catch {};
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var next: u64 = 1;
    for (paths.items) |p| {
        const n = tree.by_path.get(p) orelse continue;
        const gop = inode_of.getOrPut(n) catch continue;
        if (!gop.found_existing) {
            gop.value_ptr.* = next;
            next += 1;
        }
        const ino = gop.value_ptr.*;
        const nl = nlink_of.getOrPut(ino) catch continue;
        if (!nl.found_existing) nl.value_ptr.* = 0;
        nl.value_ptr.* += 1;
    }
    paths.deinit(allocator);
    return .{ .inode_of = inode_of, .nlink_of = nlink_of };
}

pub const Error = error{UnresolvedHardlink};
