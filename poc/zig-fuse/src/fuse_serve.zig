const std = @import("std");
const abi = @import("fuse_abi.zig");
fn readFd(fd: std.posix.fd_t, buf: []u8) !usize {
    const n = std.c.read(fd, buf.ptr, buf.len);
    if (n < 0) {
        const err: std.posix.E = @enumFromInt(std.c._errno().*);
        if (err == .SUCCESS) return error.Unexpected;
        return std.posix.unexpectedErrno(err);
    }
    if (n == 0) return error.FuseClosed;
    return @intCast(n);
}

fn writeFd(fd: std.posix.fd_t, buf: []const u8) !usize {
    const n = std.c.write(fd, buf.ptr, buf.len);
    if (n < 0) {
        const err: std.posix.E = @enumFromInt(std.c._errno().*);
        if (err == .SUCCESS) return error.Unexpected;
        return std.posix.unexpectedErrno(err);
    }
    return @intCast(n);
}
const vfs_mod = @import("vfs.zig");
const constants = @import("constants.zig");

pub const Server = struct {
    fuse_fd: std.posix.fd_t,
    vfs: *vfs_mod.Vfs,
    io: std.Io,
    allocator: std.mem.Allocator,
    read_buf: []u8,
    reply_buf: []u8,

    pub fn serve(self: *Server) !void {
        while (true) {
            const n = try readFd(self.fuse_fd, self.read_buf);
            if (n < @sizeOf(abi.InHeader)) return error.BadFuseLen;
            var off: usize = 0;
            while (off + @sizeOf(abi.InHeader) <= n) {
                const in_hdr: *const abi.InHeader = @ptrCast(@alignCast(self.read_buf.ptr + off));
                const total: usize = @intCast(in_hdr.len);
                if (total < @sizeOf(abi.InHeader) or off + total > n) return error.BadFuseLen;
                const payload = self.read_buf[off + @sizeOf(abi.InHeader) .. off + total];
                try self.dispatch(in_hdr, payload);
                off += total;
            }
        }
    }

    fn dispatch(self: *Server, hdr: *const abi.InHeader, payload: []const u8) !void {
        switch (hdr.opcode) {
            abi.FUSE_INIT => try self.handleInit(hdr, payload),
            abi.FUSE_LOOKUP => try self.handleLookup(hdr, payload),
            abi.FUSE_GETATTR => try self.handleGetattr(hdr, payload),
            abi.FUSE_OPEN => try self.handleOpen(hdr, payload),
            abi.FUSE_OPENDIR => try self.handleOpenDir(hdr, payload),
            abi.FUSE_READ => try self.handleRead(hdr, payload),
            abi.FUSE_READDIR => try self.handleReaddir(hdr, payload),
            abi.FUSE_READLINK => try self.handleReadlink(hdr),
            abi.FUSE_ACCESS => try self.replyOk(hdr, &.{}),
            abi.FUSE_STATX => try self.handleStatx(hdr),
            abi.FUSE_FORGET, abi.FUSE_RELEASE, abi.FUSE_FLUSH, abi.FUSE_RELEASEDIR => {},
            else => try self.replyErr(hdr, -abi.EOPNOTSUPP),
        }
    }

    fn handleInit(self: *Server, hdr: *const abi.InHeader, payload: []const u8) !void {
        if (payload.len < @sizeOf(abi.InitIn)) return error.BadFuseInit;
        const init_in: *const abi.InitIn = @ptrCast(@alignCast(payload.ptr));
        const minor = @min(init_in.minor, 31);

        var out: abi.InitOut = .{
            .major = 7,
            .minor = minor,
            .max_readahead = 128 * 1024,
            .flags = abi.FUSE_ATTR_RDONLY,
            .max_background = 12,
            .congestion_threshold = 9,
            .max_write = 256 * 1024,
            .time_gran = 1,
        };
        const out_len = if (init_in.minor >= 23)
            @sizeOf(abi.InitOut)
        else if (init_in.minor >= 7)
            abi.init_out_compat_22_size
        else
            abi.init_out_compat_size;
        try self.replyOk(hdr, std.mem.asBytes(&out)[0..out_len]);
    }

    fn handleLookup(self: *Server, hdr: *const abi.InHeader, payload: []const u8) !void {
        const parent = hdr.nodeid;
        const name_bytes = payload;
        const name_end = std.mem.indexOfScalar(u8, name_bytes, 0) orelse name_bytes.len;
        const name_trim = if (name_end == 0) "." else name_bytes[0..name_end];
        const ino = self.vfs.lookup(parent, name_trim) orelse {
            return self.replyErr(hdr, -abi.ENOENT);
        };
        const attr = self.vfs.attr(ino) orelse return self.replyErr(hdr, -abi.ENOENT);
        var out: abi.EntryOut = .{
            .nodeid = ino,
            .generation = 1,
            .entry_valid = 60,
            .attr_valid = 60,
            .entry_valid_nsec = 0,
            .attr_valid_nsec = 0,
            .attr = attr,
        };
        out.attr.ino = ino;
        try self.replyOk(hdr, std.mem.asBytes(&out));
    }

    fn handleStatx(self: *Server, hdr: *const abi.InHeader) !void {
        const attr = self.vfs.attr(hdr.nodeid) orelse {
            return self.replyErr(hdr, -abi.ENOENT);
        };
        var out: abi.StatxOut = .{
            .attr_valid = 60,
            .attr_valid_nsec = 0,
            .flags = 0,
            .spare = .{ 0, 0 },
            .stat = .{
                .mask = 0,
                .blksize = attr.blksize,
                .attributes = 0,
                .nlink = attr.nlink,
                .uid = attr.uid,
                .gid = attr.gid,
                .mode = @truncate(attr.mode),
                ._spare0 = 0,
                .ino = attr.ino,
                .size = attr.size,
                .blocks = attr.blocks,
                .attributes_mask = 0,
                .atime = .{ .sec = attr.atime, .nsec = attr.atime_nsec, .__reserved = 0 },
                .btime = .{ .sec = attr.mtime, .nsec = attr.mtime_nsec, .__reserved = 0 },
                .ctime = .{ .sec = attr.ctime, .nsec = attr.ctime_nsec, .__reserved = 0 },
                .mtime = .{ .sec = attr.mtime, .nsec = attr.mtime_nsec, .__reserved = 0 },
                .rdev_major = 0,
                .rdev_minor = 0,
                .dev_major = 0,
                .dev_minor = 0,
                ._spare2 = std.mem.zeroes([14]u64),
            },
        };
        out.stat.ino = hdr.nodeid;
        try self.replyOk(hdr, std.mem.asBytes(&out));
    }

    fn handleGetattr(self: *Server, hdr: *const abi.InHeader, _: []const u8) !void {
        const attr = self.vfs.attr(hdr.nodeid) orelse {
            return self.replyErr(hdr, -abi.ENOENT);
        };
        var out: abi.AttrOut = .{
            .attr_valid = 60,
            .attr_valid_nsec = 0,
            .dummy = 0,
            .attr = attr,
        };
        out.attr.ino = hdr.nodeid;
        try self.replyOk(hdr, std.mem.asBytes(&out));
    }

    fn handleOpenDir(self: *Server, hdr: *const abi.InHeader, payload: []const u8) !void {
        if (payload.len < @sizeOf(abi.OpenIn)) return error.BadFuseOpen;
        const open_in: *const abi.OpenIn = @ptrCast(@alignCast(payload.ptr));
        const accmode = open_in.flags & 3;
        if (accmode != 0) return self.replyErr(hdr, -abi.EROFS);
        if (hdr.nodeid != constants.root_ino) return self.replyErr(hdr, -abi.EISDIR);
        var out: abi.OpenOut = .{
            .fh = constants.root_ino,
            .open_flags = 0,
            .padding = 0,
        };
        try self.replyOk(hdr, std.mem.asBytes(&out));
    }

    fn handleOpen(self: *Server, hdr: *const abi.InHeader, payload: []const u8) !void {
        if (payload.len < @sizeOf(abi.OpenIn)) return error.BadFuseOpen;
        const open_in: *const abi.OpenIn = @ptrCast(@alignCast(payload.ptr));
        const accmode = open_in.flags & 3; // O_ACCMODE: RDONLY=0, WRONLY=1, RDWR=2
        if (accmode != 0) return self.replyErr(hdr, -abi.EROFS);
        if (hdr.nodeid != constants.file_ino) {
            return self.replyErr(hdr, -abi.EISDIR);
        }
        var out: abi.OpenOut = .{
            .fh = constants.file_ino,
            .open_flags = 0,
            .padding = 0,
        };
        try self.replyOk(hdr, std.mem.asBytes(&out));
    }

    fn handleRead(self: *Server, hdr: *const abi.InHeader, payload: []const u8) !void {
        const read_in = try abi.readInFrom(payload);
        const want = @min(read_in.size, @as(u32, @intCast(self.reply_buf.len - @sizeOf(abi.OutHeader))));
        const n = try self.vfs.read(self.io, hdr.nodeid, self.reply_buf[@sizeOf(abi.OutHeader) ..][0..want], read_in.offset);
        try self.replyOk(hdr, self.reply_buf[@sizeOf(abi.OutHeader) ..][0..n]);
    }

    fn handleReaddir(self: *Server, hdr: *const abi.InHeader, payload: []const u8) !void {
        const read_in = try abi.readInFrom(payload);
        const off: usize = @intCast(read_in.offset);
        const buf = self.reply_buf[@sizeOf(abi.OutHeader) ..];
        const max = @min(read_in.size, @as(u32, @intCast(buf.len)));
        var pos: usize = 0;
        var idx = off;
        while (pos + @sizeOf(abi.Dirent) < max) {
            const ent = self.vfs.readdirEntry(idx) orelse break;
            const name_len = ent.name.len;
            const ent_size = abi.direntSize(name_len);
            if (pos + ent_size > max) break;
            const de: *abi.Dirent = @ptrCast(@alignCast(&buf[pos]));
            de.ino = ent.ino;
            de.off = idx + 1;
            de.namelen = @intCast(name_len);
            de.type = ent.typ;
            @memcpy(buf[pos + @sizeOf(abi.Dirent) ..][0..name_len], ent.name);
            buf[pos + @sizeOf(abi.Dirent) + name_len] = 0;
            pos += ent_size;
            idx += 1;
        }
        try self.replyOk(hdr, buf[0..pos]);
    }

    fn handleReadlink(self: *Server, hdr: *const abi.InHeader) !void {
        const target = self.vfs.readlink(hdr.nodeid) orelse {
            return self.replyErr(hdr, -abi.EINVAL);
        };
        try self.replyOk(hdr, target);
    }

    fn replyOk(self: *Server, hdr: *const abi.InHeader, body: []const u8) !void {
        const out_hdr: *abi.OutHeader = @ptrCast(@alignCast(self.reply_buf.ptr));
        out_hdr.len = @intCast(@sizeOf(abi.OutHeader) + body.len);
        out_hdr.@"error" = 0;
        out_hdr.unique = hdr.unique;
        const dest = self.reply_buf[@sizeOf(abi.OutHeader) ..][0..body.len];
        if (dest.ptr != body.ptr) @memcpy(dest, body);
        try self.writeAll(self.reply_buf[0 .. @sizeOf(abi.OutHeader) + body.len]);
    }

    fn replyErr(self: *Server, hdr: *const abi.InHeader, err: i32) !void {
        const out_hdr: *abi.OutHeader = @ptrCast(@alignCast(self.reply_buf.ptr));
        out_hdr.len = @sizeOf(abi.OutHeader);
        out_hdr.@"error" = err;
        out_hdr.unique = hdr.unique;
        try self.writeAll(self.reply_buf[0..@sizeOf(abi.OutHeader)]);
    }

    fn writeAll(self: *Server, data: []const u8) !void {
        var sent: usize = 0;
        while (sent < data.len) {
            const w = try writeFd(self.fuse_fd, data[sent..]);
            if (w == 0) return error.FuseClosed;
            sent += w;
        }
    }
};
