const std = @import("std");
const voila_manifest_proto = @import("voila_manifest_proto.zig");
const voila_store = @import("voila_store.zig");
const voila_resolve = @import("voila_resolve.zig");
const voila_chunk_index = @import("voila_chunk_index.zig");
const voila_index = @import("voila_index.zig");

fn cloneFile(allocator: std.mem.Allocator, f: voila_manifest_proto.FileMsg) !voila_manifest_proto.FileMsg {
    var blocks = try allocator.alloc(voila_manifest_proto.BlockMsg, f.blocks.len);
    for (f.blocks, 0..) |b, i| {
        blocks[i] = .{
            .offset = b.offset,
            .chunk_id = try allocator.dupe(u8, b.chunk_id),
            .logical_len = b.logical_len,
        };
    }
    return .{
        .inode = f.inode,
        .mode = f.mode,
        .uid = f.uid,
        .gid = f.gid,
        .size = f.size,
        .mtime_ns = f.mtime_ns,
        .nlink = f.nlink,
        .blocks = blocks,
    };
}

fn cloneDir(allocator: std.mem.Allocator, d: voila_manifest_proto.DirMsg) !voila_manifest_proto.DirMsg {
    var entries = std.StringHashMap(u64).init(allocator);
    var it = d.entries.iterator();
    while (it.next()) |e| {
        const k = try allocator.dupe(u8, e.key_ptr.*);
        try entries.put(k, e.value_ptr.*);
    }
    return .{
        .inode = d.inode,
        .mode = d.mode,
        .uid = d.uid,
        .gid = d.gid,
        .mtime_ns = d.mtime_ns,
        .entries = entries,
    };
}

