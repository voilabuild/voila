const std = @import("std");
const wire = @import("proto_wire.zig");

pub const BlockMsg = struct {
    offset: u64,
    chunk_id: []const u8,
    logical_len: u64,
};

pub const FileMsg = struct {
    inode: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    size: u64,
    mtime_ns: u64,
    nlink: u32,
    blocks: []BlockMsg,
    xattrs: std.StringHashMap([]const u8),
};

pub const DirMsg = struct {
    inode: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    mtime_ns: u64,
    entries: std.StringHashMap(u64),
};

pub const SymlinkMsg = struct {
    inode: u64,
    target: []const u8,
    uid: u32,
    gid: u32,
};

pub const DeviceMsg = struct {
    inode: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    rdev_major: u32,
    rdev_minor: u32,
    is_char: bool,
};

pub const ManifestMsg = struct {
    dirs: []DirMsg,
    files: std.AutoHashMap(u64, FileMsg),
    symlinks: std.AutoHashMap(u64, SymlinkMsg),
    devices: std.AutoHashMap(u64, DeviceMsg),
    external_subtrees: std.AutoHashMap(u64, []const u8),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ManifestMsg) void {
        for (self.dirs) |*d| {
            var it = d.entries.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            d.entries.deinit();
        }
        self.allocator.free(self.dirs);
        var fit = self.files.iterator();
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
        self.files.deinit();
        var sit = self.symlinks.iterator();
        while (sit.next()) |e| self.allocator.free(e.value_ptr.target);
        self.symlinks.deinit();
        self.devices.deinit();
        var eit = self.external_subtrees.iterator();
        while (eit.next()) |e| self.allocator.free(e.value_ptr.*);
        self.external_subtrees.deinit();
    }
};

fn decodeBlock(allocator: std.mem.Allocator, data: []const u8) !BlockMsg {
    var off: usize = 0;
    var msg: BlockMsg = .{ .offset = 0, .chunk_id = "", .logical_len = 0 };
    while (off < data.len) {
        const tag = try wire.readTag(data, &off);
        switch (tag.field) {
            1 => msg.offset = try wire.readU64(data, &off),
            2 => {
                const id = try wire.readLenDelim(data, &off);
                msg.chunk_id = try allocator.dupe(u8, id);
            },
            3 => msg.logical_len = try wire.readU64(data, &off),
            else => try wire.skipField(data, &off, tag.wire),
        }
    }
    return msg;
}

fn decodeFile(allocator: std.mem.Allocator, data: []const u8) !FileMsg {
    var off: usize = 0;
    var msg: FileMsg = .{
        .inode = 0,
        .mode = 0,
        .uid = 0,
        .gid = 0,
        .size = 0,
        .mtime_ns = 0,
        .nlink = 0,
        .blocks = &.{},
        .xattrs = std.StringHashMap([]const u8).init(allocator),
    };
    var blocks: std.ArrayList(BlockMsg) = .empty;
    while (off < data.len) {
        const tag = try wire.readTag(data, &off);
        switch (tag.field) {
            1 => msg.inode = try wire.readU64(data, &off),
            2 => msg.mode = try wire.readU32(data, &off),
            3 => msg.uid = try wire.readU32(data, &off),
            4 => msg.gid = try wire.readU32(data, &off),
            5 => msg.size = try wire.readU64(data, &off),
            6 => msg.mtime_ns = try wire.readU64(data, &off),
            7 => msg.nlink = try wire.readU32(data, &off),
            8 => {
                const sub = try wire.readLenDelim(data, &off);
                var eoff: usize = 0;
                var key: []const u8 = "";
                var val: []const u8 = "";
                while (eoff < sub.len) {
                    const et = try wire.readTag(sub, &eoff);
                    switch (et.field) {
                        1 => key = try wire.readString(sub, &eoff),
                        2 => val = try wire.readLenDelim(sub, &eoff),
                        else => try wire.skipField(sub, &eoff, et.wire),
                    }
                }
                const owned_k = try allocator.dupe(u8, key);
                const owned_v = try allocator.dupe(u8, val);
                try msg.xattrs.put(owned_k, owned_v);
            },
            9 => {
                const sub = try wire.readLenDelim(data, &off);
                try blocks.append(allocator, try decodeBlock(allocator, sub));
            },
            else => try wire.skipField(data, &off, tag.wire),
        }
    }
    msg.blocks = try blocks.toOwnedSlice(allocator);
    return msg;
}

