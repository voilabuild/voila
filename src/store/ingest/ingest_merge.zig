const std = @import("std");
const tree_mod = @import("ingest_tree.zig");

pub fn mergeTrees(allocator: std.mem.Allocator, layers: []*tree_mod.LayerTree) !*tree_mod.LayerTree {
    const merged = try tree_mod.newTree(allocator);
    for (layers) |layer| {
        applyOpaque(merged, layer);
        applyWhiteouts(merged, layer);
        overlayLayer(allocator, merged, layer);
    }
    try resolvePending(merged);
    return merged;
}

fn sortedNamesAlloc(allocator: std.mem.Allocator, children: *const std.StringHashMap(*tree_mod.Node)) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var it = children.keyIterator();
    while (it.next()) |k| try names.append(allocator, k.*);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return names.toOwnedSlice(allocator);
}

fn applyOpaque(merged: *tree_mod.LayerTree, layer: *tree_mod.LayerTree) void {
    for (layer.opaque_dirs.items) |dir_path| {
        const node = merged.lookup(dir_path);
        if (node == null or node.?.node_type != .dir) continue;
        const n = node.?;
        const names = sortedNamesAlloc(merged.allocator, &n.children) catch continue;
        defer merged.allocator.free(names);
        for (names) |name| {
            if (n.children.get(name)) |child| {
                dropSubtree(merged, child);
                _ = n.children.remove(name);
            }
        }
    }
}

fn applyWhiteouts(merged: *tree_mod.LayerTree, layer: *tree_mod.LayerTree) void {
    for (layer.whiteouts.items) |w| {
        const parent = if (w.parent.len == 0) merged.root else merged.lookup(w.parent) orelse continue;
        if (parent.node_type != .dir) continue;
        if (parent.children.get(w.name)) |child| {
            dropSubtree(merged, child);
            _ = parent.children.remove(w.name);
        }
    }
}

fn overlayLayer(allocator: std.mem.Allocator, merged: *tree_mod.LayerTree, layer: *tree_mod.LayerTree) void {
    var copies: std.AutoHashMap(*tree_mod.Node, *tree_mod.Node) = .init(allocator);
    defer copies.deinit();
    mergeDirInto(allocator, merged, merged.root, layer.root, &copies);
}

fn mergeDirInto(
    allocator: std.mem.Allocator,
    merged: *tree_mod.LayerTree,
    merged_dir: *tree_mod.Node,
    src_dir: *tree_mod.Node,
    copies: *std.AutoHashMap(*tree_mod.Node, *tree_mod.Node),
) void {
    mergeMeta(merged_dir, src_dir);
    const names = sortedNamesAlloc(allocator, &src_dir.children) catch return;
    defer allocator.free(names);
    for (names) |name| {
        const src = src_dir.children.get(name) orelse continue;
        overlayChild(allocator, merged, merged_dir, name, src, copies);
    }
}

fn overlayChild(
    allocator: std.mem.Allocator,
    merged: *tree_mod.LayerTree,
    merged_parent: *tree_mod.Node,
    name: []const u8,
    src: *tree_mod.Node,
    copies: *std.AutoHashMap(*tree_mod.Node, *tree_mod.Node),
) void {
    if (copies.get(src)) |existing| {
        // A hardlink: the second path shares the node and needs its own by_path entry.
        attachChild(allocator, merged_parent, name, existing) catch {};
        const path = if (merged_parent.path.len == 0)
            allocator.dupe(u8, name) catch return
        else
            std.fmt.allocPrint(allocator, "{s}/{s}", .{ merged_parent.path, name }) catch return;
        merged.by_path.put(path, existing) catch allocator.free(path);
        return;
    }
    const existing = merged_parent.children.get(name);
    if (existing != null and existing.?.node_type == .dir and src.node_type == .dir) {
        mergeDirInto(allocator, merged, existing.?, src, copies);
        return;
    }
    if (existing) |e| {
        dropSubtree(merged, e);
        _ = merged_parent.children.remove(name);
    }
    const m = copyShallow(allocator, src);
    copies.put(src, m) catch {};
    m.name = allocator.dupe(u8, name) catch return;
    if (merged_parent.path.len == 0) {
        m.path = allocator.dupe(u8, name) catch return;
    } else {
        m.path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ merged_parent.path, name }) catch return;
    }
    attachChild(allocator, merged_parent, name, m) catch {};
    merged.put(m) catch {};
    if (m.node_type == .dir) {
        m.children = std.StringHashMap(*tree_mod.Node).init(allocator);
        const child_names = sortedNamesAlloc(allocator, &src.children) catch return;
        defer allocator.free(child_names);
        for (child_names) |cname| {
            const c = src.children.get(cname) orelse continue;
            overlayChild(allocator, merged, m, cname, c, copies);
        }
    }
}

