//! Ingest a host directory (COPY sources or an overlayfs upper dir) into a `LayerTree`.
const std = @import("std");
const fs = @import("../../sys/fs.zig");
const tree_mod = @import("ingest_tree.zig");
const layer_walk = @import("ingest_layer_walk.zig");
const chunk_store = @import("ingest_chunk_store.zig");
const voila_store = @import("../voila_store.zig");

pub const Mode = enum { copy, overlay_upper };

pub const Owner = struct { uid: u32, gid: u32 };

pub const Skip = struct {
    ctx: *const anyopaque,
    /// Returns true when `rel` (path relative to the added source) must be left out.
    func: *const fn (ctx: *const anyopaque, rel: []const u8, is_dir: bool) bool,
};

pub const Options = struct {
    mode: Mode,
    /// copy: owner of every entry (Docker COPY defaults to root:root).
    owner: Owner = .{ .uid = 0, .gid = 0 },
    /// overlay_upper: host ids that are root inside the build user namespace.
    host_root: ?Owner = null,
    skip: ?Skip = null,
};

pub const UpperClass = enum { normal, whiteout, opaque_dir };

/// Overlayfs upper-dir encoding: 0/0 char devices are whiteouts, `overlay.opaque=y` marks opaque dirs.
pub fn classifyUpper(st: fs.Stat, opaque_xattr: ?[]const u8) UpperClass {
    if (st.kind == .char_dev and st.rdev_major == 0 and st.rdev_minor == 0) return .whiteout;
    if (st.kind == .dir) {
        if (opaque_xattr) |v| if (std.mem.eql(u8, v, "y")) return .opaque_dir;
    }
    return .normal;
}

const InodeKey = struct { major: u32, minor: u32, ino: u64 };

