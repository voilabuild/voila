//! `COPY --from`: graft nodes of another image's tree by chunk reference; no file data is read.
const std = @import("std");
const glob = @import("../../core/glob.zig");
const tree_mod = @import("../../store/ingest/ingest_tree.zig");
const layer_walk = @import("../../store/ingest/ingest_layer_walk.zig");
const dir_walk = @import("../../store/ingest/ingest_dir_walk.zig");
const copy_sources = @import("copy_sources.zig");

const Node = tree_mod.Node;

pub const Match = struct {
    node: *Node,
    /// Path in the source image, without a leading `/`.
    rel: []const u8,
};

pub const Error = error{ CopySourceMissing, UnsupportedWildcard, BadDestination };

/// Nodes of `src` matching each source path; wildcards only in the last segment.
pub fn resolve(a: std.mem.Allocator, src: *tree_mod.LayerTree, srcs: []const []const u8) ![]Match {
    var out: std.ArrayList(Match) = .empty;
    for (srcs) |raw| {
        const rel = try copy_sources.cleanSource(a, raw);
        const dir = std.fs.path.dirname(rel) orelse "";
        const base = std.fs.path.basename(rel);
        if (glob.hasWildcard(dir)) return error.UnsupportedWildcard;
        if (!glob.hasWildcard(base)) {
            try out.append(a, .{ .node = src.lookup(rel) orelse return error.CopySourceMissing, .rel = rel });
            continue;
        }
        const parent = src.lookup(dir) orelse return error.CopySourceMissing;
        var names: std.ArrayList([]const u8) = .empty;
        var it = parent.children.keyIterator();
        while (it.next()) |k| if (glob.matchSegment(base, k.*)) try names.append(a, k.*);
        if (names.items.len == 0) return error.CopySourceMissing;
        std.mem.sort([]const u8, names.items, {}, lessThan);
        for (names.items) |n| {
            const r = if (dir.len == 0) n else try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, n });
            try out.append(a, .{ .node = parent.children.get(n).?, .rel = r });
        }
    }
    return out.toOwnedSlice(a);
}

/// Layer tree holding `matches` at `dest` (relative): a directory contributes its
/// contents; with `into_dir`, other entries land under their basename.
/// `owner` overrides ownership; otherwise the source's is kept.
pub fn graft(a: std.mem.Allocator, matches: []const Match, dest: []const u8, into_dir: bool, owner: ?dir_walk.Owner) !*tree_mod.LayerTree {
    var g: Grafter = .{ .a = a, .tree = try tree_mod.newTree(a), .owner = owner, .copies = .init(a) };
    for (matches) |m| {
        if (m.node.node_type == .dir) {
            const d = layer_walk.ensureDir(a, g.tree, dest);
            try g.children(d, m.node);
            continue;
        }
        const target = if (into_dir) try join(a, dest, std.fs.path.basename(m.rel)) else dest;
        if (target.len == 0) return error.BadDestination;
        const parts = layer_walk.splitPath(target);
        try g.add(layer_walk.ensureDir(a, g.tree, parts.parent), parts.base, m.node);
    }
    return g.tree;
}

const Grafter = struct {
    a: std.mem.Allocator,
    tree: *tree_mod.LayerTree,
    owner: ?dir_walk.Owner,
    /// Source node to its copy, so hard links stay shared.
    copies: std.AutoHashMap(*Node, *Node),

    fn children(self: *Grafter, dst: *Node, src: *Node) std.mem.Allocator.Error!void {
        var it = src.children.iterator();
        while (it.next()) |e| try self.add(dst, e.key_ptr.*, e.value_ptr.*);
    }

    fn add(self: *Grafter, parent: *Node, name: []const u8, src: *Node) std.mem.Allocator.Error!void {
        const a = self.a;
        const path = try join(a, parent.path, name);
        if (parent.children.get(name)) |old| {
            if (old.node_type == .dir and src.node_type == .dir) {
                self.meta(old, src);
                return self.children(old, src);
            }
            self.forget(old);
        }
        if (self.copies.get(src)) |shared| {
            try layer_walk.attachChild(a, parent, name, shared);
            try self.tree.by_path.put(path, shared);
            return;
        }
        const n = try a.create(Node);
        n.* = src.*;
        n.path = path;
        n.name = try a.dupe(u8, name);
        n.children = .init(a);
        n.blocks = try src.blocks.clone(a);
        n.xattrs = try src.xattrs.cloneWithAllocator(a);
        n.allocator = a;
        self.meta(n, src);
        try self.copies.put(src, n);
        try layer_walk.attachChild(a, parent, name, n);
        try self.tree.put(n);
        if (src.node_type == .dir) try self.children(n, src);
    }

    fn meta(self: *Grafter, dst: *Node, src: *Node) void {
        dst.mode = src.mode;
        dst.mtime_ns = src.mtime_ns;
        dst.implicit = false;
        const o = self.owner orelse dir_walk.Owner{ .uid = src.uid, .gid = src.gid };
        dst.uid = o.uid;
        dst.gid = o.gid;
    }

    fn forget(self: *Grafter, n: *Node) void {
        var it = n.children.valueIterator();
        while (it.next()) |c| self.forget(c.*);
        _ = self.tree.by_path.remove(n.path);
    }
};

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

fn join(a: std.mem.Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    if (dir.len == 0) return a.dupe(u8, name);
    return std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
}

test "graft keeps chunk ids, hard links and ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = try tree_mod.newTree(a);
    const bin = layer_walk.ensureDir(a, src, "out/bin");
    bin.implicit = false;
    bin.uid = 7;
    const f = try a.create(Node);
    f.* = .{ .path = "out/bin/app", .name = "app", .node_type = .regular, .uid = 7, .size = 3, .blocks = .empty, .xattrs = .init(a), .children = .init(a), .allocator = a };
    try f.blocks.append(a, .{ .offset = 0, .chunk_id = @splat(5), .logical_len = 3 });
    try layer_walk.attachChild(a, bin, "app", f);
    try src.put(f);
    try layer_walk.attachChild(a, bin, "app2", f);
    try src.by_path.put("out/bin/app2", f);

    const all = try resolve(a, src, &.{"/out/"});
    const t = try graft(a, all, "usr", true, null);
    const app = t.lookup("usr/bin/app").?;
    try std.testing.expectEqual(app, t.lookup("usr/bin/app2").?);
    try std.testing.expectEqualSlices(u8, &f.blocks.items[0].chunk_id, &app.blocks.items[0].chunk_id);
    try std.testing.expectEqual(@as(u32, 7), t.lookup("usr/bin").?.uid);
    try std.testing.expect(t.lookup("usr").?.implicit);

    const wild = try resolve(a, src, &.{"out/bin/app*"});
    try std.testing.expectEqual(@as(usize, 2), wild.len);
    const one = try graft(a, wild[0..1], "x/renamed", false, .{ .uid = 1, .gid = 2 });
    try std.testing.expectEqual(@as(u32, 2), one.lookup("x/renamed").?.gid);
    try std.testing.expectError(error.CopySourceMissing, resolve(a, src, &.{"nope"}));
    try std.testing.expectError(error.BadDestination, graft(a, wild[0..1], "", false, null));
}
