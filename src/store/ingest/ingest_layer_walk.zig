const std = @import("std");
const tree_mod = @import("ingest_tree.zig");
const whiteouts = @import("ingest_whiteouts.zig");
const tar_mod = @import("ingest_tar.zig");
const chunk_store = @import("ingest_chunk_store.zig");

pub const chunk_size = voila_store_chunk_size;
const voila_store_chunk_size = @import("../voila_store.zig").ChunkSize;

pub const LayerWalkResult = struct {
    tree: *tree_mod.LayerTree,
    bytes_in: u64,
    chunk_count: u64,
    chunks_deduped: u64,
    stored_bytes: u64,
};

pub fn walkLayer(
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    layer_tar: []const u8,
) !LayerWalkResult {
    const layer_tree = try tree_mod.newTree(allocator);
    var res = LayerWalkResult{
        .tree = layer_tree,
        .bytes_in = 0,
        .chunk_count = 0,
        .chunks_deduped = 0,
        .stored_bytes = 0,
    };

    var seen: std.AutoHashMap(chunk_store.ChunkId, void) = .init(allocator);
    defer seen.deinit();

    var tr = tar_mod.TarStream.init(layer_tar);
    var chunk_buf: [chunk_size]u8 = undefined;

    while (try tr.next(allocator)) |hdr| {
        defer {
            allocator.free(hdr.name);
            allocator.free(hdr.linkname);
        }
        const clean = whiteouts.cleanEntryPath(allocator, hdr.name) catch continue;
        defer allocator.free(clean);
        const classified = whiteouts.classifyEntry(clean);
        if (classified.is_opaque) {
            recordOpaque(layer_tree, allocator, classified.parent);
            layer_tree.opaque_n += 1;
            continue;
        }
        if (classified.explicit) {
            recordWhiteout(layer_tree, allocator, classified.parent, classified.name);
            layer_tree.whiteouts_n += 1;
            continue;
        }
        if (clean.len == 0) {
            applyHeaderMeta(layer_tree.root, hdr, .dir);
            layer_tree.root.implicit = false;
            continue;
        }
        try walkEntry(allocator, voila_root, &tr, hdr, clean, layer_tree, &seen, &chunk_buf, &res);
    }
    return res;
}

fn walkEntry(
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    tr: *tar_mod.TarStream,
    hdr: tar_mod.TarHeader,
    clean: []const u8,
    layer_tree: *tree_mod.LayerTree,
    seen: *std.AutoHashMap(chunk_store.ChunkId, void),
    chunk_buf: *[chunk_size]u8,
    res: *LayerWalkResult,
) !void {
    const parts = splitPath(clean);
    const parent = ensureDir(allocator, layer_tree, parts.parent);

    switch (hdr.typeflag) {
        '0', 0 => {
            const node = try allocator.create(tree_mod.Node);
            node.* = .{
                .path = try allocator.dupe(u8, clean),
                .name = try allocator.dupe(u8, parts.base),
                .node_type = .regular,
                .mode = hdr.mode,
                .uid = hdr.uid,
                .gid = hdr.gid,
                .mtime_ns = @as(u64, @intCast(hdr.mtime)) * 1_000_000_000,
                .blocks = .empty,
                .xattrs = std.StringHashMap([]const u8).init(allocator),
                .children = std.StringHashMap(*tree_mod.Node).init(allocator),
                .allocator = allocator,
            };
            try chunkFile(allocator, voila_root, tr, hdr.size, node, seen, chunk_buf, res);
            try attachChild(allocator, parent, parts.base, node);
            try layer_tree.put(node);
        },
        '2' => {
            const node = try allocator.create(tree_mod.Node);
            node.* = .{
                .path = try allocator.dupe(u8, clean),
                .name = try allocator.dupe(u8, parts.base),
                .node_type = .symlink,
                .mode = hdr.mode,
                .uid = hdr.uid,
                .gid = hdr.gid,
                .mtime_ns = @as(u64, @intCast(hdr.mtime)) * 1_000_000_000,
                .target = try allocator.dupe(u8, hdr.linkname),
                .blocks = .empty,
                .xattrs = std.StringHashMap([]const u8).init(allocator),
                .children = std.StringHashMap(*tree_mod.Node).init(allocator),
                .allocator = allocator,
            };
            try attachChild(allocator, parent, parts.base, node);
            try layer_tree.put(node);
        },
        '5' => {
            _ = ensureDirEx(allocator, layer_tree, clean, hdr);
        },
        else => {},
    }
}

fn chunkFile(
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    tr: *tar_mod.TarStream,
    size: u64,
    node: *tree_mod.Node,
    seen: *std.AutoHashMap(chunk_store.ChunkId, void),
    _: *[chunk_size]u8,
    res: *LayerWalkResult,
) !void {
    var offset: u64 = 0;
    var remaining = size;
    while (remaining > 0) {
        const want = @min(remaining, chunk_size);
        const slice = try tr.readAll(allocator, want);
        defer allocator.free(slice);
        remaining -= slice.len;
        res.bytes_in += slice.len;
        node.size += slice.len;
        const put_res = try putChunk(allocator, voila_root, seen, slice);
        try node.blocks.append(allocator, .{
            .offset = offset,
            .chunk_id = put_res.id,
            .logical_len = slice.len,
        });
        res.chunk_count += 1;
        res.stored_bytes += put_res.stored_add;
        if (!put_res.is_new) res.chunks_deduped += 1;
        offset += slice.len;
    }
}

