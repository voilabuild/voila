const std = @import("std");

pub const Block = struct {
    offset: u64,
    chunk_hex: []const u8,
    logical_len: u64,
    algo: i32,
};

pub const Dir = struct {
    mode: u32,
    uid: u32,
    gid: u32,
    mtime_ns: u64,
    entries: std.StringHashMap(u64),
};

pub const File = struct {
    mode: u32,
    uid: u32,
    gid: u32,
    size: u64,
    mtime_ns: u64,
    nlink: u32,
    blocks: []Block,
};

pub const Link = struct {
    target: []const u8,
    uid: u32,
    gid: u32,
};

pub const Device = struct {
    mode: u32,
    uid: u32,
    gid: u32,
    rdev_major: u32,
    rdev_minor: u32,
    is_char: bool,
};

pub const Index = struct {
    voila_root: []const u8,
    root_ino: u64,
    dirs: std.AutoHashMap(u64, Dir),
    files: std.AutoHashMap(u64, File),
    symlinks: std.AutoHashMap(u64, Link),
    devices: std.AutoHashMap(u64, Device),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Index) void {
        var dit = self.dirs.iterator();
        while (dit.next()) |e| {
            var kit = e.value_ptr.entries.keyIterator();
            while (kit.next()) |k| self.allocator.free(k.*);
            e.value_ptr.entries.deinit();
        }
        self.dirs.deinit();
        var fit = self.files.iterator();
        while (fit.next()) |e| {
            for (e.value_ptr.blocks) |b| self.allocator.free(b.chunk_hex);
            self.allocator.free(e.value_ptr.blocks);
        }
        self.files.deinit();
        var lit = self.symlinks.iterator();
        while (lit.next()) |e| {
            self.allocator.free(e.value_ptr.target);
        }
        self.symlinks.deinit();
        self.devices.deinit();
        self.allocator.free(self.voila_root);
    }

    pub fn parse(allocator: std.mem.Allocator, json_bytes: []const u8) !Index {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return error.BadIndex;

        const voila_root = try allocator.dupe(u8, (root.object.get("voila_root") orelse return error.BadIndex).string);
        const root_ino = @as(u64, @intCast((root.object.get("root_ino") orelse return error.BadIndex).integer));

        var dirs: std.AutoHashMap(u64, Dir) = .init(allocator);
        var files: std.AutoHashMap(u64, File) = .init(allocator);
        var symlinks: std.AutoHashMap(u64, Link) = .init(allocator);
        var devices: std.AutoHashMap(u64, Device) = .init(allocator);

        try parseDirMap(allocator, root.object.get("dirs"), &dirs);
        try parseFileMap(allocator, root.object.get("files"), &files);
        try parseLinkMap(allocator, root.object.get("symlinks"), &symlinks);
        try parseDeviceMap(allocator, root.object.get("devices"), &devices);

        return .{
            .voila_root = voila_root,
            .root_ino = root_ino,
            .dirs = dirs,
            .files = files,
            .symlinks = symlinks,
            .devices = devices,
            .allocator = allocator,
        };
    }
};

fn parseInoKey(s: []const u8) !u64 {
    return std.fmt.parseInt(u64, s, 10);
}

fn parseDirMap(allocator: std.mem.Allocator, val: ?std.json.Value, out: *std.AutoHashMap(u64, Dir)) !void {
    const obj = (val orelse return).object;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const ino = try parseInoKey(entry.key_ptr.*);
        const o = entry.value_ptr.object;
        var entries: std.StringHashMap(u64) = .init(allocator);
        const ent_obj = o.get("entries") orelse return error.BadIndex;
        var eit = ent_obj.object.iterator();
        while (eit.next()) |e| {
            try entries.put(try allocator.dupe(u8, e.key_ptr.*), @intCast(e.value_ptr.integer));
        }
        try out.put(ino, .{
            .mode = @intCast((o.get("mode") orelse return error.BadIndex).integer),
            .uid = @intCast((o.get("uid") orelse return error.BadIndex).integer),
            .gid = @intCast((o.get("gid") orelse return error.BadIndex).integer),
            .mtime_ns = @intCast((o.get("mtime_ns") orelse return error.BadIndex).integer),
            .entries = entries,
        });
    }
}

fn parseFileMap(allocator: std.mem.Allocator, val: ?std.json.Value, out: *std.AutoHashMap(u64, File)) !void {
    const obj = (val orelse return).object;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const ino = try parseInoKey(entry.key_ptr.*);
        const o = entry.value_ptr.object;
        const blocks_val = o.get("blocks") orelse return error.BadIndex;
        const blocks_arr = blocks_val.array;
        const blocks = try allocator.alloc(Block, blocks_arr.items.len);
        for (blocks_arr.items, 0..) |bval, i| {
            const b = bval.object;
            const hex = try allocator.dupe(u8, (b.get("chunk_hex") orelse return error.BadIndex).string);
            blocks[i] = .{
                .offset = @intCast((b.get("offset") orelse return error.BadIndex).integer),
                .chunk_hex = hex,
                .logical_len = @intCast((b.get("logical_len") orelse return error.BadIndex).integer),
                .algo = @intCast((b.get("algo") orelse return error.BadIndex).integer),
            };
        }
        try out.put(ino, .{
            .mode = @intCast((o.get("mode") orelse return error.BadIndex).integer),
            .uid = @intCast((o.get("uid") orelse return error.BadIndex).integer),
            .gid = @intCast((o.get("gid") orelse return error.BadIndex).integer),
            .size = @intCast((o.get("size") orelse return error.BadIndex).integer),
            .mtime_ns = @intCast((o.get("mtime_ns") orelse return error.BadIndex).integer),
            .nlink = @intCast((o.get("nlink") orelse return error.BadIndex).integer),
            .blocks = blocks,
        });
    }
}

fn parseLinkMap(allocator: std.mem.Allocator, val: ?std.json.Value, out: *std.AutoHashMap(u64, Link)) !void {
    const obj = (val orelse return).object;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const ino = try parseInoKey(entry.key_ptr.*);
        const o = entry.value_ptr.object;
        try out.put(ino, .{
            .target = try allocator.dupe(u8, (o.get("target") orelse return error.BadIndex).string),
            .uid = @intCast((o.get("uid") orelse return error.BadIndex).integer),
            .gid = @intCast((o.get("gid") orelse return error.BadIndex).integer),
        });
    }
}

fn parseDeviceMap(_: std.mem.Allocator, val: ?std.json.Value, out: *std.AutoHashMap(u64, Device)) !void {
    const obj = (val orelse return).object;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const ino = try parseInoKey(entry.key_ptr.*);
        const o = entry.value_ptr.object;
        try out.put(ino, .{
            .mode = @intCast((o.get("mode") orelse return error.BadIndex).integer),
            .uid = @intCast((o.get("uid") orelse return error.BadIndex).integer),
            .gid = @intCast((o.get("gid") orelse return error.BadIndex).integer),
            .rdev_major = @intCast((o.get("rdev_major") orelse return error.BadIndex).integer),
            .rdev_minor = @intCast((o.get("rdev_minor") orelse return error.BadIndex).integer),
            .is_char = (o.get("is_char") orelse return error.BadIndex).bool,
        });
    }
}
