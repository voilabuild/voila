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
        self.off = self.next_header;
        self.content_remaining = 0;
        if (self.off + 512 > self.data.len) return null;
        const block = self.data[self.off .. self.off + 512];
        var all_zero = true;
        for (block) |b| {
            if (b != 0) all_zero = false;
        }
        if (all_zero) return null;

        const name_raw = trimNull(block[0..100]);
        const mode = parseOct(block[100..108]);
        const uid: u32 = @intCast(parseOct(block[108..116]));
        const gid: u32 = @intCast(parseOct(block[116..124]));
        const size = parseOct(block[124..136]);
        const mtime: i64 = @intCast(parseOct(block[136..148]));
        const typeflag = block[156];
        const linkname = trimNull(block[157..257]);
        const name = if (name_raw.len == 0) linkname else name_raw;

        self.off += 512;
        self.content_remaining = size;
        self.next_header = self.off + @as(usize, @intCast((size + 511) & ~@as(u64, 511)));

        return .{
            .name = try allocator.dupe(u8, name),
            .mode = @intCast(mode & 0o7777),
            .uid = uid,
            .gid = gid,
            .size = size,
            .mtime = mtime,
            .typeflag = typeflag,
            .linkname = try allocator.dupe(u8, linkname),
        };
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

fn parseOct(s: []const u8) u64 {
    var v: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '7') break;
        v = (v << 3) + @as(u64, c - '0');
    }
    return v;
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
