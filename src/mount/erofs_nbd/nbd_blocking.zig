const std = @import("std");
const constants = @import("./constants.zig");
const backend = @import("./backend.zig");
const capacity_wait = @import("./capacity_wait.zig");
const posix_util = @import("./posix_util.zig");

pub fn disconnect(nbd_path: []const u8) void {
    disconnectIoctl(nbd_path);
    if (nbd_path.len + 16 < 96) {
        var cmd: [96]u8 = undefined;
        const prefix = "nbd-client -d ";
        @memcpy(cmd[0..prefix.len], prefix);
        @memcpy(cmd[prefix.len .. prefix.len + nbd_path.len], nbd_path);
        cmd[prefix.len + nbd_path.len] = 0;
        _ = posix_util.shell(cmd[0 .. prefix.len + nbd_path.len :0]);
    }
    for (0..200) |_| {
        if (!capacity_wait.nbdSessionActive(nbd_path)) break;
        disconnectIoctl(nbd_path);
        var ts = std.os.linux.timespec{ .sec = 0, .nsec = 5_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
}

fn disconnectIoctl(nbd_path: []const u8) void {
    var nbd_z: [64]u8 = undefined;
    if (nbd_path.len >= nbd_z.len) return;
    @memcpy(nbd_z[0..nbd_path.len], nbd_path);
    nbd_z[nbd_path.len] = 0;
    const nbd_raw = std.os.linux.open(nbd_z[0..nbd_path.len :0], .{ .ACCMODE = .RDWR }, 0);
    const nbd_isize: isize = @bitCast(nbd_raw);
    if (nbd_isize < 0) return;
    const fd: i32 = @intCast(nbd_isize);
    ioctl(fd, constants.nbd_disconnect, 0) catch {};
    ioctl(fd, constants.nbd_clear_sock, 0) catch {};
    _ = std.c.close(fd);
}

pub fn attachAndServe(io: std.Io, dev: *backend.Device, nbd_path: []const u8, connected: ?*std.atomic.Value(bool)) !void {
    dev.serve_io = io;
    disconnect(nbd_path);
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const listen_addr = server.socket.address;

    var accepted: ?std.Io.net.Stream = null;
    var accept_err: ?anyerror = null;
    const accept_thread = try std.Thread.spawn(.{}, struct {
        fn run(io_inner: std.Io, srv: *std.Io.net.Server, out: *?std.Io.net.Stream, err: *?anyerror) void {
            const s = srv.accept(io_inner) catch |e| {
                err.* = e;
                return;
            };
            out.* = s;
        }
    }.run, .{ io, &server, &accepted, &accept_err });

    const client = try listen_addr.connect(io, .{ .mode = .stream });

    accept_thread.join();
    if (accept_err != null) return accept_err.?;
    const server_stream = accepted orelse return error.NoConnection;
    const server_fd = server_stream.socket.handle;
    const client_fd = client.socket.handle;
    setBlocking(server_fd);
    setBlocking(client_fd);

    var handshake_done = std.atomic.Value(bool).init(false);
    const serve_thread = try std.Thread.spawn(.{}, struct {
        fn run(io_inner: std.Io, fd: i32, device: *backend.Device, done: *std.atomic.Value(bool)) void {
            serveConnectionFd(io_inner, fd, device, done) catch {};
        }
    }.run, .{ io, server_fd, dev, &handshake_done });

    try clientNegotiateFd(client_fd);
    handshake_done.store(true, .release);
    var yield_ts = std.os.linux.timespec{ .sec = 0, .nsec = 10_000_000 };
    _ = std.os.linux.nanosleep(&yield_ts, null);

    const sock_dup = std.c.dup(@intCast(client_fd));
    if (sock_dup < 0) return error.DupFailed;
    var nbd_z: [64]u8 = undefined;
    if (nbd_path.len >= nbd_z.len) return error.NameTooLong;
    @memcpy(nbd_z[0..nbd_path.len], nbd_path);
    nbd_z[nbd_path.len] = 0;
    const nbd_raw = std.os.linux.open(nbd_z[0..nbd_path.len :0], .{ .ACCMODE = .RDWR }, 0);
    const nbd_isize: isize = @bitCast(nbd_raw);
    if (nbd_isize < 0) return error.NbdOpen;
    const nbd_fd: i32 = @intCast(nbd_isize);
    defer _ = std.c.close(nbd_fd);

    try ioctl(nbd_fd, constants.nbd_set_sock, @intCast(sock_dup));
    _ = std.c.close(@intCast(sock_dup));
    client.close(io);
    try ioctl(nbd_fd, constants.nbd_set_blksize, constants.block_size);
    const num_blocks = (dev.device_size + constants.block_size - 1) / constants.block_size;
    try ioctl(nbd_fd, constants.nbd_set_size_blocks, num_blocks);
    try ioctl(nbd_fd, constants.nbd_set_flags, constants.nbd_flag_has_flags | constants.nbd_flag_read_only);

    const DoItCtx = struct {
        err: ?anyerror = null,
        finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    };
    var do_it_ctx = DoItCtx{};
    const do_it = try std.Thread.spawn(.{}, struct {
        fn run(fd: i32, ctx: *DoItCtx) void {
            ioctl(fd, constants.nbd_do_it, 0) catch |e| {
                ctx.err = e;
            };
            ctx.finished.store(true, .release);
        }
    }.run, .{ nbd_fd, &do_it_ctx });

    for (0..50) |_| {
        if (do_it_ctx.finished.load(.acquire)) {
            if (do_it_ctx.err != null) return do_it_ctx.err.?;
            return error.NbdDoItEnded;
        }
        var ts = std.os.linux.timespec{ .sec = 0, .nsec = 1_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }

    try capacity_wait.waitNbdConnected(nbd_path, dev.device_size, 15_000);
    try capacity_wait.waitDeviceCapacityWithPolls(nbd_path, dev.device_size, 15_000, capacity_wait.readDeviceSizeWhenReadable);
    if (connected) |flag| flag.store(true, .release);

    do_it.join();
    ioctl(nbd_fd, constants.nbd_disconnect, 0) catch {};
    ioctl(nbd_fd, constants.nbd_clear_sock, 0) catch {};
    serve_thread.join();
}

fn serveConnectionFd(_: std.Io, fd: i32, dev: *backend.Device, handshake_done: *std.atomic.Value(bool)) !void {
    var hdr: [18]u8 = undefined;
    std.mem.writeInt(u64, hdr[0..8], constants.negotiation_magic_oldstyle, .big);
    std.mem.writeInt(u64, hdr[8..16], constants.negotiation_magic_option, .big);
    std.mem.writeInt(u16, hdr[16..18], 1, .big);
    try fdWriteAll(fd, &hdr);

    var client_flags: [4]u8 = undefined;
    try fdReadExact(fd, &client_flags);
    try serverNegotiateFd(fd, dev.device_size);

    while (!handshake_done.load(.acquire)) {
        var ts = std.os.linux.timespec{ .sec = 0, .nsec = 100_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }

    var req_buf = try std.heap.page_allocator.alloc(u8, 2 * backend.ChunkSize);
    defer std.heap.page_allocator.free(req_buf);
    while (true) {
        var req_hdr: [28]u8 = undefined;
        try fdReadExact(fd, &req_hdr);
        const magic = std.mem.readInt(u32, req_hdr[0..4], .big);
        if (magic != constants.transmission_magic_request) return error.BadRequestMagic;
        const cmd = std.mem.readInt(u32, req_hdr[4..8], .big);
        const handle = req_hdr[8..16];
        const offset = std.mem.readInt(u64, req_hdr[16..24], .big);
        const length = std.mem.readInt(u32, req_hdr[24..28], .big);
        switch (cmd) {
            constants.nbd_cmd_read => {
                if (length > req_buf.len) return error.ReadTooLarge;
                var reply: [16]u8 = undefined;
                @memset(&reply, 0);
                std.mem.writeInt(u32, reply[0..4], constants.transmission_magic_reply, .big);
                @memcpy(reply[8..16], handle);
                try fdWriteAll(fd, &reply);
                const slice = req_buf[0..length];
                try dev.preloadSlotsForRangeSync(offset, length);
                dev.readAtSync(slice, offset);
                try fdWriteAll(fd, slice);
            },
            constants.nbd_cmd_write => {
                try discardFd(fd, length);
                var reply: [16]u8 = undefined;
                std.mem.writeInt(u32, reply[0..4], constants.transmission_magic_reply, .big);
                std.mem.writeInt(u32, reply[4..8], 1, .big);
                @memcpy(reply[8..16], handle);
                try fdWriteAll(fd, &reply);
            },
            constants.nbd_cmd_disc => return,
            else => return error.BadCmd,
        }
    }
}

fn serverNegotiateFd(fd: i32, export_size: u64) !void {
    while (true) {
        var opt: [16]u8 = undefined;
        try fdReadExact(fd, &opt);
        const opt_id = std.mem.readInt(u32, opt[8..12], .big);
        const opt_len = std.mem.readInt(u32, opt[12..16], .big);
        if (opt_id == constants.negotiation_id_option_go) {
            var name_len_buf: [4]u8 = undefined;
            try fdReadExact(fd, &name_len_buf);
            const name_len = std.mem.readInt(u32, name_len_buf[0..4], .big);
            var name: [64]u8 = undefined;
            try fdReadExact(fd, name[0..name_len]);
            var info_count: [2]u8 = undefined;
            try fdReadExact(fd, &info_count);
            try sendExportInfoFd(fd, opt_id, export_size);
            try sendNameInfoFd(fd, opt_id, "default");
            try sendDescriptionInfoFd(fd, opt_id, "");
            try sendBlockSizeInfoFd(fd, opt_id);
            try sendAckFd(fd, opt_id);
            return;
        }
        try discardFd(fd, opt_len);
    }
}

fn clientNegotiateFd(fd: i32) !void {
    var header: [18]u8 = undefined;
    try fdReadExact(fd, &header);
    var client_flags: [4]u8 = undefined;
    std.mem.writeInt(u32, client_flags[0..4], 3, .big);
    try fdWriteAll(fd, &client_flags);
    const export_name = "default";
    const opt_len: u32 = @intCast(4 + export_name.len + 2);
    var opt_hdr: [16]u8 = undefined;
    std.mem.writeInt(u64, opt_hdr[0..8], constants.negotiation_magic_option, .big);
    std.mem.writeInt(u32, opt_hdr[8..12], constants.negotiation_id_option_go, .big);
    std.mem.writeInt(u32, opt_hdr[12..16], opt_len, .big);
    try fdWriteAll(fd, &opt_hdr);
    var opt_data: [128]u8 = undefined;
    std.mem.writeInt(u32, opt_data[0..4], @intCast(export_name.len), .big);
    @memcpy(opt_data[4 .. 4 + export_name.len], export_name);
    std.mem.writeInt(u16, opt_data[4 + export_name.len .. 4 + export_name.len + 2], 0, .big);
    try fdWriteAll(fd, opt_data[0 .. 4 + export_name.len + 2]);
    while (true) {
        var reply: [20]u8 = undefined;
        try fdReadExact(fd, &reply);
        const rep_type = std.mem.readInt(u32, reply[12..16], .big);
        const rep_len = std.mem.readInt(u32, reply[16..20], .big);
        if (rep_type == constants.negotiation_type_reply_ack) break;
        try discardFd(fd, rep_len);
    }
}

fn sendExportInfoFd(fd: i32, opt_id: u32, size: u64) !void {
    var info: [12]u8 = undefined;
    std.mem.writeInt(u16, info[0..2], constants.negotiation_type_info_export, .big);
    std.mem.writeInt(u64, info[2..10], size, .big);
    std.mem.writeInt(u16, info[10..12], 1 | 256, .big); // HAS_FLAGS | CAN_MULTI_CONN
    try sendReplyInfoFd(fd, opt_id, &info);
}

fn sendNameInfoFd(fd: i32, opt_id: u32, name: []const u8) !void {
    var payload: [2 + 64]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], constants.negotiation_type_info_name, .big);
    @memcpy(payload[2 .. 2 + name.len], name);
    try sendReplyInfoFd(fd, opt_id, payload[0 .. 2 + name.len]);
}

fn sendDescriptionInfoFd(fd: i32, opt_id: u32, desc: []const u8) !void {
    var payload: [2 + 256]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], constants.negotiation_type_info_description, .big);
    if (desc.len > 0) @memcpy(payload[2 .. 2 + desc.len], desc);
    try sendReplyInfoFd(fd, opt_id, payload[0 .. 2 + desc.len]);
}