pub const Tree = struct {
    voila_root: []const u8,
    allocator: std.mem.Allocator,
    manifest_hex_loaded: std.StringHashMap(void),
    dir_by_inode: std.AutoHashMap(u64, voila_manifest_proto.DirMsg),
    file_by_inode: std.AutoHashMap(u64, voila_manifest_proto.FileMsg),
    symlink_by_inode: std.AutoHashMap(u64, voila_manifest_proto.SymlinkMsg),
    device_by_inode: std.AutoHashMap(u64, voila_manifest_proto.DeviceMsg),
    external_subtrees: std.AutoHashMap(u64, []const u8),
    root_ino: u64,

    pub fn deinit(self: *Tree) void {
        var mit = self.manifest_hex_loaded.keyIterator();
        while (mit.next()) |k| self.allocator.free(k.*);
        self.manifest_hex_loaded.deinit();
        var dit = self.dir_by_inode.iterator();
        while (dit.next()) |e| {
            var kit = e.value_ptr.entries.keyIterator();
            while (kit.next()) |k| self.allocator.free(k.*);
            e.value_ptr.entries.deinit();
        }
        self.dir_by_inode.deinit();
        var fit = self.file_by_inode.iterator();
        while (fit.next()) |e| {
            for (e.value_ptr.blocks) |*b| self.allocator.free(b.chunk_id);
            self.allocator.free(e.value_ptr.blocks);
        }
        self.file_by_inode.deinit();
        var sit = self.symlink_by_inode.iterator();
        while (sit.next()) |e| self.allocator.free(e.value_ptr.target);
        self.symlink_by_inode.deinit();
        self.device_by_inode.deinit();
        var eit = self.external_subtrees.iterator();
        while (eit.next()) |e| self.allocator.free(e.value_ptr.*);
        self.external_subtrees.deinit();
        self.allocator.free(self.voila_root);
    }

    fn indexManifest(self: *Tree, m: *const voila_manifest_proto.ManifestMsg) !void {
        for (m.dirs) |d| {
            if (!self.dir_by_inode.contains(d.inode)) {
                const copy = try cloneDir(self.allocator, d);
                try self.dir_by_inode.put(d.inode, copy);
            }
        }
        var fit = m.files.iterator();
        while (fit.next()) |e| {
            if (!self.file_by_inode.contains(e.key_ptr.*)) {
                const copy = try cloneFile(self.allocator, e.value_ptr.*);
                try self.file_by_inode.put(e.key_ptr.*, copy);
            }
        }
        var sit = m.symlinks.iterator();
        while (sit.next()) |e| {
            if (!self.symlink_by_inode.contains(e.key_ptr.*)) {
                const copy: voila_manifest_proto.SymlinkMsg = .{
                    .inode = e.value_ptr.inode,
                    .target = try self.allocator.dupe(u8, e.value_ptr.target),
                    .uid = e.value_ptr.uid,
                    .gid = e.value_ptr.gid,
                };
                try self.symlink_by_inode.put(e.key_ptr.*, copy);
            }
        }
        var dit = m.devices.iterator();
        while (dit.next()) |e| {
            if (!self.device_by_inode.contains(e.key_ptr.*)) {
                try self.device_by_inode.put(e.key_ptr.*, e.value_ptr.*);
            }
        }
        var ext = m.external_subtrees.iterator();
        while (ext.next()) |e| {
            if (e.value_ptr.*.len != 32) continue;
            if (!self.external_subtrees.contains(e.key_ptr.*)) {
                const owned = try self.allocator.dupe(u8, e.value_ptr.*);
                try self.external_subtrees.put(e.key_ptr.*, owned);
            }
        }
    }

    fn loadManifestChunk(self: *Tree, chunk_id: []const u8) !void {
        const hex = try voila_resolve.chunkIdToHex(self.allocator, chunk_id);
        defer self.allocator.free(hex);
        if (self.manifest_hex_loaded.contains(hex)) return;
        const algo = voila_chunk_index.compAlgoForChunk(self.voila_root, chunk_id) catch voila_store.AlgoRaw;
        const raw = try voila_store.loadChunkRaw(self.allocator, self.voila_root, hex, algo);
        defer self.allocator.free(raw);
        var m = try voila_manifest_proto.decodeManifest(self.allocator, raw);
        defer m.deinit();
        try self.indexManifest(&m);
        const key = try self.allocator.dupe(u8, hex);
        try self.manifest_hex_loaded.put(key, {});
    }

    pub fn loadRoot(self: *Tree, root_chunk: []const u8) !void {
        if (root_chunk.len != 32) return error.BadRootChunk;
        try self.loadManifestChunk(root_chunk);
        if (self.dir_by_inode.contains(1)) {
            self.root_ino = 1;
        } else {
            var lowest: ?u64 = null;
            var it = self.dir_by_inode.keyIterator();
            while (it.next()) |ino| {
                if (lowest == null or ino.* < lowest.?) lowest = ino.*;
            }
            if (lowest == null) return error.NoRootDir;
            self.root_ino = lowest.?;
        }
    }

    pub fn prefetchAll(self: *Tree) void {
        while (true) {
            var pending: std.ArrayList([]const u8) = .empty;
            defer pending.deinit(self.allocator);
            var it = self.external_subtrees.iterator();
            while (it.next()) |e| {
                const hex = voila_resolve.chunkIdToHex(self.allocator, e.value_ptr.*) catch continue;
                defer self.allocator.free(hex);
                if (self.manifest_hex_loaded.contains(hex)) continue;
                var dup = false;
                for (pending.items) |p| {
                    if (std.mem.eql(u8, p, e.value_ptr.*)) dup = true;
                }
                if (!dup) pending.append(self.allocator, e.value_ptr.*) catch {};
            }
            if (pending.items.len == 0) break;
            for (pending.items) |cid| self.loadManifestChunk(cid) catch {};
        }
    }

    fn ensureInode(self: *Tree, ino: u64) !void {
        if (self.dir_by_inode.contains(ino) or self.file_by_inode.contains(ino) or
            self.symlink_by_inode.contains(ino) or self.device_by_inode.contains(ino)) return;
        const cid = self.external_subtrees.get(ino) orelse return error.InodeNotFound;
        try self.loadManifestChunk(cid);
    }

    pub fn buildIndex(self: *Tree) !voila_index.Index {
        var idx: voila_index.Index = .{
            .voila_root = try self.allocator.dupe(u8, self.voila_root),
            .root_ino = self.root_ino,
            .dirs = std.AutoHashMap(u64, voila_index.Dir).init(self.allocator),
            .files = std.AutoHashMap(u64, voila_index.File).init(self.allocator),
            .symlinks = std.AutoHashMap(u64, voila_index.Link).init(self.allocator),
            .devices = std.AutoHashMap(u64, voila_index.Device).init(self.allocator),
            .allocator = self.allocator,
        };

        var seen: std.AutoHashMap(u64, void) = .init(self.allocator);
        defer seen.deinit();

        const Walk = struct {
            fn go(t: *Tree, i: *voila_index.Index, ino: u64, s: *std.AutoHashMap(u64, void)) !void {
                if (s.contains(ino)) return;
                try s.put(ino, {});
                try t.ensureInode(ino);

                if (t.dir_by_inode.get(ino)) |d| {
                    var entries = std.StringHashMap(u64).init(t.allocator);
                    var it = d.entries.iterator();
                    while (it.next()) |e| {
                        const k = try t.allocator.dupe(u8, e.key_ptr.*);
                        try entries.put(k, e.value_ptr.*);
                    }
                    try i.dirs.put(ino, .{
                        .mode = d.mode,
                        .uid = d.uid,
                        .gid = d.gid,
                        .mtime_ns = d.mtime_ns,
                        .entries = entries,
                    });
                    var kit = d.entries.keyIterator();
                    while (kit.next()) |name| {
                        const child = d.entries.get(name.*) orelse continue;
                        try go(t, i, child, s);
                    }
                    return;
                }
                if (t.file_by_inode.get(ino)) |f| {
                    var blocks: std.ArrayList(voila_index.Block) = .empty;
                    for (f.blocks) |b| {
                        var hex_id: []const u8 = "";
                        var algo: i32 = 0;
                        if (b.chunk_id.len == 32) {
                            hex_id = try voila_resolve.chunkIdToHex(t.allocator, b.chunk_id);
                            algo = voila_chunk_index.compAlgoForChunk(t.voila_root, b.chunk_id) catch 0;
                        }
                        try blocks.append(t.allocator, .{
                            .offset = b.offset,
                            .chunk_hex = hex_id,
                            .logical_len = b.logical_len,
                            .algo = algo,
                        });
                    }
                    try i.files.put(ino, .{
                        .mode = f.mode,
                        .uid = f.uid,
                        .gid = f.gid,
                        .size = f.size,
                        .mtime_ns = f.mtime_ns,
                        .nlink = f.nlink,
                        .blocks = try blocks.toOwnedSlice(t.allocator),
                    });
                    return;
                }
                if (t.symlink_by_inode.get(ino)) |l| {
                    try i.symlinks.put(ino, .{
                        .target = try t.allocator.dupe(u8, l.target),
                        .uid = l.uid,
                        .gid = l.gid,
                    });
                    return;
                }
                if (t.device_by_inode.get(ino)) |dv| {
                    try i.devices.put(ino, .{
                        .mode = dv.mode,
                        .uid = dv.uid,
                        .gid = dv.gid,
                        .rdev_major = dv.rdev_major,
                        .rdev_minor = dv.rdev_minor,
                        .is_char = dv.is_char,
                    });
                }
            }
        };

        try Walk.go(self, &idx, self.root_ino, &seen);
        return idx;
    }
};

pub const Error = error{
    BadRootChunk,
    NoRootDir,
    InodeNotFound,
};

pub fn openTree(allocator: std.mem.Allocator, voila_root: []const u8, root_chunk: []const u8) !Tree {
    var tree: Tree = .{
        .voila_root = try allocator.dupe(u8, voila_root),
        .allocator = allocator,
        .manifest_hex_loaded = std.StringHashMap(void).init(allocator),
        .dir_by_inode = std.AutoHashMap(u64, voila_manifest_proto.DirMsg).init(allocator),
        .file_by_inode = std.AutoHashMap(u64, voila_manifest_proto.FileMsg).init(allocator),
        .symlink_by_inode = std.AutoHashMap(u64, voila_manifest_proto.SymlinkMsg).init(allocator),
        .device_by_inode = std.AutoHashMap(u64, voila_manifest_proto.DeviceMsg).init(allocator),
        .external_subtrees = std.AutoHashMap(u64, []const u8).init(allocator),
        .root_ino = 1,
    };
    try tree.loadRoot(root_chunk);
    tree.prefetchAll();
    return tree;
}