fn decodeDir(allocator: std.mem.Allocator, data: []const u8) !DirMsg {
    var off: usize = 0;
    var msg: DirMsg = .{
        .inode = 0,
        .mode = 0,
        .uid = 0,
        .gid = 0,
        .mtime_ns = 0,
        .entries = std.StringHashMap(u64).init(allocator),
    };
    while (off < data.len) {
        const tag = try wire.readTag(data, &off);
        switch (tag.field) {
            1 => msg.inode = try wire.readU64(data, &off),
            2 => msg.mode = try wire.readU32(data, &off),
            3 => msg.uid = try wire.readU32(data, &off),
            4 => msg.gid = try wire.readU32(data, &off),
            5 => msg.mtime_ns = try wire.readU64(data, &off),
            6 => {
                const sub = try wire.readLenDelim(data, &off);
                var eoff: usize = 0;
                var name: []const u8 = "";
                var child: u64 = 0;
                while (eoff < sub.len) {
                    const et = try wire.readTag(sub, &eoff);
                    switch (et.field) {
                        1 => name = try wire.readString(sub, &eoff),
                        2 => child = try wire.readU64(sub, &eoff),
                        else => try wire.skipField(sub, &eoff, et.wire),
                    }
                }
                const owned = try allocator.dupe(u8, name);
                try msg.entries.put(owned, child);
            },
            else => try wire.skipField(data, &off, tag.wire),
        }
    }
    return msg;
}

fn decodeSymlink(allocator: std.mem.Allocator, data: []const u8) !SymlinkMsg {
    var off: usize = 0;
    var msg: SymlinkMsg = .{ .inode = 0, .target = "", .uid = 0, .gid = 0 };
    while (off < data.len) {
        const tag = try wire.readTag(data, &off);
        switch (tag.field) {
            1 => msg.inode = try wire.readU64(data, &off),
            2 => msg.target = try allocator.dupe(u8, try wire.readString(data, &off)),
            3 => msg.uid = try wire.readU32(data, &off),
            4 => msg.gid = try wire.readU32(data, &off),
            else => try wire.skipField(data, &off, tag.wire),
        }
    }
    return msg;
}

fn decodeDevice(data: []const u8) !DeviceMsg {
    var off: usize = 0;
    var msg: DeviceMsg = .{
        .inode = 0,
        .mode = 0,
        .uid = 0,
        .gid = 0,
        .rdev_major = 0,
        .rdev_minor = 0,
        .is_char = false,
    };
    while (off < data.len) {
        const tag = try wire.readTag(data, &off);
        switch (tag.field) {
            1 => msg.inode = try wire.readU64(data, &off),
            2 => msg.mode = try wire.readU32(data, &off),
            3 => msg.uid = try wire.readU32(data, &off),
            4 => msg.gid = try wire.readU32(data, &off),
            5 => msg.rdev_major = try wire.readU32(data, &off),
            6 => msg.rdev_minor = try wire.readU32(data, &off),
            7 => msg.is_char = (try wire.readVarint(data, &off)) != 0,
            else => try wire.skipField(data, &off, tag.wire),
        }
    }
    return msg;
}

pub fn decodeManifest(allocator: std.mem.Allocator, data: []const u8) !ManifestMsg {
    var off: usize = 0;
    var dirs: std.ArrayList(DirMsg) = .empty;
    var msg: ManifestMsg = .{
        .dirs = &.{},
        .files = std.AutoHashMap(u64, FileMsg).init(allocator),
        .symlinks = std.AutoHashMap(u64, SymlinkMsg).init(allocator),
        .devices = std.AutoHashMap(u64, DeviceMsg).init(allocator),
        .external_subtrees = std.AutoHashMap(u64, []const u8).init(allocator),
        .allocator = allocator,
    };
    errdefer msg.deinit();

    while (off < data.len) {
        const tag = try wire.readTag(data, &off);
        switch (tag.field) {
            1 => {
                const sub = try wire.readLenDelim(data, &off);
                try dirs.append(allocator, try decodeDir(allocator, sub));
            },
            2 => {
                const sub = try wire.readLenDelim(data, &off);
                var eoff: usize = 0;
                var ino: u64 = 0;
                var file_bytes: []const u8 = "";
                while (eoff < sub.len) {
                    const et = try wire.readTag(sub, &eoff);
                    switch (et.field) {
                        1 => ino = try wire.readU64(sub, &eoff),
                        2 => file_bytes = try wire.readLenDelim(sub, &eoff),
                        else => try wire.skipField(sub, &eoff, et.wire),
                    }
                }
                const file = try decodeFile(allocator, file_bytes);
                try msg.files.put(ino, file);
            },
            3 => {
                const sub = try wire.readLenDelim(data, &off);
                var eoff: usize = 0;
                var ino: u64 = 0;
                var link_bytes: []const u8 = "";
                while (eoff < sub.len) {
                    const et = try wire.readTag(sub, &eoff);
                    switch (et.field) {
                        1 => ino = try wire.readU64(sub, &eoff),
                        2 => link_bytes = try wire.readLenDelim(sub, &eoff),
                        else => try wire.skipField(sub, &eoff, et.wire),
                    }
                }
                const link = try decodeSymlink(allocator, link_bytes);
                try msg.symlinks.put(ino, link);
            },
            4 => {
                const sub = try wire.readLenDelim(data, &off);
                var eoff: usize = 0;
                var ino: u64 = 0;
                var dev_bytes: []const u8 = "";
                while (eoff < sub.len) {
                    const et = try wire.readTag(sub, &eoff);
                    switch (et.field) {
                        1 => ino = try wire.readU64(sub, &eoff),
                        2 => dev_bytes = try wire.readLenDelim(sub, &eoff),
                        else => try wire.skipField(sub, &eoff, et.wire),
                    }
                }
                const dev = try decodeDevice(dev_bytes);
                try msg.devices.put(ino, dev);
            },
            5 => {
                const sub = try wire.readLenDelim(data, &off);
                var eoff: usize = 0;
                var ino: u64 = 0;
                var cid: []const u8 = "";
                while (eoff < sub.len) {
                    const et = try wire.readTag(sub, &eoff);
                    switch (et.field) {
                        1 => ino = try wire.readU64(sub, &eoff),
                        2 => cid = try wire.readLenDelim(sub, &eoff),
                        else => try wire.skipField(sub, &eoff, et.wire),
                    }
                }
                const owned = try allocator.dupe(u8, cid);
                try msg.external_subtrees.put(ino, owned);
            },
            else => try wire.skipField(data, &off, tag.wire),
        }
    }
    msg.dirs = try dirs.toOwnedSlice(allocator);
    return msg;
}

