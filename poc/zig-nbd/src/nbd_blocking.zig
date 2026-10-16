const std = @import("std");
const constants = @import("constants.zig");
const backend = @import("backend.zig");

pub fn attachAndServe(io: std.Io, dev: *backend.Device, nbd_path: []const u8) !void {
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
    defer client.close(io);

    accept_thread.join();
    if (accept_err != null) return accept_err.?;
    const server_stream = accepted orelse return error.NoConnection;

    const serve_thread = try std.Thread.spawn(.{}, struct {
        fn run(io_inner: std.Io, stream: std.Io.net.Stream, device: *backend.Device) void {
            defer stream.close(io_inner);
            serveConnection(io_inner, stream, device) catch {};
        }
    }.run, .{ io, server_stream, dev });

    try clientNegotiate(io, client);

    const sock_fd = client.socket.handle;
    var nbd_z: [64]u8 = undefined;
    if (nbd_path.len >= nbd_z.len) return error.NameTooLong;
    @memcpy(nbd_z[0..nbd_path.len], nbd_path);
    nbd_z[nbd_path.len] = 0;
    const nbd_fd = std.os.linux.open(nbd_z[0..nbd_path.len :0], .{ .ACCMODE = .RDWR }, 0);
    if (nbd_fd < 0) return error.NbdOpen;
    defer _ = std.c.close(@intCast(nbd_fd));

    try ioctl(@intCast(nbd_fd), constants.nbd_set_sock, @intCast(sock_fd));
    try ioctl(@intCast(nbd_fd), constants.nbd_set_blksize, constants.block_size);
    const num_blocks = (dev.device_size + constants.block_size - 1) / constants.block_size;
    try ioctl(@intCast(nbd_fd), constants.nbd_set_size_blocks, num_blocks);
    try ioctl(@intCast(nbd_fd), constants.nbd_set_flags, constants.nbd_flag_has_flags | constants.nbd_flag_read_only);

    const do_it = try std.Thread.spawn(.{}, struct {
        fn run(fd: i32) void {
            ioctl(fd, constants.nbd_do_it, 0) catch {};
        }
    }.run, .{@as(i32, @intCast(nbd_fd))});
    do_it.join();
    ioctl(@intCast(nbd_fd), constants.nbd_disconnect, 0) catch {};
    ioctl(@intCast(nbd_fd), constants.nbd_clear_sock, 0) catch {};
    serve_thread.join();
}

fn serveConnection(io: std.Io, stream: std.Io.net.Stream, dev: *backend.Device) !void {
    var hdr: [18]u8 = undefined;
    std.mem.writeInt(u64, hdr[0..8], constants.negotiation_magic_oldstyle, .big);
    std.mem.writeInt(u64, hdr[8..16], constants.negotiation_magic_option, .big);
    std.mem.writeInt(u16, hdr[16..18], 1, .big);
    try writeAll(io, stream, &hdr);

    var client_flags: [4]u8 = undefined;
    try readExact(io, stream, &client_flags);
    try serverNegotiate(io, stream, dev.device_size);

    var req_buf: [32 * 1024 * 1024]u8 = undefined;
    while (true) {
        var req_hdr: [28]u8 = undefined;
        try readExact(io, stream, &req_hdr);
        const cmd = std.mem.readInt(u32, req_hdr[4..8], .big);
        const handle = req_hdr[8..16];
        const offset = std.mem.readInt(u64, req_hdr[16..24], .big);
        const length = std.mem.readInt(u32, req_hdr[24..28], .big);
        switch (cmd) {
            constants.nbd_cmd_read => {
                var reply: [16]u8 = undefined;
                std.mem.writeInt(u32, reply[0..4], constants.transmission_magic_reply, .big);
                @memcpy(reply[8..16], handle);
                try writeAll(io, stream, &reply);
                const slice = req_buf[0..length];
                dev.preloadSlotsForRange(io, offset, length) catch {};
                dev.readAt(io, slice, offset) catch {};
                try writeAll(io, stream, slice);
            },
            constants.nbd_cmd_write => {
                try discard(io, stream, length);
                var reply: [16]u8 = undefined;
                std.mem.writeInt(u32, reply[0..4], constants.transmission_magic_reply, .big);
                std.mem.writeInt(u32, reply[4..8], 1, .big);
                @memcpy(reply[8..16], handle);
                try writeAll(io, stream, &reply);
            },
            constants.nbd_cmd_disc => return,
            else => return error.BadCmd,
        }
    }
}

