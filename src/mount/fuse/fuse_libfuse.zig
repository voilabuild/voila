const std = @import("std");
const fuse_vfs = @import("./fuse_vfs.zig");

const c = @import("fuse3");

fn pathSlice(path: [*c]const u8) []const u8 {
    return std.mem.sliceTo(path, 0);
}

fn vfsFromCtx() *fuse_vfs.FuseVfs {
    const ctx = c.fuse_get_context();
    return @ptrCast(@alignCast(ctx[0].private_data));
}

fn negErr(e: std.posix.E) c_int {
    return -@as(c_int, @intCast(@backingInt(e)));
}

fn fillStatFromAttr(vfs: *fuse_vfs.FuseVfs, ino: u64, stbuf: ?*c.struct_stat) bool {
    const attr = vfs.attr(ino) orelse return false;
    c.voila_fuse_fill_stat(
        stbuf,
        ino,
        attr.mode,
        attr.nlink,
        attr.uid,
        attr.gid,
        @intCast(attr.size),
        @intCast(attr.blksize),
        @intCast(attr.blocks),
        @intCast(attr.atime),
        @intCast(attr.atime_nsec),
        @intCast(attr.mtime),
        @intCast(attr.mtime_nsec),
        @intCast(attr.ctime),
        @intCast(attr.ctime_nsec),
    );
    return true;
}

fn getattrCb(path: [*c]const u8, stbuf: ?*c.struct_stat, fi: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    _ = fi;
    const vfs = vfsFromCtx();
    const ino = vfs.inoFromPath(pathSlice(path)) orelse return negErr(.NOENT);
    if (!fillStatFromAttr(vfs, ino, stbuf)) return negErr(.NOENT);
    return 0;
}

fn readlinkCb(path: [*c]const u8, buf: [*c]u8, size: usize) callconv(.c) c_int {
    const vfs = vfsFromCtx();
    const ino = vfs.inoFromPath(pathSlice(path)) orelse return negErr(.NOENT);
    const target = vfs.readlink(ino) orelse return negErr(.INVAL);
    if (size == 0) return negErr(.INVAL);
    const out = @as([*]u8, @ptrCast(buf))[0..size];
    if (target.len >= size) return negErr(.RANGE);
    @memcpy(out[0..target.len], target);
    out[target.len] = 0;
    return 0;
}

fn openCb(path: [*c]const u8, fi: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    const vfs = vfsFromCtx();
    const ino = vfs.inoFromPath(pathSlice(path)) orelse return negErr(.NOENT);
    if (!vfs.isFile(ino)) return negErr(.ISDIR);
    const info = fi orelse return negErr(.INVAL);
    const open_flags = @as(*const c_int, @ptrCast(@alignCast(info)));
    const accmode = @as(u32, @intCast(open_flags.*)) & 3; // O_ACCMODE
    if (accmode != 0) return negErr(.ROFS); // O_RDONLY
    return 0;
}

fn readCb(path: [*c]const u8, buf: [*c]u8, size: usize, offset: c.off_t, fi: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    _ = fi;
    const vfs = vfsFromCtx();
    const ino = vfs.inoFromPath(pathSlice(path)) orelse return negErr(.NOENT);
    if (size == 0) return 0;
    const off: u64 = @intCast(offset);
    const slice = @as([*]u8, @ptrCast(buf))[0..size];
    const n = vfs.readFuse(ino, slice, off);
    return @intCast(n);
}

fn readdirCb(
    path: [*c]const u8,
    buf: ?*anyopaque,
    filler: c.fuse_fill_dir_t,
    offset: c.off_t,
    fi: ?*c.struct_fuse_file_info,
    flags: c.enum_fuse_readdir_flags,
) callconv(.c) c_int {
    _ = fi;
    _ = flags;
    const vfs = vfsFromCtx();
    const dir_ino = vfs.inoFromPath(pathSlice(path)) orelse return negErr(.NOTDIR);
    if (!vfs.isDir(dir_ino)) return negErr(.NOTDIR);
    var idx: usize = @intCast(offset);
    while (true) {
        const ent = vfs.readdirEntry(dir_ino, idx) orelse return 0;
        var name_buf: [256]u8 = undefined;
        if (ent.name.len >= name_buf.len) return negErr(.NAMETOOLONG);
        @memcpy(name_buf[0..ent.name.len], ent.name);
        name_buf[ent.name.len] = 0;
        const next_off: c.off_t = @intCast(idx + 1);
        const fill = filler orelse return negErr(.INVAL);
        if (fill(buf, @ptrCast(&name_buf), null, next_off, 0) != 0) return 0;
        idx += 1;
    }
}

