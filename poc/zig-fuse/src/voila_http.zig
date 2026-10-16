const std = @import("std");

/// GET url with optional Authorization: Bearer header. Returns owned body.
/// Uses curl subprocess so registry fetch works from the voilad gRPC thread.
pub fn httpGet(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    bearer_token: []const u8,
) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "curl", "-fsSL", "--max-time", "120" });
    var auth_hdr: ?[]const u8 = null;
    if (bearer_token.len != 0) {
        auth_hdr = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{bearer_token});
        try argv.append(allocator, "-H");
        try argv.append(allocator, auth_hdr.?);
    }
    defer if (auth_hdr) |h| allocator.free(h);
    try argv.append(allocator, url);

    const res = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    });
    defer allocator.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code != 0) return error.HttpStatus,
        else => return error.HttpStatus,
    }
    return res.stdout;
}

/// Go url.QueryEscape for registry image paths.
pub fn queryEscape(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        const unreserved = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.' or c == '~';
        if (unreserved) {
            try out.append(allocator, c);
        } else {
            const hex = "0123456789abcdef";
            try out.append(allocator, '%');
            try out.append(allocator, hex[c >> 4]);
            try out.append(allocator, hex[c & 0xf]);
        }
    }
    return out.toOwnedSlice(allocator);
}

pub const Error = error{
    BadUrl,
    HttpStatus,
};