fn serverNegotiate(io: std.Io, stream: std.Io.net.Stream, export_size: u64) !void {
    while (true) {
        var opt: [16]u8 = undefined;
        try readExact(io, stream, &opt);
        const opt_id = std.mem.readInt(u32, opt[8..12], .big);
        const opt_len = std.mem.readInt(u32, opt[12..16], .big);
        if (opt_id == constants.negotiation_id_option_go) {
            var name_len_buf: [4]u8 = undefined;
            try readExact(io, stream, &name_len_buf);
            const name_len = std.mem.readInt(u32, name_len_buf[0..4], .big);
            var name: [64]u8 = undefined;
            try readExact(io, stream, name[0..name_len]);
            var info_count: [2]u8 = undefined;
            try readExact(io, stream, &info_count);
            try sendExportInfo(io, stream, opt_id, export_size);
            try sendAck(io, stream, opt_id);
            return;
        }
        try discard(io, stream, opt_len);
    }
}

fn clientNegotiate(io: std.Io, stream: std.Io.net.Stream) !void {
    var header: [18]u8 = undefined;
    try readExact(io, stream, &header);
    var client_flags: [4]u8 = undefined;
    std.mem.writeInt(u32, client_flags[0..4], 3, .big);
    try writeAll(io, stream, &client_flags);
    const export_name = "default";
    const opt_len: u32 = @intCast(4 + export_name.len + 2);
    var opt_hdr: [16]u8 = undefined;
    std.mem.writeInt(u64, opt_hdr[0..8], constants.negotiation_magic_option, .big);
    std.mem.writeInt(u32, opt_hdr[8..12], constants.negotiation_id_option_go, .big);
    std.mem.writeInt(u32, opt_hdr[12..16], opt_len, .big);
    try writeAll(io, stream, &opt_hdr);
    var opt_data: [128]u8 = undefined;
    std.mem.writeInt(u32, opt_data[0..4], @intCast(export_name.len), .big);
    @memcpy(opt_data[4 .. 4 + export_name.len], export_name);
    std.mem.writeInt(u16, opt_data[4 + export_name.len .. 4 + export_name.len + 2], 0, .big);
    try writeAll(io, stream, opt_data[0 .. 4 + export_name.len + 2]);
    while (true) {
        var reply: [20]u8 = undefined;
        try readExact(io, stream, &reply);
        const rep_type = std.mem.readInt(u32, reply[12..16], .big);
        const rep_len = std.mem.readInt(u32, reply[16..20], .big);
        if (rep_type == constants.negotiation_type_reply_ack) break;
        try discard(io, stream, rep_len);
    }
}

fn sendExportInfo(io: std.Io, stream: std.Io.net.Stream, opt_id: u32, size: u64) !void {
    var info: [12]u8 = undefined;
    std.mem.writeInt(u16, info[0..2], constants.negotiation_type_info_export, .big);
    std.mem.writeInt(u64, info[2..10], size, .big);
    try sendReplyInfo(io, stream, opt_id, &info);
}

fn sendReplyInfo(io: std.Io, stream: std.Io.net.Stream, opt_id: u32, payload: []const u8) !void {
    var rh: [20]u8 = undefined;
    std.mem.writeInt(u64, rh[0..8], constants.negotiation_magic_reply, .big);
    std.mem.writeInt(u32, rh[8..12], opt_id, .big);
    std.mem.writeInt(u32, rh[12..16], constants.negotiation_type_reply_info, .big);
    std.mem.writeInt(u32, rh[16..20], @intCast(payload.len), .big);
    try writeAll(io, stream, &rh);
    try writeAll(io, stream, payload);
}

fn sendAck(io: std.Io, stream: std.Io.net.Stream, opt_id: u32) !void {
    var rh: [20]u8 = undefined;
    std.mem.writeInt(u64, rh[0..8], constants.negotiation_magic_reply, .big);
    std.mem.writeInt(u32, rh[8..12], opt_id, .big);
    std.mem.writeInt(u32, rh[12..16], constants.negotiation_type_reply_ack, .big);
    try writeAll(io, stream, &rh);
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
    const rc = std.os.linux.ioctl(fd, @intCast(request), @intCast(arg));
    if (rc < 0) return std.posix.unexpectedErrno(std.posix.errno(@intCast(rc)));
}