fn opendirCb(path: [*c]const u8, fi: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    _ = fi;
    const vfs = vfsFromCtx();
    const ino = vfs.inoFromPath(pathSlice(path)) orelse return negErr(.NOENT);
    if (!vfs.isDir(ino)) return negErr(.NOTDIR);
    return 0;
}

/// use_ino: report the manifest inode, so hardlinked paths share st_ino.
fn initCb(conn: ?*c.struct_fuse_conn_info, cfg: ?*c.struct_fuse_config) callconv(.c) ?*anyopaque {
    _ = conn;
    if (cfg) |config| config.use_ino = 1;
    return c.fuse_get_context()[0].private_data;
}

fn ops() c.struct_fuse_operations {
    return .{
        .init = initCb,
        .getattr = getattrCb,
        .readlink = readlinkCb,
        .open = openCb,
        .read = readCb,
        .opendir = opendirCb,
        .readdir = readdirCb,
    };
}

pub const Session = struct {
    fuse: ?*c.struct_fuse,
    mountpoint: []const u8,
    allocator: std.mem.Allocator,

    pub fn stop(self: *Session) void {
        const f = self.fuse orelse return;
        c.fuse_exit(f);
    }

    pub fn deinit(self: *Session) void {
        if (self.fuse != null) {
            c.fuse_unmount(self.fuse);
            c.fuse_destroy(self.fuse);
            self.fuse = null;
        }
        self.allocator.free(self.mountpoint);
    }
};

pub fn mountSession(allocator: std.mem.Allocator, mountpoint: []const u8, vfs: *fuse_vfs.FuseVfs, fuse_opts: []const u8) !Session {
    const mnt = try allocator.dupe(u8, mountpoint);
    errdefer allocator.free(mnt);
    const mnt_z = try allocator.allocSentinel(u8, mnt.len, 0);
    defer allocator.free(mnt_z);
    @memcpy(mnt_z, mnt);

    const prog = "zig-fuse";
    const prog_z = try allocator.allocSentinel(u8, prog.len, 0);
    defer allocator.free(prog_z);
    @memcpy(prog_z, prog);

    var args: c.struct_fuse_args = .{
        .argc = 0,
        .argv = null,
        .allocated = 0,
    };
    const prog_ptr: [*c]const u8 = @ptrCast(prog_z.ptr);
    if (c.fuse_opt_add_arg(&args, prog_ptr) != 0) return error.FuseArgsFailed;
    if (c.fuse_opt_add_arg(&args, "-o") != 0) return error.FuseArgsFailed;
    const opts_z = try allocator.allocSentinel(u8, fuse_opts.len, 0);
    defer allocator.free(opts_z);
    @memcpy(opts_z, fuse_opts);
    const opts_ptr: [*c]const u8 = @ptrCast(opts_z.ptr);
    if (c.fuse_opt_add_arg(&args, opts_ptr) != 0) return error.FuseArgsFailed;

    const fuse_ops = ops();
    const private_data: ?*anyopaque = @ptrCast(vfs);
    const f = c.voila_fuse_new(&args, &fuse_ops, @sizeOf(c.struct_fuse_operations), private_data);
    c.fuse_opt_free_args(&args);
    if (f == null) return error.FuseNewFailed;

    const mnt_ptr: [*c]const u8 = @ptrCast(mnt_z.ptr);
    if (c.fuse_mount(f, mnt_ptr) != 0) {
        c.fuse_destroy(f);
        return error.FuseMountFailed;
    }

    return .{
        .fuse = f,
        .mountpoint = mnt,
        .allocator = allocator,
    };
}

pub fn serveSession(session: *Session) !void {
    const f = session.fuse orelse return error.NoFuse;
    const rc = c.fuse_loop(f);
    if (rc != 0) return error.FuseLoopFailed;
}

pub fn mountAndServe(allocator: std.mem.Allocator, vfs: *fuse_vfs.FuseVfs, mountpoint: []const u8, fuse_opts: []const u8) !void {
    var session = try mountSession(allocator, mountpoint, vfs, fuse_opts);
    defer session.deinit();
    try serveSession(&session);
}
