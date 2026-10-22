const std = @import("std");

pub const Error = error{
    Truncated,
    BadWireType,
    BadUtf8,
};

pub fn readVarint(data: []const u8, off: *usize) Error!u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (off.* < data.len) {
        const b = data[off.*];
        off.* += 1;
        result |= @as(u64, b & 0x7f) << shift;
        if ((b & 0x80) == 0) return result;
        shift += 7;
        if (shift > 63) return Error.Truncated;
    }
    return Error.Truncated;
}

pub fn readTag(data: []const u8, off: *usize) Error!struct { field: u32, wire: u3 } {
    const tag = try readVarint(data, off);
    return .{
        .field = @intCast(tag >> 3),
        .wire = @intCast(tag & 7),
    };
}

pub fn skipField(data: []const u8, off: *usize, wire: u3) Error!void {
    switch (wire) {
        0 => _ = try readVarint(data, off),
        1 => {
            if (off.* + 8 > data.len) return Error.Truncated;
            off.* += 8;
        },
        2 => {
            const len = try readVarint(data, off);
            const n = std.math.cast(usize, len) orelse return Error.Truncated;
            if (off.* + n > data.len) return Error.Truncated;
            off.* += n;
        },
        5 => {
            if (off.* + 4 > data.len) return Error.Truncated;
            off.* += 4;
        },
        else => return Error.BadWireType,
    }
}

pub fn readLenDelim(data: []const u8, off: *usize) Error![]const u8 {
    const len = try readVarint(data, off);
    const n = std.math.cast(usize, len) orelse return Error.Truncated;
    if (off.* + n > data.len) return Error.Truncated;
    const slice = data[off.* .. off.* + n];
    off.* += n;
    return slice;
}

pub fn readU32(data: []const u8, off: *usize) Error!u32 {
    const v = try readVarint(data, off);
    return @intCast(v);
}

pub fn readU64(data: []const u8, off: *usize) Error!u64 {
    return readVarint(data, off);
}

pub fn readString(data: []const u8, off: *usize) Error![]const u8 {
    const bytes = try readLenDelim(data, off);
    if (!std.unicode.utf8ValidateSlice(bytes)) return Error.BadUtf8;
    return bytes;
}