fn sendBlockSizeInfoFd(fd: i32, opt_id: u32) !void {
    var info: [14]u8 = undefined;
    std.mem.writeInt(u16, info[0..2], constants.negotiation_type_info_blocksize, .big);
    std.mem.writeInt(u32, info[2..6], 1, .big);
    std.mem.writeInt(u32, info[6..10], @intCast(constants.block_size), .big);
    std.mem.writeInt(u32, info[10..14], 32 * 1024 * 1024, .big);
    try sendReplyInfoFd(fd, opt_id, &info);
}

fn sendReplyInfoFd(fd: i32, opt_id: u32, payload: []const u8) !void {
    var rh: [20]u8 = undefined;
    std.mem.writeInt(u64, rh[0..8], constants.negotiation_magic_reply, .big);
    std.mem.writeInt(u32, rh[8..12], opt_id, .big);
    std.mem.writeInt(u32, rh[12..16], constants.negotiation_type_reply_info, .big);
    std.mem.writeInt(u32, rh[16..20], @intCast(payload.len), .big);
    try fdWriteAll(fd, &rh);
    try fdWriteAll(fd, payload);
}

fn sendAckFd(fd: i32, opt_id: u32) !void {
    var rh: [20]u8 = undefined;
    std.mem.writeInt(u64, rh[0..8], constants.negotiation_magic_reply, .big);
    std.mem.writeInt(u32, rh[8..12], opt_id, .big);
    std.mem.writeInt(u32, rh[12..16], constants.negotiation_type_reply_ack, .big);
    std.mem.writeInt(u32, rh[16..20], 0, .big);
    try fdWriteAll(fd, &rh);
}

