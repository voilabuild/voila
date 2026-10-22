const std = @import("std");
const voila_manifest_proto = @import("./manifest/voila_manifest_proto.zig");
const voila_store = @import("./voila_store.zig");
const hex_util = @import("./hex_util.zig");
const backend = @import("./backend.zig");

/// Set by voilad before openTreeEager so manifest prefetch can use registry chunk cache.
pub var prefetch_io: ?std.Io = null;

fn cloneFile(allocator: std.mem.Allocator, f: voila_manifest_proto.FileMsg) !voila_manifest_proto.FileMsg {
    var blocks = try allocator.alloc(voila_manifest_proto.BlockMsg, f.blocks.len);
    for (f.blocks, 0..) |b, i| {
        blocks[i] = .{
            .offset = b.offset,
            .chunk_id = try allocator.dupe(u8, b.chunk_id),
            .logical_len = b.logical_len,
        };
    }
    var xattrs = std.StringHashMap([]const u8).init(allocator);
    var xit = f.xattrs.iterator();
    while (xit.next()) |e| {
        const k = try allocator.dupe(u8, e.key_ptr.*);
        const v = try allocator.dupe(u8, e.value_ptr.*);
        try xattrs.put(k, v);
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
        .xattrs = xattrs,
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
    manifest_hex_failed: std.StringHashMap(void),
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
        var mfail = self.manifest_hex_failed.keyIterator();
        while (mfail.next()) |k| self.allocator.free(k.*);
        self.manifest_hex_failed.deinit();
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
            var xit = e.value_ptr.xattrs.iterator();
            while (xit.next()) |xe| {
                self.allocator.free(xe.key_ptr.*);
                self.allocator.free(xe.value_ptr.*);
            }
            e.value_ptr.xattrs.deinit();
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

    fn markManifestFailed(self: *Tree, hex: []const u8) void {
        if (self.manifest_hex_loaded.contains(hex) or self.manifest_hex_failed.contains(hex)) return;
        const key = self.allocator.dupe(u8, hex) catch return;
        self.manifest_hex_failed.put(key, {}) catch {
            self.allocator.free(key);
        };
    }

    fn loadManifestChunk(self: *Tree, chunk_id: []const u8) !void {
        const hex = try chunkIdToHex(self.allocator, chunk_id);
        defer self.allocator.free(hex);
        if (self.manifest_hex_loaded.contains(hex)) return;
        if (self.manifest_hex_failed.contains(hex)) return error.ManifestUnavailable;

        const raw = loadManifestBytes(self, hex) catch |e| {
            self.markManifestFailed(hex);
            return e;
        };
        defer self.allocator.free(raw);
        var m = voila_manifest_proto.decodeManifest(self.allocator, raw) catch |e| {
            self.markManifestFailed(hex);
            return e;
        };
        defer m.deinit();
        self.indexManifest(&m) catch |e| {
            self.markManifestFailed(hex);
            return e;
        };
        const key = try self.allocator.dupe(u8, hex);
        try self.manifest_hex_loaded.put(key, {});
    }

    fn loadManifestBytes(self: *Tree, hex: []const u8) ![]u8 {
        if (backend.load_chunk_cached) |load| {
            const io = prefetch_io orelse return voila_store.loadChunkRaw(self.allocator, self.voila_root, hex);
            return load(io, self.allocator, self.voila_root, hex) catch
                voila_store.loadChunkRaw(self.allocator, self.voila_root, hex);
        }
        return voila_store.loadChunkRaw(self.allocator, self.voila_root, hex);
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
                const hex = chunkIdToHex(self.allocator, e.value_ptr.*) catch continue;
                defer self.allocator.free(hex);
                if (self.manifest_hex_loaded.contains(hex)) continue;
                if (self.manifest_hex_failed.contains(hex)) continue;
                var dup = false;
                for (pending.items) |p| {
                    if (std.mem.eql(u8, p, e.value_ptr.*)) dup = true;
                }
                if (!dup) pending.append(self.allocator, e.value_ptr.*) catch {};
            }
            if (pending.items.len == 0) break;
            const loaded_before = self.manifest_hex_loaded.count();
            for (pending.items) |cid| self.loadManifestChunk(cid) catch {};
            if (self.manifest_hex_loaded.count() == loaded_before) break;
        }
    }

    pub fn ensureInode(self: *Tree, ino: u64) !void {
        if (self.dir_by_inode.contains(ino) or self.file_by_inode.contains(ino) or
            self.symlink_by_inode.contains(ino) or self.device_by_inode.contains(ino)) return;
        const cid = self.external_subtrees.get(ino) orelse return error.InodeNotFound;
        try self.loadManifestChunk(cid);
    }
};

pub fn chunkIdToHex(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    return hex_util.allocHexLower(allocator, id);
}

pub fn openTreeEager(allocator: std.mem.Allocator, voila_root: []const u8, root_chunk: []const u8) !Tree {
    var tree: Tree = .{
        .voila_root = try allocator.dupe(u8, voila_root),
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
    try tree.loadRoot(root_chunk);
    tree.prefetchAll();
    return tree;
}

pub const Error = error{
    BadRootChunk,
    NoRootDir,
    InodeNotFound,
    ManifestUnavailable,
};
