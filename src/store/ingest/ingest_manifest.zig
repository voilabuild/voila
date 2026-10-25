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
    const bytes = try buildManifestBytes(allocator, voila_root, tree, per_layer);
    defer allocator.free(bytes);
    return chunk_store.putBytes(allocator, voila_root, bytes);
}

fn buildManifestBytes(
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    tree: *tree_mod.LayerTree,
    per_layer: bool,
) ![]u8 {
    var maps = assignInodes(allocator, tree);
    defer maps.inode_of.deinit();
    defer maps.nlink_of.deinit();

    var b: ManifestBuilder = .{
        .allocator = allocator,
        .voila_root = voila_root,
        .inode_of = &maps.inode_of,
        .nlink_of = &maps.nlink_of,
        .per_layer = per_layer,
    };
    var built = try b.buildForDir(tree.root);
    defer built.manifest.deinit();
    defer allocator.free(built.data);
    return proto.encodeManifest(allocator, built.manifest);
}

const ManifestBuilder = struct {
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    inode_of: *std.AutoHashMap(*tree_mod.Node, u64),
    nlink_of: *std.AutoHashMap(u64, u32),
    per_layer: bool,

    const BuiltDir = struct {
        manifest: proto.ManifestMsg,
        data: []const u8,
    };

    const ChildBuildResult = struct {
        node: *tree_mod.Node,
        manifest: proto.ManifestMsg,
        data: []u8,

        fn deinit(self: *ChildBuildResult, allocator: std.mem.Allocator) void {
            self.manifest.deinit();
            allocator.free(self.data);
        }
    };

    fn buildForDir(self: *ManifestBuilder, dir: *tree_mod.Node) !BuiltDir {
        const child_dirs = try sortedChildDirs(self.allocator, dir);
        defer self.allocator.free(child_dirs);

        var children: std.ArrayList(ChildBuildResult) = .empty;
        for (child_dirs) |c| {
            const built = try self.buildForDir(c);
            const data = try self.allocator.dupe(u8, built.data);
            try children.append(self.allocator, .{
                .node = c,
                .manifest = built.manifest,
                .data = data,
            });
            self.allocator.free(built.data);
        }
        defer {
            for (children.items) |*ch| ch.deinit(self.allocator);
            children.deinit(self.allocator);
        }

        var inlined = std.AutoHashMap(*tree_mod.Node, void).init(self.allocator);
        defer inlined.deinit();
        for (children.items) |ch| try inlined.put(ch.node, {});

        var external_chunk: std.AutoHashMap(*tree_mod.Node, []const u8) = .init(self.allocator);
        defer {
            var it = external_chunk.iterator();
            while (it.next()) |e| self.allocator.free(e.value_ptr.*);
            external_chunk.deinit();
        }

        var result = try self.assembleDir(dir, &children, &inlined, &external_chunk);

        while (result.data.len > manifest_split_threshold) {
            const best = pickLargestInlinedChild(&children, &inlined) orelse break;
            if (self.voila_root.len == 0) break;
            const ch = childByNode(&children, best) orelse break;
            const chunk_id = try chunk_store.putBytes(self.allocator, self.voila_root, ch.data);
            const owned = try self.allocator.dupe(u8, &chunk_id);
            try external_chunk.put(best, owned);
            _ = inlined.remove(best);
            result.manifest.deinit();
            self.allocator.free(result.data);
            result = try self.assembleDir(dir, &children, &inlined, &external_chunk);
        }
        const out_data = try self.allocator.dupe(u8, result.data);
        self.allocator.free(result.data);
        return .{ .manifest = result.manifest, .data = out_data };
    }

    fn assembleDir(
        self: *ManifestBuilder,
        dir: *tree_mod.Node,
        children: *const std.ArrayList(ChildBuildResult),
        inlined: *const std.AutoHashMap(*tree_mod.Node, void),
        external_chunk: *const std.AutoHashMap(*tree_mod.Node, []const u8),
    ) !BuiltDir {
        var msg: proto.ManifestMsg = .{
            .dirs = &.{},
            .files = std.AutoHashMap(u64, proto.FileMsg).init(self.allocator),
            .symlinks = std.AutoHashMap(u64, proto.SymlinkMsg).init(self.allocator),
            .devices = std.AutoHashMap(u64, proto.DeviceMsg).init(self.allocator),
            .external_subtrees = std.AutoHashMap(u64, []const u8).init(self.allocator),
            .allocator = self.allocator,
        };
        errdefer msg.deinit();

        const ino = self.inode_of.get(dir) orelse return error.InodeNotFound;
        var entries = std.StringHashMap(u64).init(self.allocator);
        const names = try sortedNames(self.allocator, dir);
        defer {
            for (names) |n| self.allocator.free(n);
            self.allocator.free(names);
        }
        for (names) |name| {
            const child = dir.children.get(name) orelse continue;
            const child_ino = self.inode_of.get(child) orelse continue;
            const owned_name = try self.allocator.dupe(u8, name);
            try entries.put(owned_name, child_ino);
            switch (child.node_type) {
                .dir => {
                    if (inlined.contains(child)) {
                        const ch = childByNode(children, child) orelse return error.InodeNotFound;
                        try mergeManifestCopy(self.allocator, &msg, &ch.manifest);
                    } else {
                        const cid = external_chunk.get(child) orelse return error.InodeNotFound;
                        const owned_cid = try self.allocator.dupe(u8, cid);
                        try msg.external_subtrees.put(child_ino, owned_cid);
                    }
                },
                .regular => try msg.files.put(child_ino, try self.fileMsg(child, child_ino)),
                .symlink => try msg.symlinks.put(child_ino, .{
                    .inode = child_ino,
                    .target = try self.allocator.dupe(u8, child.target),
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
                .pending_hardlink => if (!self.per_layer) return error.UnresolvedHardlink,
            }
        }

        const root_dir: proto.DirMsg = .{
            .inode = ino,
            .mode = dir.mode,
            .uid = dir.uid,
            .gid = dir.gid,
            .mtime_ns = dir.mtime_ns,
            .entries = entries,
        };
        const old_dirs = msg.dirs;
        const merged_dirs = try self.allocator.alloc(proto.DirMsg, old_dirs.len + 1);
        @memcpy(merged_dirs[0..old_dirs.len], old_dirs);
        merged_dirs[old_dirs.len] = root_dir;
        self.allocator.free(old_dirs);
        msg.dirs = merged_dirs;

        const data = try proto.encodeManifest(self.allocator, msg);
        return .{ .manifest = msg, .data = data };
    }

    fn fileMsg(self: *ManifestBuilder, child: *tree_mod.Node, child_ino: u64) !proto.FileMsg {
        var blocks: std.ArrayList(proto.BlockMsg) = .empty;
        for (child.blocks.items) |b| {
            try blocks.append(self.allocator, .{
                .offset = b.offset,
                .chunk_id = try self.allocator.dupe(u8, &b.chunk_id),
                .logical_len = b.logical_len,
            });
        }
        var xattrs = std.StringHashMap([]const u8).init(self.allocator);
        var xit = child.xattrs.iterator();
        while (xit.next()) |e| {
            const k = try self.allocator.dupe(u8, e.key_ptr.*);
            const v = try self.allocator.dupe(u8, e.value_ptr.*);
            try xattrs.put(k, v);
        }
        return .{
            .inode = child_ino,
            .mode = child.mode,
            .uid = child.uid,
            .gid = child.gid,
            .size = child.size,
            .mtime_ns = child.mtime_ns,
            .nlink = self.nlink_of.get(child_ino) orelse 1,
            .blocks = try blocks.toOwnedSlice(self.allocator),
            .xattrs = xattrs,
        };
    }
};

fn childByNode(children: *const std.ArrayList(ManifestBuilder.ChildBuildResult), node: *tree_mod.Node) ?*ManifestBuilder.ChildBuildResult {
    for (children.items) |*ch| {
        if (ch.node == node) return ch;
    }
    return null;
}

fn pickLargestInlinedChild(
    children: *const std.ArrayList(ManifestBuilder.ChildBuildResult),
    inlined: *const std.AutoHashMap(*tree_mod.Node, void),
) ?*tree_mod.Node {
    var best: ?*tree_mod.Node = null;
    var best_size: isize = -1;
    for (children.items) |*ch| {
        if (!inlined.contains(ch.node)) continue;
        if (@as(isize, @intCast(ch.data.len)) > best_size) {
            best_size = @intCast(ch.data.len);
            best = ch.node;
        }
    }
    return best;
}

fn sortedChildDirs(allocator: std.mem.Allocator, dir: *tree_mod.Node) ![]*tree_mod.Node {
    const names = try sortedNames(allocator, dir);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
    var out: std.ArrayList(*tree_mod.Node) = .empty;
    for (names) |name| {
        const child = dir.children.get(name) orelse continue;
        if (child.node_type == .dir) try out.append(allocator, child);
    }
    return out.toOwnedSlice(allocator);
}

fn sortedNames(allocator: std.mem.Allocator, dir: *tree_mod.Node) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.children.keyIterator();
    while (it.next()) |k| try names.append(allocator, k.*);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var owned: std.ArrayList([]const u8) = .empty;
    for (names.items) |n| try owned.append(allocator, try allocator.dupe(u8, n));
    names.deinit(allocator);
    return owned.toOwnedSlice(allocator);
}

fn mergeManifestCopy(allocator: std.mem.Allocator, dst: *proto.ManifestMsg, src: *const proto.ManifestMsg) !void {
    const old_len = dst.dirs.len;
    const merged_dirs = try allocator.alloc(proto.DirMsg, old_len + src.dirs.len);
    @memcpy(merged_dirs[0..old_len], dst.dirs);
    allocator.free(dst.dirs);
    for (src.dirs, 0..) |sd, i| {
        var entries = std.StringHashMap(u64).init(allocator);
        var sit = sd.entries.iterator();
        while (sit.next()) |e| {
            const k = try allocator.dupe(u8, e.key_ptr.*);
            try entries.put(k, e.value_ptr.*);
        }
        merged_dirs[old_len + i] = .{
            .inode = sd.inode,
            .mode = sd.mode,
            .uid = sd.uid,
            .gid = sd.gid,
            .mtime_ns = sd.mtime_ns,
            .entries = entries,
        };
    }
    dst.dirs = merged_dirs;

    var fit = src.files.iterator();
    while (fit.next()) |e| {
        var blocks: std.ArrayList(proto.BlockMsg) = .empty;
        for (e.value_ptr.blocks) |b| {
            try blocks.append(allocator, .{
                .offset = b.offset,
                .chunk_id = try allocator.dupe(u8, b.chunk_id),
                .logical_len = b.logical_len,
            });
        }
        var xattrs = std.StringHashMap([]const u8).init(allocator);
        var xit = e.value_ptr.xattrs.iterator();
        while (xit.next()) |xe| {
            const k = try allocator.dupe(u8, xe.key_ptr.*);
            const v = try allocator.dupe(u8, xe.value_ptr.*);
            try xattrs.put(k, v);
        }
        try dst.files.put(e.key_ptr.*, .{
            .inode = e.value_ptr.inode,
            .mode = e.value_ptr.mode,
            .uid = e.value_ptr.uid,
            .gid = e.value_ptr.gid,
            .size = e.value_ptr.size,
            .mtime_ns = e.value_ptr.mtime_ns,
            .nlink = e.value_ptr.nlink,
            .blocks = try blocks.toOwnedSlice(allocator),
            .xattrs = xattrs,
        });
    }
    var sit = src.symlinks.iterator();
    while (sit.next()) |e| {
        try dst.symlinks.put(e.key_ptr.*, .{
            .inode = e.value_ptr.inode,
            .target = try allocator.dupe(u8, e.value_ptr.target),
            .uid = e.value_ptr.uid,
            .gid = e.value_ptr.gid,
        });
    }
    var dit = src.devices.iterator();
    while (dit.next()) |e| {
        try dst.devices.put(e.key_ptr.*, e.value_ptr.*);
    }
    var ext = src.external_subtrees.iterator();
    while (ext.next()) |e| {
        const owned = try allocator.dupe(u8, e.value_ptr.*);
        try dst.external_subtrees.put(e.key_ptr.*, owned);
    }
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

pub const Error = error{ UnresolvedHardlink, InodeNotFound };

test "a hardlink keeps one inode and nlink 2 through the layer merge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const layer_walk = @import("ingest_layer_walk.zig");
    const merge = @import("ingest_merge.zig");
    const layer = try tree_mod.newTree(a);
    const bin = layer_walk.ensureDir(a, layer, "usr/bin");
    const perl = try a.create(tree_mod.Node);
    perl.* = .{
        .path = "usr/bin/perl",
        .name = "perl",
        .node_type = .regular,
        .mode = 0o755,
        .blocks = .empty,
        .xattrs = .init(a),
        .children = .init(a),
        .allocator = a,
    };
    try layer_walk.attachChild(a, bin, "perl", perl);
    try layer.put(perl);
    try layer_walk.attachChild(a, bin, "perl5.36.0", perl);
    try layer.by_path.put("usr/bin/perl5.36.0", perl);

    var layers = [_]*tree_mod.LayerTree{layer};
    const merged = try merge.mergeTrees(a, &layers);
    var msg = try proto.decodeManifest(a, try buildManifestBytes(a, "", merged, false));
    defer msg.deinit();
    var bin_dir: ?proto.DirMsg = null;
    for (msg.dirs) |d| if (d.entries.contains("perl")) {
        bin_dir = d;
    };
    const entries = bin_dir.?.entries;
    const ino = entries.get("perl").?;
    try std.testing.expectEqual(ino, entries.get("perl5.36.0").?);
    try std.testing.expectEqual(@as(u32, 2), msg.files.get(ino).?.nlink);
}

test "large merged root splits into external_subtrees under threshold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const layer_walk = @import("ingest_layer_walk.zig");
    const fs = @import("sys").fs;

    const tmp = try fs.makeTempDir(a, "voila-manifest-split");
    defer fs.removeTree(a, tmp) catch {};
    defer a.free(tmp);
    const store = try std.fmt.allocPrint(a, "{s}/store", .{tmp});
    try fs.makePath(store);

    const tree = try tree_mod.newTree(a);
    const child_dirs = 500;
    const files_per_dir = 2;
    for (0..child_dirs) |i| {
        const dir_name = try std.fmt.allocPrint(a, "d{d:0>4}", .{i});
        _ = layer_walk.ensureDir(a, tree, dir_name);
        for (0..files_per_dir) |j| {
            const path = try std.fmt.allocPrint(
                a,
                "{s}/file-with-a-long-name-for-manifest-padding-{d}-{d}",
                .{ dir_name, i, j },
            );
            try addRegularNode(a, tree, path, 0o644);
        }
    }

    const root_id = try buildAndStoreManifest(a, store, tree, false);
    const posix_util = @import("sys").posix_util;
    const root_path = try chunkPath(a, store, root_id);
    const root_bytes = try posix_util.readFileAlloc(a, root_path, std.math.maxInt(usize));
    defer a.free(root_bytes);
    try std.testing.expect(root_bytes.len <= manifest_split_threshold);

    var root_msg = try proto.decodeManifest(a, root_bytes);
    defer root_msg.deinit();
    try std.testing.expect(root_msg.external_subtrees.count() > 0);

    var total_dirs: usize = root_msg.dirs.len;
    var total_files: usize = root_msg.files.count();
    var ext = root_msg.external_subtrees.iterator();
    while (ext.next()) |e| {
        const cid: [32]u8 = e.value_ptr.*[0..32].*;
        const child_path = try chunkPath(a, store, cid);
        const child_bytes = try posix_util.readFileAlloc(a, child_path, std.math.maxInt(usize));
        defer a.free(child_bytes);
        var child_msg = try proto.decodeManifest(a, child_bytes);
        defer child_msg.deinit();
        total_dirs += child_msg.dirs.len;
        total_files += child_msg.files.count();
    }
    try std.testing.expectEqual(@as(usize, 1 + child_dirs), total_dirs);
    try std.testing.expectEqual(@as(usize, child_dirs * files_per_dir), total_files);
}

fn addRegularNode(allocator: std.mem.Allocator, tree: *tree_mod.LayerTree, path: []const u8, mode: u32) !void {
    const layer_walk = @import("ingest_layer_walk.zig");
    const parts = layer_walk.splitPath(path);
    const parent = layer_walk.ensureDir(allocator, tree, parts.parent);
    const node = try allocator.create(tree_mod.Node);
    node.* = .{
        .path = try allocator.dupe(u8, path),
        .name = try allocator.dupe(u8, parts.base),
        .node_type = .regular,
        .mode = mode,
        .blocks = .empty,
        .xattrs = std.StringHashMap([]const u8).init(allocator),
        .children = std.StringHashMap(*tree_mod.Node).init(allocator),
        .allocator = allocator,
    };
    try layer_walk.attachChild(allocator, parent, parts.base, node);
    try tree.put(node);
}

fn chunkPath(allocator: std.mem.Allocator, voila_root: []const u8, id: chunk_store.ChunkId) ![]const u8 {
    const hex = chunk_store.idToHex(id);
    const voila_store = @import("../voila_store.zig");
    return voila_store.chunkBlobPath(allocator, voila_root, &hex);
}