fn setBlocking(fd: i32) void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return;
    const nonblock: c_int = 0x800;
    _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @intCast(flags)) & ~nonblock);
}

fn fdWriteAll(fd: i32, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + off, bytes.len - off);
        const n_isize: isize = @bitCast(n);
        if (n_isize < 0) return std.posix.unexpectedErrno(std.os.linux.errno(n));
        if (n_isize == 0) return error.WriteFailed;
        off += @intCast(n_isize);
    }
}

fn fdReadExact(fd: i32, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = std.c.read(fd, buf.ptr + off, buf.len - off);
        const n_isize: isize = @bitCast(n);
        if (n_isize < 0) return std.posix.unexpectedErrno(std.os.linux.errno(n));
        if (n_isize == 0) return error.UnexpectedEof;
        off += @intCast(n_isize);
    }
}

fn discardFd(fd: i32, n: u32) !void {
    var scratch: [4096]u8 = undefined;
    var left = n;
    while (left > 0) {
        const chunk: usize = @min(left, scratch.len);
        try fdReadExact(fd, scratch[0..chunk]);
        left -= @intCast(chunk);
    }
}

fn writeAll(io: std.Io, stream: std.Io.net.Stream, bytes: []const u8) !void {
    var wbuf: [4096]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

fn readExact(io: std.Io, stream: std.Io.net.Stream, buf: []u8) !void {
    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    try r.interface.readSliceAll(buf);
}

fn discard(io: std.Io, stream: std.Io.net.Stream, n: u32) !void {
    var scratch: [4096]u8 = undefined;
    var left = n;
    while (left > 0) {
        const chunk: usize = @min(left, scratch.len);
        try readExact(io, stream, scratch[0..chunk]);
        left -= @intCast(chunk);
    }
}

fn ioctl(fd: i32, request: u64, arg: u64) !void {
    const rc_raw = std.os.linux.ioctl(fd, @intCast(request), @intCast(arg));
    const rc: isize = @bitCast(rc_raw);
    if (rc < 0) return std.posix.unexpectedErrno(std.os.linux.errno(rc_raw));
}