pub const Walker = struct {
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    opts: Options,
    res: layer_walk.LayerWalkResult,
    seen: std.AutoHashMap(chunk_store.ChunkId, void),
    writer: voila_store.ChunkWriter,
    links: std.AutoHashMap(InodeKey, *tree_mod.Node),
    buf: []u8,

    /// Use an arena: `LayerTree` nodes follow the ingest ownership model.
    pub fn init(allocator: std.mem.Allocator, voila_root: []const u8, opts: Options) !Walker {
        return .{
            .allocator = allocator,
            .voila_root = voila_root,
            .opts = opts,
            .res = .{ .tree = try tree_mod.newTree(allocator), .bytes_in = 0, .chunk_count = 0, .chunks_deduped = 0, .stored_bytes = 0 },
            .seen = .init(allocator),
            .writer = .init(voila_root),
            .links = .init(allocator),
            .buf = try allocator.alloc(u8, layer_walk.chunk_size),
        };
    }

    pub fn deinit(self: *Walker) void {
        self.writer.deinit();
        self.seen.deinit();
        self.links.deinit();
        self.allocator.free(self.buf);
    }

    /// Adds `src` at image path `dest` (relative, no leading `/`; "" is the root).
    /// A directory source contributes its contents, not its own metadata.
    pub fn add(self: *Walker, src: []const u8, dest: []const u8) !void {
        const st = try fs.lstat(src);
        if (st.kind == .dir) {
            _ = layer_walk.ensureDir(self.allocator, self.res.tree, dest);
            return self.walkChildren(src, dest, "");
        }
        if (dest.len == 0) return error.BadDestination;
        try self.addEntry(src, dest, st);
    }

    /// Commits pending index rows; call before anything else writes chunks.
    pub fn finish(self: *Walker) !layer_walk.LayerWalkResult {
        try self.writer.flush();
        return self.res;
    }

    fn walkChildren(self: *Walker, src_dir: []const u8, dest_dir: []const u8, rel_dir: []const u8) !void {
        const names = try fs.listDir(self.allocator, src_dir);
        defer fs.freeNames(self.allocator, names);
        for (names) |name| {
            const src = try join(self.allocator, src_dir, name);
            defer self.allocator.free(src);
            const dest = try join(self.allocator, dest_dir, name);
            defer self.allocator.free(dest);
            const rel = try join(self.allocator, rel_dir, name);
            defer self.allocator.free(rel);
            const st = try fs.lstat(src);
            if (self.opts.skip) |s| if (s.func(s.ctx, rel, st.kind == .dir)) continue;

            var class: UpperClass = .normal;
            if (self.opts.mode == .overlay_upper) {
                const opq = if (st.kind == .dir) try opaqueXattr(self.allocator, src) else null;
                defer if (opq) |v| self.allocator.free(v);
                class = classifyUpper(st, opq);
            }
            switch (class) {
                .whiteout => {
                    layer_walk.recordWhiteout(self.res.tree, self.allocator, dest_dir, name);
                    self.res.tree.whiteouts_n += 1;
                    continue;
                },
                .opaque_dir => {
                    layer_walk.recordOpaque(self.res.tree, self.allocator, dest);
                    self.res.tree.opaque_n += 1;
                },
                .normal => {},
            }
            if (st.kind == .dir) {
                const node = layer_walk.ensureDir(self.allocator, self.res.tree, dest);
                self.applyMeta(node, st);
                try self.walkChildren(src, dest, rel);
            } else try self.addEntry(src, dest, st);
        }
    }

    fn addEntry(self: *Walker, src: []const u8, dest: []const u8, st: fs.Stat) !void {
        const parts = layer_walk.splitPath(dest);
        const parent = layer_walk.ensureDir(self.allocator, self.res.tree, parts.parent);
        const key: InodeKey = .{ .major = st.dev_major, .minor = st.dev_minor, .ino = st.ino };
        if (st.kind == .file and st.nlink > 1) {
            if (self.links.get(key)) |existing| {
                try layer_walk.attachChild(self.allocator, parent, parts.base, existing);
                try self.res.tree.by_path.put(try self.allocator.dupe(u8, dest), existing);
                return;
            }
        }
        const node_type: tree_mod.NodeType = switch (st.kind) {
            .file => .regular,
            .symlink => .symlink,
            .char_dev, .block_dev => .device,
            .dir, .fifo, .socket => return,
        };
        const node = try self.allocator.create(tree_mod.Node);
        node.* = .{
            .path = try self.allocator.dupe(u8, dest),
            .name = try self.allocator.dupe(u8, parts.base),
            .node_type = node_type,
            .blocks = .empty,
            .xattrs = std.StringHashMap([]const u8).init(self.allocator),
            .children = std.StringHashMap(*tree_mod.Node).init(self.allocator),
            .allocator = self.allocator,
        };
        self.applyMeta(node, st);
        switch (st.kind) {
            .file => try self.chunkFile(src, node),
            .symlink => node.target = try fs.readLink(self.allocator, src),
            .char_dev, .block_dev => {
                node.major = st.rdev_major;
                node.minor = st.rdev_minor;
                node.char_device = st.kind == .char_dev;
            },
            else => {},
        }
        if (st.kind == .file and st.nlink > 1) try self.links.put(key, node);
        try layer_walk.attachChild(self.allocator, parent, parts.base, node);
        try self.res.tree.put(node);
    }

    fn applyMeta(self: *Walker, node: *tree_mod.Node, st: fs.Stat) void {
        node.mode = st.perm;
        node.mtime_ns = st.mtime_ns;
        node.implicit = false;
        switch (self.opts.mode) {
            .copy => {
                node.uid = self.opts.owner.uid;
                node.gid = self.opts.owner.gid;
            },
            .overlay_upper => {
                const hr = self.opts.host_root;
                node.uid = if (hr != null and st.uid == hr.?.uid) 0 else st.uid;
                node.gid = if (hr != null and st.gid == hr.?.gid) 0 else st.gid;
            },
        }
    }

    fn chunkFile(self: *Walker, src: []const u8, node: *tree_mod.Node) !void {
        const f = try fs.File.openRead(src);
        defer f.close();
        var offset: u64 = 0;
        while (true) {
            const n = try f.readFull(self.buf);
            if (n == 0) break;
            const put = try layer_walk.putChunk(self.allocator, &self.writer, &self.seen, self.buf[0..n]);
            try node.blocks.append(self.allocator, .{ .offset = offset, .chunk_id = put.id, .logical_len = n });
            offset += n;
            self.res.bytes_in += n;
            self.res.chunk_count += 1;
            self.res.stored_bytes += put.stored_add;
            if (!put.is_new) self.res.chunks_deduped += 1;
            if (n < self.buf.len) break;
        }
        node.size = offset;
    }
};

fn opaqueXattr(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    if (try fs.getXattr(allocator, path, "user.overlay.opaque")) |v| return v;
    return fs.getXattr(allocator, path, "trusted.overlay.opaque");
}

fn join(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    if (a.len == 0) return allocator.dupe(u8, b);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ a, b });
}

pub const Error = error{BadDestination};
