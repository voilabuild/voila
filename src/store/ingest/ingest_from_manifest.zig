//! Rebuild a mutable `LayerTree` from a stored merged root manifest (metadata only).
const std = @import("std");
const voila_tree = @import("../../core/voila_tree.zig");
const tree_mod = @import("ingest_tree.zig");
const layer_walk = @import("ingest_layer_walk.zig");

/// Loads every subtree manifest of `root_chunk`; file data chunks are not touched.
/// Use an arena: nodes follow the ingest ownership model.
pub fn loadTree(allocator: std.mem.Allocator, voila_root: []const u8, root_chunk: [32]u8) !*tree_mod.LayerTree {
    var src = try voila_tree.openTreeEager(allocator, voila_root, &root_chunk);
    defer src.deinit();
    const out = try tree_mod.newTree(allocator);
    var by_ino: std.AutoHashMap(u64, *tree_mod.Node) = .init(allocator);
    defer by_ino.deinit();
    const root_dir = src.dir_by_inode.get(src.root_ino) orelse return error.NoRootDir;
    setDirMeta(out.root, root_dir);
    try fillDir(allocator, &src, out, out.root, src.root_ino, &by_ino);
    return out;
}

fn setDirMeta(node: *tree_mod.Node, d: anytype) void {
    node.mode = d.mode;
    node.uid = d.uid;
    node.gid = d.gid;
    node.mtime_ns = d.mtime_ns;
    node.implicit = false;
}

fn fillDir(
    allocator: std.mem.Allocator,
    src: *voila_tree.Tree,
    out: *tree_mod.LayerTree,
    dir_node: *tree_mod.Node,
    dir_ino: u64,
    by_ino: *std.AutoHashMap(u64, *tree_mod.Node),
) !void {
    const d = src.dir_by_inode.get(dir_ino) orelse return error.InodeNotFound;
    var it = d.entries.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        const ino = e.value_ptr.*;
        try src.ensureInode(ino);
        const path = if (dir_node.path.len == 0)
            try allocator.dupe(u8, name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_node.path, name });

        if (by_ino.get(ino)) |existing| {
            try layer_walk.attachChild(allocator, dir_node, name, existing);
            try out.by_path.put(path, existing);
            continue;
        }
        const node = try allocator.create(tree_mod.Node);
        node.* = .{
            .path = path,
            .name = try allocator.dupe(u8, name),
            .node_type = .dir,
            .blocks = .empty,
            .xattrs = std.StringHashMap([]const u8).init(allocator),
            .children = std.StringHashMap(*tree_mod.Node).init(allocator),
            .allocator = allocator,
        };
        try layer_walk.attachChild(allocator, dir_node, name, node);
        try out.put(node);

        if (src.dir_by_inode.get(ino)) |sub| {
            setDirMeta(node, sub);
            try fillDir(allocator, src, out, node, ino, by_ino);
        } else if (src.file_by_inode.get(ino)) |f| {
            node.node_type = .regular;
            node.mode = f.mode;
            node.uid = f.uid;
            node.gid = f.gid;
            node.mtime_ns = f.mtime_ns;
            node.size = f.size;
            for (f.blocks) |b| {
                if (b.chunk_id.len != 32) return error.BadChunkId;
                try node.blocks.append(allocator, .{ .offset = b.offset, .chunk_id = b.chunk_id[0..32].*, .logical_len = b.logical_len });
            }
            var xit = f.xattrs.iterator();
            while (xit.next()) |x| try node.xattrs.put(try allocator.dupe(u8, x.key_ptr.*), try allocator.dupe(u8, x.value_ptr.*));
            if (f.nlink > 1) try by_ino.put(ino, node);
        } else if (src.symlink_by_inode.get(ino)) |l| {
            node.node_type = .symlink;
            node.mode = 0o777;
            node.uid = l.uid;
            node.gid = l.gid;
            node.target = try allocator.dupe(u8, l.target);
        } else if (src.device_by_inode.get(ino)) |dv| {
            node.node_type = .device;
            node.mode = dv.mode;
            node.uid = dv.uid;
            node.gid = dv.gid;
            node.major = dv.rdev_major;
            node.minor = dv.rdev_minor;
            node.char_device = dv.is_char;
        } else return error.InodeNotFound;
    }
}

pub const Error = error{ NoRootDir, InodeNotFound, BadChunkId };