pub fn encodeBlock(allocator: std.mem.Allocator, b: BlockMsg) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try wire.writeU64(&out, allocator, 1, b.offset);
    try wire.writeBytes(&out, allocator, 2, b.chunk_id);
    try wire.writeU64(&out, allocator, 3, b.logical_len);
    return out.toOwnedSlice(allocator);
}

pub fn encodeFile(allocator: std.mem.Allocator, f: FileMsg) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try wire.writeU64(&out, allocator, 1, f.inode);
    try wire.writeU32(&out, allocator, 2, f.mode);
    try wire.writeU32(&out, allocator, 3, f.uid);
    try wire.writeU32(&out, allocator, 4, f.gid);
    try wire.writeU64(&out, allocator, 5, f.size);
    try wire.writeU64(&out, allocator, 6, f.mtime_ns);
    try wire.writeU32(&out, allocator, 7, f.nlink);
    var xit = f.xattrs.iterator();
    while (xit.next()) |e| {
        var pair: std.ArrayList(u8) = .empty;
        try wire.writeString(&pair, allocator, 1, e.key_ptr.*);
        try wire.writeBytes(&pair, allocator, 2, e.value_ptr.*);
        const sub = try pair.toOwnedSlice(allocator);
        defer allocator.free(sub);
        try wire.writeSubmessage(&out, allocator, 8, sub);
    }
    for (f.blocks) |blk| {
        const sub = try encodeBlock(allocator, blk);
        defer allocator.free(sub);
        try wire.writeSubmessage(&out, allocator, 9, sub);
    }
    return out.toOwnedSlice(allocator);
}

pub fn encodeDir(allocator: std.mem.Allocator, d: DirMsg) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try wire.writeU64(&out, allocator, 1, d.inode);
    try wire.writeU32(&out, allocator, 2, d.mode);
    try wire.writeU32(&out, allocator, 3, d.uid);
    try wire.writeU32(&out, allocator, 4, d.gid);
    try wire.writeU64(&out, allocator, 5, d.mtime_ns);
    var eit = d.entries.iterator();
    while (eit.next()) |e| {
        var pair: std.ArrayList(u8) = .empty;
        try wire.writeString(&pair, allocator, 1, e.key_ptr.*);
        try wire.writeU64(&pair, allocator, 2, e.value_ptr.*);
        const sub = try pair.toOwnedSlice(allocator);
        defer allocator.free(sub);
        try wire.writeSubmessage(&out, allocator, 6, sub);
    }
    return out.toOwnedSlice(allocator);
}

pub fn encodeSymlink(allocator: std.mem.Allocator, s: SymlinkMsg) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try wire.writeU64(&out, allocator, 1, s.inode);
    try wire.writeString(&out, allocator, 2, s.target);
    try wire.writeU32(&out, allocator, 3, s.uid);
    try wire.writeU32(&out, allocator, 4, s.gid);
    return out.toOwnedSlice(allocator);
}

