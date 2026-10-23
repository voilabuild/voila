const std = @import("std");
const proto = @import("../../codec/voila_manifest_proto.zig");

pub const NodeType = enum {
    regular,
    dir,
    symlink,
    device,
    pending_hardlink,
};

pub const Block = struct {
    offset: u64,
    chunk_id: [32]u8,
    logical_len: u64,
};

pub const Node = struct {
    path: []const u8,
    name: []const u8,
    node_type: NodeType,
    mode: u32 = 0o755,
    uid: u32 = 0,
    gid: u32 = 0,
    mtime_ns: u64 = 0,
    size: u64 = 0,
    blocks: std.ArrayList(Block),
    xattrs: std.StringHashMap([]const u8),
    target: []const u8 = "",
    major: u32 = 0,
    minor: u32 = 0,
    char_device: bool = false,
    link_target: []const u8 = "",
    nlink: u32 = 1,
    children: std.StringHashMap(*Node),
    implicit: bool = false,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Node) void {
        for (self.blocks.items) |_| {}
        self.blocks.deinit(self.allocator);
        var it = self.xattrs.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.xattrs.deinit();
        if (self.target.len != 0) self.allocator.free(self.target);
        if (self.link_target.len != 0) self.allocator.free(self.link_target);
        if (self.path.len != 0 and self.node_type != .dir) self.allocator.free(self.path);
        if (self.name.len != 0 and self.node_type != .dir) self.allocator.free(self.name);
        var cit = self.children.iterator();
        while (cit.next()) |e| {
            e.value_ptr.*.deinit();
            self.allocator.destroy(e.value_ptr.*);
            self.allocator.free(e.key_ptr.*);
        }
        self.children.deinit();
    }
};

pub const WhiteoutEntry = struct {
    parent: []const u8,
    name: []const u8,
};

pub const LayerTree = struct {
    root: *Node,
    by_path: std.StringHashMap(*Node),
    whiteouts: std.ArrayList(WhiteoutEntry),
    opaque_dirs: std.ArrayList([]const u8),
    whiteouts_n: u64 = 0,
    opaque_n: u64 = 0,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *LayerTree) void {
        var it = self.by_path.iterator();
        var seen = std.AutoHashMap(*Node, void).init(self.allocator);
        defer seen.deinit();
        while (it.next()) |e| {
            if (seen.contains(e.value_ptr.*)) continue;
            seen.put(e.value_ptr.*, {}) catch {};
            e.value_ptr.*.deinit();
            self.allocator.destroy(e.value_ptr.*);
        }
        self.by_path.deinit();
        for (self.whiteouts.items) |w| {
            self.allocator.free(w.parent);
            self.allocator.free(w.name);
        }
        self.whiteouts.deinit(self.allocator);
        for (self.opaque_dirs.items) |d| self.allocator.free(d);
        self.opaque_dirs.deinit(self.allocator);
    }

    pub fn lookup(self: *LayerTree, path: []const u8) ?*Node {
        return self.by_path.get(path);
    }

    pub fn put(self: *LayerTree, n: *Node) !void {
        const key = if (n.path.len == 0) "" else n.path;
        try self.by_path.put(try self.allocator.dupe(u8, key), n);
    }
};

pub fn newTree(allocator: std.mem.Allocator) !*LayerTree {
    const tree = try allocator.create(LayerTree);
    const root = try allocator.create(Node);
    root.* = .{
        .path = "",
        .name = "",
        .node_type = .dir,
        .mode = 0o755,
        .blocks = .empty,
        .xattrs = std.StringHashMap([]const u8).init(allocator),
        .children = std.StringHashMap(*Node).init(allocator),
        .implicit = true,
        .allocator = allocator,
    };
    tree.* = .{
        .root = root,
        .by_path = std.StringHashMap(*Node).init(allocator),
        .whiteouts = .empty,
        .opaque_dirs = .empty,
        .allocator = allocator,
    };
    try tree.put(root);
    return tree;
}

pub fn blocksToProto(allocator: std.mem.Allocator, blocks: []const Block) ![]proto.BlockMsg {
    var out: std.ArrayList(proto.BlockMsg) = .empty;
    for (blocks) |b| {
        try out.append(allocator, .{
            .offset = b.offset,
            .chunk_id = try allocator.dupe(u8, &b.chunk_id),
            .logical_len = b.logical_len,
        });
    }
    return out.toOwnedSlice(allocator);
}