const PutChunkResult = struct { id: chunk_store.ChunkId, is_new: bool, stored_add: u64 };

fn putChunk(
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    seen: *std.AutoHashMap(chunk_store.ChunkId, void),
    buf: []const u8,
) !PutChunkResult {
    const id = chunk_store.hashRaw(buf);
    if (seen.contains(id)) return .{ .id = id, .is_new = false, .stored_add = 0 };
    const existed = chunk_store.chunkExists(allocator, voila_root, id);
    if (existed) {
        seen.put(id, {}) catch {};
        return .{ .id = id, .is_new = false, .stored_add = 0 };
    }
    _ = try chunk_store.putBytes(allocator, voila_root, buf);
    seen.put(id, {}) catch {};
    return .{ .id = id, .is_new = true, .stored_add = buf.len };
}

fn splitPath(clean: []const u8) struct { parent: []const u8, base: []const u8 } {
    const parent = std.fs.path.dirname(clean) orelse "";
    const base = std.fs.path.basename(clean);
    return .{
        .parent = if (std.mem.eql(u8, parent, ".")) "" else parent,
        .base = base,
    };
}

fn ensureDir(allocator: std.mem.Allocator, layer_tree: *tree_mod.LayerTree, dir_path: []const u8) *tree_mod.Node {
    if (dir_path.len == 0) return layer_tree.root;
    if (layer_tree.lookup(dir_path)) |n| return n;
    const parts = splitPath(dir_path);
    const pn = ensureDir(allocator, layer_tree, parts.parent);
    const node = allocator.create(tree_mod.Node) catch unreachable;
    node.* = .{
        .path = allocator.dupe(u8, dir_path) catch unreachable,
        .name = allocator.dupe(u8, parts.base) catch unreachable,
        .node_type = .dir,
        .mode = 0o755,
        .blocks = .empty,
        .xattrs = std.StringHashMap([]const u8).init(allocator),
        .children = std.StringHashMap(*tree_mod.Node).init(allocator),
        .implicit = true,
        .allocator = allocator,
    };
    attachChild(allocator, pn, parts.base, node) catch {};
    layer_tree.put(node) catch {};
    return node;
}

fn ensureDirEx(allocator: std.mem.Allocator, layer_tree: *tree_mod.LayerTree, clean: []const u8, hdr: tar_mod.TarHeader) *tree_mod.Node {
    if (layer_tree.lookup(clean)) |existing| {
        applyHeaderMeta(existing, hdr, .dir);
        return existing;
    }
    const parts = splitPath(clean);
    const pn = ensureDir(allocator, layer_tree, parts.parent);
    const node = allocator.create(tree_mod.Node) catch unreachable;
    node.* = .{
        .path = allocator.dupe(u8, clean) catch unreachable,
        .name = allocator.dupe(u8, parts.base) catch unreachable,
        .node_type = .dir,
        .mode = 0o755,
        .blocks = .empty,
        .xattrs = std.StringHashMap([]const u8).init(allocator),
        .children = std.StringHashMap(*tree_mod.Node).init(allocator),
        .allocator = allocator,
    };
    applyHeaderMeta(node, hdr, .dir);
    attachChild(allocator, pn, parts.base, node) catch {};
    layer_tree.put(node) catch {};
    return node;
}

fn attachChild(allocator: std.mem.Allocator, parent: *tree_mod.Node, base: []const u8, child: *tree_mod.Node) !void {
    const key = try allocator.dupe(u8, base);
    try parent.children.put(key, child);
}

fn applyHeaderMeta(n: *tree_mod.Node, hdr: tar_mod.TarHeader, t: tree_mod.NodeType) void {
    n.node_type = t;
    if (hdr.mode != 0) n.mode = hdr.mode;
    n.uid = hdr.uid;
    n.gid = hdr.gid;
    n.implicit = false;
    if (hdr.mtime != 0) {
        const mt: u64 = @intCast(hdr.mtime);
        n.mtime_ns = mt * 1_000_000_000;
    }
}

fn recordWhiteout(layer_tree: *tree_mod.LayerTree, allocator: std.mem.Allocator, parent: []const u8, name: []const u8) void {
    _ = ensureDir(allocator, layer_tree, parent);
    layer_tree.whiteouts.append(allocator, .{
        .parent = allocator.dupe(u8, parent) catch return,
        .name = allocator.dupe(u8, name) catch return,
    }) catch {};
}

fn recordOpaque(layer_tree: *tree_mod.LayerTree, allocator: std.mem.Allocator, dir: []const u8) void {
    _ = ensureDir(allocator, layer_tree, dir);
    layer_tree.opaque_dirs.append(allocator, allocator.dupe(u8, dir) catch return) catch {};
}
