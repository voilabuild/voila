//! Opt-in timing trace. `VOILA_TRACE=<file>` makes every voila process (the CLI, the
//! FUSE server, the namespace child) append Chrome trace events to one file; open it in
//! https://ui.perfetto.dev or summarize it with `tools/trace_summary.py`.
//!
//! Each event is one `write(2)` on an `O_APPEND` fd, so processes and threads interleave
//! whole lines. Timestamps are CLOCK_MONOTONIC microseconds, shared by all processes.
//! The file is a JSON array without the closing `]`, which the trace viewers accept.
const std = @import("std");
const linux = std.os.linux;

/// -1: not opened (or `VOILA_TRACE` unset); opened once by `init` before any thread starts.
var fd: std.c.fd_t = -1;
var pid: i32 = 0;
/// The whole-process span, emitted from `atexit` because commands leave through `exit`.
var process_start: u64 = 0;
var process_label: [64]u8 = undefined;
var process_label_len: usize = 0;

/// Opens `VOILA_TRACE` if set. Call once at process start, before namespaces or
/// `pivot_root` change what the path refers to. A failure leaves tracing off.
pub fn init(process_name: []const u8) void {
    if (fd >= 0) return;
    const path = std.c.getenv("VOILA_TRACE") orelse return;
    if (path[0] == 0) return;
    const created = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .APPEND = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o644));
    if (created >= 0) {
        fd = created;
        writeAll("[\n");
    } else {
        fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .APPEND = true, .CLOEXEC = true }, @as(std.c.mode_t, 0));
        if (fd < 0) return;
    }
    pid = std.c.getpid();
    process_start = nowUs();
    process_label_len = @min(process_name.len, process_label.len);
    @memcpy(process_label[0..process_label_len], process_name[0..process_label_len]);
    _ = atexit(onExit); // without the hook only the process span is missing
    emit("{{\"name\":\"process_name\",\"ph\":\"M\",\"pid\":{d},\"tid\":{d},\"args\":{{\"name\":\"{s} ({d})\"}}}}", .{ pid, pid, process_name, pid });
}

/// Stops tracing in this process, before it closes fds it does not know about.
pub fn close() void {
    if (fd < 0) return;
    _ = std.c.close(fd); // nothing to do if close fails; the fd is forgotten either way
    fd = -1;
}

pub fn enabled() bool {
    return fd >= 0;
}

pub fn nowUs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.us_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_us;
}

/// A duration event; `start` is 0 when tracing is off, so ending it is free.
pub const Span = struct {
    name: []const u8,
    start: u64,

    pub fn end(self: Span) void {
        self.endArgs("", .{});
    }

    /// `fmt` renders the inside of the `args` object, e.g. `"\"bytes\":{d}"`.
    pub fn endArgs(self: Span, comptime fmt: []const u8, args: anytype) void {
        if (self.start == 0) return;
        const now = nowUs();
        var buf: [512]u8 = undefined;
        const a = std.fmt.bufPrint(&buf, fmt, args) catch ""; // over-long args are dropped, the span is kept
        emit("{{\"name\":\"{s}\",\"ph\":\"X\",\"ts\":{d},\"dur\":{d},\"pid\":{d},\"tid\":{d},\"args\":{{{s}}}}}", .{ self.name, self.start, now - self.start, pid, tid(), a });
    }
};

pub fn begin(name: []const u8) Span {
    return .{ .name = name, .start = if (enabled()) nowUs() else 0 };
}

/// A counter track (e.g. fetches in flight).
pub fn counter(name: []const u8, value: i64) void {
    if (!enabled()) return;
    emit("{{\"name\":\"{s}\",\"ph\":\"C\",\"ts\":{d},\"pid\":{d},\"tid\":{d},\"args\":{{\"value\":{d}}}}}", .{ name, nowUs(), pid, tid(), value });
}

/// A point in time on the calling thread.
pub fn instant(name: []const u8) void {
    if (!enabled()) return;
    emit("{{\"name\":\"{s}\",\"ph\":\"i\",\"s\":\"t\",\"ts\":{d},\"pid\":{d},\"tid\":{d}}}", .{ name, nowUs(), pid, tid() });
}

pub fn threadName(name: []const u8) void {
    if (!enabled()) return;
    emit("{{\"name\":\"thread_name\",\"ph\":\"M\",\"pid\":{d},\"tid\":{d},\"args\":{{\"name\":\"{s}\"}}}}", .{ pid, tid(), name });
}

/// Formats `s` as a JSON string (with quotes) for span args: `endArgs("\"path\":{f}", .{trace.str(p)})`.
pub fn str(s: []const u8) Str {
    return .{ .s = s };
}

pub const Str = struct {
    s: []const u8,

    pub fn format(self: Str, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeByte('"');
        for (self.s) |ch| switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            0...0x1f => try w.print("\\u{x:0>4}", .{ch}),
            else => try w.writeByte(ch),
        };
        try w.writeByte('"');
    }
};

fn onExit() callconv(.c) void {
    if (!enabled()) return;
    (Span{ .name = process_label[0..process_label_len], .start = process_start }).end();
}

fn tid() i32 {
    return @intCast(linux.gettid());
}

fn emit(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt ++ ",\n", args) catch return; // an event over 1 KiB is dropped; tracing is best-effort
    writeAll(line);
}

fn writeAll(s: []const u8) void {
    // One write per event keeps lines whole under O_APPEND; a short write only loses this event.
    _ = std.c.write(fd, s.ptr, s.len);
}

test "spans are free and silent when tracing is off" {
    try std.testing.expect(!enabled());
    const s = begin("x");
    try std.testing.expectEqual(@as(u64, 0), s.start);
    s.endArgs("\"n\":{d}", .{1});
    counter("c", 1);
}

test "init appends whole JSON events to the trace file" {
    const fs = @import("fs.zig");
    const a = std.testing.allocator;
    const dir = try fs.makeTempDir(a, "voila-trace");
    defer a.free(dir);
    defer fs.removeTree(a, dir) catch {}; // leftover temp dir is fine
    const path = try std.fmt.allocPrintSentinel(a, "{s}/t.json", .{dir}, 0);
    defer a.free(path);
    try std.testing.expectEqual(@as(c_int, 0), setenv("VOILA_TRACE", path, 1));
    defer _ = unsetenv("VOILA_TRACE");
    init("voila test");
    defer close();
    try std.testing.expect(enabled());
    const s = begin("fetch");
    s.endArgs("\"bytes\":{d},\"path\":{f}", .{ 42, str("/a\"b\\c\n") });
    counter("inflight", 3);

    const posix_util = @import("posix_util.zig");
    const got = try posix_util.readFileAlloc(a, path, 1 << 16);
    defer a.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "[\n"));
    // Closing the array must make it valid JSON with all three events.
    const closed = try std.fmt.allocPrint(a, "{s}{{}}]", .{got});
    defer a.free(closed);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, closed, .{});
    defer parsed.deinit();
    const events = parsed.value.array.items;
    try std.testing.expectEqual(@as(usize, 4), events.len);
    try std.testing.expectEqualStrings("fetch", events[1].object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 42), events[1].object.get("args").?.object.get("bytes").?.integer);
    try std.testing.expectEqualStrings("/a\"b\\c\n", events[1].object.get("args").?.object.get("path").?.string);
}

extern "c" fn atexit(f: *const fn () callconv(.c) void) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
