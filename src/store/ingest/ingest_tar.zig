const std = @import("std");
const zstd = @import("zstd");
const flate = @import("std").compress.flate;

pub const Compression = enum {
    unknown,
    raw,
    gzip,
    zstd,
};

const gzip_magic = [_]u8{ 0x1f, 0x8b };
const zstd_magic = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd };

pub fn sniffCompression(magic: []const u8) Compression {
    if (magic.len >= 2 and magic[0] == gzip_magic[0] and magic[1] == gzip_magic[1]) return .gzip;
    if (magic.len >= 4 and std.mem.eql(u8, magic[0..4], &zstd_magic)) return .zstd;
    return .raw;
}

pub fn mediaTypeHint(media_type: []const u8) Compression {
    if (std.mem.indexOf(u8, media_type, "gzip") != null) return .gzip;
    if (std.mem.indexOf(u8, media_type, "zstd") != null) return .zstd;
    return .raw;
}

pub const TarHeader = struct {
    name: []const u8,
    mode: u32,
    uid: u32,
    gid: u32,
    size: u64,
    mtime: i64,
    typeflag: u8,
    linkname: []const u8,
    devmajor: u32 = 0,
    devminor: u32 = 0,
};

/// Fields a PAX `x` record or GNU `L`/`K` entry sets for the next header.
const Override = struct {
    path: ?[]const u8 = null,
    linkpath: ?[]const u8 = null,
    size: ?u64 = null,
    uid: ?u32 = null,
    gid: ?u32 = null,
    mtime: ?i64 = null,
};

pub const TarStream = struct {
    data: []const u8,
    off: usize,
    content_remaining: u64,
    /// Offset of the next header: end of the current entry's content, padded to 512.
    next_header: usize,

    pub fn init(data: []const u8) TarStream {
        return .{ .data = data, .off = 0, .content_remaining = 0, .next_header = 0 };
    }

    pub fn next(self: *TarStream, allocator: std.mem.Allocator) !?TarHeader {
        var ov: Override = .{};
        while (true) {
            self.off = self.next_header;
            self.content_remaining = 0;
            if (self.off + 512 > self.data.len) return null;
            const block = self.data[self.off .. self.off + 512];
            if (std.mem.allEqual(u8, block, 0)) return null;

            const typeflag = block[156];
            var size = parseNum(block[124..136]);
            if (ov.size) |s| {
                if (typeflag != 'x' and typeflag != 'g' and typeflag != 'L' and typeflag != 'K') size = s;
            }
            self.off += 512;
            if (size > self.data.len - self.off) return error.ShortRead;
            const body = self.data[self.off..][0..@intCast(size)];
            self.content_remaining = size;
            self.next_header = self.off + @as(usize, @intCast((size + 511) & ~@as(u64, 511)));

            switch (typeflag) {
                'x' => {
                    parsePax(body, &ov);
                    continue;
                },
                'g' => continue,
                'L' => {
                    ov.path = trimNull(body);
                    continue;
                },
                'K' => {
                    ov.linkpath = trimNull(body);
                    continue;
                },
                else => {},
            }

            const name = ov.path orelse try ustarName(allocator, block);
            defer if (ov.path == null) allocator.free(name);
            const linkname = ov.linkpath orelse trimNull(block[157..257]);
            return .{
                .name = try allocator.dupe(u8, if (name.len == 0) linkname else name),
                .mode = @intCast(parseNum(block[100..108]) & 0o7777),
                .uid = ov.uid orelse @truncate(parseNum(block[108..116])),
                .gid = ov.gid orelse @truncate(parseNum(block[116..124])),
                .size = size,
                .mtime = ov.mtime orelse @intCast(parseNum(block[136..148]) & std.math.maxInt(i64)),
                .typeflag = typeflag,
                .linkname = try allocator.dupe(u8, linkname),
                .devmajor = @truncate(parseNum(block[329..337])),
                .devminor = @truncate(parseNum(block[337..345])),
            };
        }
    }

    pub fn read(self: *TarStream, buf: []u8) usize {
        if (self.content_remaining == 0) return 0;
        const avail = self.data[self.off..];
        const want = @min(buf.len, avail.len, @as(usize, @intCast(self.content_remaining)));
        if (want == 0) return 0;
        @memcpy(buf[0..want], avail[0..want]);
        self.off += want;
        self.content_remaining -= want;
        return want;
    }

    pub fn readAll(self: *TarStream, allocator: std.mem.Allocator, size: u64) ![]u8 {
        const out = try allocator.alloc(u8, @intCast(size));
        var got: usize = 0;
        while (got < out.len) {
            const n = self.read(out[got..]);
            if (n == 0) return error.ShortRead;
            got += n;
        }
        return out;
    }
};