pub fn encodeDevice(allocator: std.mem.Allocator, d: DeviceMsg) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try wire.writeU64(&out, allocator, 1, d.inode);
    try wire.writeU32(&out, allocator, 2, d.mode);
    try wire.writeU32(&out, allocator, 3, d.uid);
    try wire.writeU32(&out, allocator, 4, d.gid);
    try wire.writeU32(&out, allocator, 5, d.rdev_major);
    try wire.writeU32(&out, allocator, 6, d.rdev_minor);
    try wire.writeBool(&out, allocator, 7, d.is_char);
    return out.toOwnedSlice(allocator);
}

pub fn encodeManifest(allocator: std.mem.Allocator, m: ManifestMsg) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const sorted_dirs = try allocator.alloc(DirMsg, m.dirs.len);
    @memcpy(sorted_dirs, m.dirs);
    std.mem.sort(DirMsg, sorted_dirs, {}, struct {
        fn less(_: void, a: DirMsg, b: DirMsg) bool {
            return a.inode < b.inode;
        }
    }.less);
    for (sorted_dirs) |d| {
        const sub = try encodeDir(allocator, d);
        defer allocator.free(sub);
        try wire.writeSubmessage(&out, allocator, 1, sub);
    }
    allocator.free(sorted_dirs);

    var file_keys: std.ArrayList(u64) = .empty;
    var fit = m.files.iterator();
    while (fit.next()) |e| try file_keys.append(allocator, e.key_ptr.*);
    std.mem.sort(u64, file_keys.items, {}, std.sort.asc(u64));
    for (file_keys.items) |ino| {
        const f = m.files.get(ino) orelse continue;
        var entry: std.ArrayList(u8) = .empty;
        try wire.writeU64(&entry, allocator, 1, ino);
        const fbytes = try encodeFile(allocator, f);
        defer allocator.free(fbytes);
        try wire.writeSubmessage(&entry, allocator, 2, fbytes);
        const sub = try entry.toOwnedSlice(allocator);
        defer allocator.free(sub);
        try wire.writeSubmessage(&out, allocator, 2, sub);
    }
    file_keys.deinit(allocator);

    var sit = m.symlinks.iterator();
    var skeys: std.ArrayList(u64) = .empty;
    while (sit.next()) |e| try skeys.append(allocator, e.key_ptr.*);
    std.mem.sort(u64, skeys.items, {}, std.sort.asc(u64));
    for (skeys.items) |ino| {
        const s = m.symlinks.get(ino) orelse continue;
        var entry: std.ArrayList(u8) = .empty;
        try wire.writeU64(&entry, allocator, 1, ino);
        const sbytes = try encodeSymlink(allocator, s);
        defer allocator.free(sbytes);
        try wire.writeSubmessage(&entry, allocator, 2, sbytes);
        const sub = try entry.toOwnedSlice(allocator);
        defer allocator.free(sub);
        try wire.writeSubmessage(&out, allocator, 3, sub);
    }
    skeys.deinit(allocator);

    var dit = m.devices.iterator();
    var dkeys: std.ArrayList(u64) = .empty;
    while (dit.next()) |e| try dkeys.append(allocator, e.key_ptr.*);
    std.mem.sort(u64, dkeys.items, {}, std.sort.asc(u64));
    for (dkeys.items) |ino| {
        const d = m.devices.get(ino) orelse continue;
        var entry: std.ArrayList(u8) = .empty;
        try wire.writeU64(&entry, allocator, 1, ino);
        const dbytes = try encodeDevice(allocator, d);
        defer allocator.free(dbytes);
        try wire.writeSubmessage(&entry, allocator, 2, dbytes);
        const sub = try entry.toOwnedSlice(allocator);
        defer allocator.free(sub);
        try wire.writeSubmessage(&out, allocator, 4, sub);
    }
    dkeys.deinit(allocator);

    var ext = m.external_subtrees.iterator();
    var ext_keys: std.ArrayList(u64) = .empty;
    while (ext.next()) |e| try ext_keys.append(allocator, e.key_ptr.*);
    std.mem.sort(u64, ext_keys.items, {}, std.sort.asc(u64));
    for (ext_keys.items) |ino| {
        const cid = m.external_subtrees.get(ino) orelse continue;
        var entry: std.ArrayList(u8) = .empty;
        try wire.writeU64(&entry, allocator, 1, ino);
        try wire.writeBytes(&entry, allocator, 2, cid);
        const sub = try entry.toOwnedSlice(allocator);
        defer allocator.free(sub);
        try wire.writeSubmessage(&out, allocator, 5, sub);
    }
    ext_keys.deinit(allocator);

    return out.toOwnedSlice(allocator);
}
