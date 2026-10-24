const std = @import("std");

const c = std.c;
const TIOCGWINSZ: u64 = 0x5413;
const TIOCSWINSZ: u64 = 0x5414;

extern "c" fn login_tty(fd: c_int) c_int;

pub const Pty = struct {
    master: std.posix.fd_t,
    slave: std.posix.fd_t,

    pub fn close(self: *Pty) void {
        if (self.master >= 0) _ = c.close(self.master);
        if (self.slave >= 0) _ = c.close(self.slave);
        self.master = -1;
        self.slave = -1;
    }

    pub fn useSlaveInChild(self: *Pty) !void {
        _ = c.close(self.master);
        self.master = -1;
        if (login_tty(self.slave) != 0) return error.PtyLoginFailed;
        self.slave = -1;
    }
};

pub fn copyTerminalToMaster(master: std.posix.fd_t) void {
    const stdin_fd = c.STDIN_FILENO;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(stdin_fd, &buf, buf.len);
        if (n <= 0) break;
        writeAll(master, buf[0..@intCast(n)]);
    }
}

pub fn pumpMasterToStdout(master: std.posix.fd_t) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(master, &buf, buf.len);
        if (n <= 0) break;
        writeAll(c.STDOUT_FILENO, buf[0..@intCast(n)]);
    }
}

pub fn syncWindowSize(master: std.posix.fd_t) void {
    var ws: std.posix.winsize = undefined;
    if (c.ioctl(c.STDIN_FILENO, TIOCGWINSZ, &ws) == 0) {
        _ = c.ioctl(master, TIOCSWINSZ, &ws);
    }
}

fn writeAll(fd: std.posix.fd_t, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = c.write(fd, data[off..].ptr, data.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

pub const Error = error{
    PtyOpenFailed,
    PtyLoginFailed,
};