fn trimNull(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, 0)) |i| return s[0..i];
    return std.mem.trim(u8, s, " \t");
}

/// Joins the ustar `prefix` field (bytes 345..500) and `name`.
fn ustarName(allocator: std.mem.Allocator, block: []const u8) ![]const u8 {
    const name = trimNull(block[0..100]);
    const is_ustar = std.mem.eql(u8, block[257..262], "ustar") and block[262] == 0;
    const prefix = if (is_ustar) trimNull(block[345..500]) else "";
    if (prefix.len == 0) return allocator.dupe(u8, name);
    return std.mem.concat(allocator, u8, &.{ prefix, "/", name });
}

/// Octal, or GNU base-256 when the high bit of the first byte is set.
fn parseNum(s: []const u8) u64 {
    if (s.len > 0 and s[0] & 0x80 != 0) {
        var v: u64 = s[0] & 0x7f;
        for (s[1..]) |c| v = (v << 8) | c;
        return v;
    }
    var v: u64 = 0;
    for (s) |c| {
        if (c == ' ' and v == 0) continue;
        if (c < '0' or c > '7') break;
        v = (v << 3) + @as(u64, c - '0');
    }
    return v;
}

/// Records are `<len> <key>=<value>\n`; malformed records end parsing.
fn parsePax(body: []const u8, ov: *Override) void {
    var rest = body;
    while (rest.len > 0) {
        const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return;
        const len = std.fmt.parseInt(usize, rest[0..sp], 10) catch return;
        if (len <= sp + 1 or len > rest.len or rest[len - 1] != '\n') return;
        const rec = rest[sp + 1 .. len - 1];
        rest = rest[len..];
        const eq = std.mem.indexOfScalar(u8, rec, '=') orelse continue;
        const key = rec[0..eq];
        const val = rec[eq + 1 ..];
        if (std.mem.eql(u8, key, "path")) {
            ov.path = val;
        } else if (std.mem.eql(u8, key, "linkpath")) {
            ov.linkpath = val;
        } else if (std.mem.eql(u8, key, "size")) {
            ov.size = std.fmt.parseInt(u64, val, 10) catch continue;
        } else if (std.mem.eql(u8, key, "uid")) {
            ov.uid = std.fmt.parseInt(u32, val, 10) catch continue;
        } else if (std.mem.eql(u8, key, "gid")) {
            ov.gid = std.fmt.parseInt(u32, val, 10) catch continue;
        } else if (std.mem.eql(u8, key, "mtime")) {
            const whole = val[0 .. std.mem.indexOfScalar(u8, val, '.') orelse val.len];
            ov.mtime = std.fmt.parseInt(i64, whole, 10) catch continue;
        }
    }
}

pub fn decompressLayer(allocator: std.mem.Allocator, blob: []const u8, hint: Compression) ![]u8 {
    const sniffed = sniffCompression(blob);
    var chosen = sniffed;
    if (chosen == .raw and (hint == .gzip or hint == .zstd)) chosen = hint;

    switch (chosen) {
        .raw => return allocator.dupe(u8, blob),
        .gzip => {
            var in: std.Io.Reader = .fixed(blob);
            var decompress: flate.Decompress = .init(&in, .gzip, &.{});
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            _ = try decompress.reader.streamRemaining(&aw.writer);
            return aw.toOwnedSlice();
        },
        .zstd => {
            const bound = zstd.ZSTD_decompressBound(blob.ptr, blob.len);
            if (zstd.ZSTD_isError(bound) != 0) return error.ZstdDecode;
            const out = try allocator.alloc(u8, @intCast(bound));
            errdefer allocator.free(out);
            const n = zstd.ZSTD_decompress(out.ptr, out.len, blob.ptr, blob.len);
            if (zstd.ZSTD_isError(n) != 0) return error.ZstdDecode;
            return out[0..@intCast(n)];
        },
        .unknown => return error.UnsupportedCompression,
    }
}