fn resolvePending(merged: *tree_mod.LayerTree) !void {
    while (true) {
        var pending: std.ArrayList([]const u8) = .empty;
        var it = merged.by_path.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.*.node_type == .pending_hardlink) {
                pending.append(merged.allocator, e.key_ptr.*) catch {};
            }
        }
        if (pending.items.len == 0) {
            pending.deinit(merged.allocator);
            return;
        }
        var progress = false;
        for (pending.items) |q| {
            const p = merged.lookup(q) orelse continue;
            const target = merged.lookup(p.link_target) orelse continue;
            if (target.node_type != .regular) continue;
            const parts = splitPath(q);
            const parent = if (parts.parent.len == 0) merged.root else merged.lookup(parts.parent) orelse continue;
            attachChild(merged.allocator, parent, parts.base, target) catch {};
            merged.by_path.put(q, target) catch {};
            progress = true;
        }
        pending.deinit(merged.allocator);
        if (!progress) return error.UnresolvedHardlink;
    }
}

fn mergeMeta(dst: *tree_mod.Node, upper: *tree_mod.Node) void {
    if (upper.implicit) return;
    if (upper.mode != 0) dst.mode = upper.mode;
    dst.uid = upper.uid;
    dst.gid = upper.gid;
    if (upper.mtime_ns != 0) dst.mtime_ns = upper.mtime_ns;
}

fn copyShallow(allocator: std.mem.Allocator, n: *tree_mod.Node) *tree_mod.Node {
    const m = allocator.create(tree_mod.Node) catch unreachable;
    m.* = n.*;
    m.children = std.StringHashMap(*tree_mod.Node).init(allocator);
    m.blocks = .empty;
    for (n.blocks.items) |b| m.blocks.append(allocator, b) catch {};
    m.xattrs = std.StringHashMap([]const u8).init(allocator);
    var xit = n.xattrs.iterator();
    while (xit.next()) |e| {
        const k = allocator.dupe(u8, e.key_ptr.*) catch continue;
        const v = allocator.dupe(u8, e.value_ptr.*) catch continue;
        m.xattrs.put(k, v) catch {};
    }
    return m;
}

fn dropSubtree(merged: *tree_mod.LayerTree, node: *tree_mod.Node) void {
    if (node.node_type == .dir) {
        const names = sortedNamesAlloc(merged.allocator, &node.children) catch return;
        defer merged.allocator.free(names);
        for (names) |name| {
            if (node.children.get(name)) |c| dropSubtree(merged, c);
        }
    }
    _ = merged.by_path.remove(node.path);
}

fn attachChild(allocator: std.mem.Allocator, parent: *tree_mod.Node, base: []const u8, child: *tree_mod.Node) !void {
    const key = try allocator.dupe(u8, base);
    try parent.children.put(key, child);
}

fn splitPath(clean: []const u8) struct { parent: []const u8, base: []const u8 } {
    const parent = std.fs.path.dirname(clean) orelse "";
    const base = std.fs.path.basename(clean);
    return .{
        .parent = if (std.mem.eql(u8, parent, ".")) "" else parent,
        .base = base,
    };
}

pub const Error = error{UnresolvedHardlink};

test "opaque dir in an upper layer hides the lower layer's children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const layer_walk = @import("ingest_layer_walk.zig");
    const lower = try tree_mod.newTree(a);
    _ = layer_walk.ensureDir(a, lower, "d/x/deep");
    _ = layer_walk.ensureDir(a, lower, "keep");
    const upper = try tree_mod.newTree(a);
    layer_walk.recordOpaque(upper, a, "d");
    _ = layer_walk.ensureDir(a, upper, "d/y");

    var layers = [_]*tree_mod.LayerTree{ lower, upper };
    const merged = try mergeTrees(a, &layers);
    try std.testing.expect(merged.lookup("d/x") == null);
    try std.testing.expect(merged.lookup("d/x/deep") == null);
    try std.testing.expect(merged.lookup("d/y") != null);
    try std.testing.expect(merged.lookup("keep") != null);
    try std.testing.expect(!merged.lookup("d").?.children.contains("x"));
}