pub const Error = error{
    ShortRead,
    UnsupportedCompression,
    ZstdDecode,
};

fn testHeader(buf: []u8, name: []const u8, size: u64) void {
    @memset(buf[0..512], 0);
    @memcpy(buf[0..name.len], name);
    _ = std.fmt.bufPrint(buf[100..107], "{o:0>7}", .{0o644}) catch unreachable;
    _ = std.fmt.bufPrint(buf[124..135], "{o:0>11}", .{size}) catch unreachable;
    buf[156] = '0';
}

test "next header is found after fully, partially and un-read entries" {
    const a = std.testing.allocator;
    var data: [512 * 8]u8 = @splat(0);
    testHeader(data[0..], "a", 6);
    @memcpy(data[512..518], "hello\n");
    testHeader(data[1024..], "b", 7);
    @memcpy(data[1536..1543], "second\n");
    testHeader(data[2048..], "c", 3);
    @memcpy(data[2560..2563], "end");

    var tr = TarStream.init(&data);
    const names = [_][]const u8{ "a", "b", "c" };
    const reads = [_]u64{ 6, 2, 0 };
    for (names, reads) |want, n| {
        const h = (try tr.next(a)).?;
        defer a.free(h.name);
        defer a.free(h.linkname);
        try std.testing.expectEqualStrings(want, h.name);
        const body = try tr.readAll(a, n);
        a.free(body);
    }
    try std.testing.expect((try tr.next(a)) == null);
}

fn testEntry(out: []u8, typeflag: u8, name: []const u8, body: []const u8) usize {
    testHeader(out, name, body.len);
    out[156] = typeflag;
    @memcpy(out[512..][0..body.len], body);
    return 512 + ((body.len + 511) & ~@as(usize, 511));
}

test "ustar prefix, PAX and GNU long names" {
    const a = std.testing.allocator;
    var data: [512 * 12]u8 = @splat(0);
    var off: usize = 0;
    off += testEntry(data[off..], '0', "file.js", "");
    @memcpy(data[257..263], "ustar\x00");
    @memcpy(data[345..][0..7], "pre/fix");
    off += testEntry(data[off..], 'x', "PaxHeaders/x", "26 path=pax/long/name.txt\n");
    off += testEntry(data[off..], '0', "trunc", "abc");
    off += testEntry(data[off..], 'L', "././@LongLink", "gnu/long/name\x00");
    off += testEntry(data[off..], '0', "gnu-trunc", "");
    off += testEntry(data[off..], 'K', "././@LongLink", "gnu/target\x00");
    off += testEntry(data[off..], '1', "hard", "");

    var tr = TarStream.init(&data);
    const want = [_][]const u8{ "pre/fix/file.js", "pax/long/name.txt", "gnu/long/name", "hard" };
    for (want, 0..) |w, i| {
        const h = (try tr.next(a)).?;
        defer a.free(h.name);
        defer a.free(h.linkname);
        try std.testing.expectEqualStrings(w, h.name);
        if (i == 1) try std.testing.expectEqual(@as(u64, 3), h.size);
        if (i == 3) try std.testing.expectEqualStrings("gnu/target", h.linkname);
    }
    try std.testing.expect((try tr.next(a)) == null);
}

test "base-256 numeric fields" {
    var f: [12]u8 = @splat(0);
    f[0] = 0x80;
    f[10] = 0x01;
    f[11] = 0x02;
    try std.testing.expectEqual(@as(u64, 0x0102), parseNum(&f));
    try std.testing.expectEqual(@as(u64, 0o755), parseNum("0000755\x00"));
}
