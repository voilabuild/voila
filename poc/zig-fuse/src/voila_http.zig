const std = @import("std");
const curl_c = @import("curl_c");

const http_timeout_seconds: c_long = 120;

/// GET url with optional Authorization: Bearer header. Returns owned body.
/// Uses libcurl (blocking) so registry fetch works from the voilad gRPC thread.
pub fn httpGet(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    bearer_token: []const u8,
) ![]u8 {
    _ = io;
    const url_z = try allocator.allocSentinel(u8, url.len, 0);
    defer allocator.free(url_z);
    @memcpy(url_z, url);

    var token_ptr: [*:0]const u8 = "";
    var token_buf: ?[:0]u8 = null;
    if (bearer_token.len != 0) {
        token_buf = try allocator.allocSentinel(u8, bearer_token.len, 0);
        @memcpy(token_buf.?, bearer_token);
        token_ptr = token_buf.?.ptr;
    }
    defer if (token_buf) |tb| allocator.free(tb);

    var out_ptr: [*c]u8 = null;
    var out_len: usize = 0;
    const rc = curl_c.voila_curl_http_get(url_z.ptr, token_ptr, http_timeout_seconds, &out_ptr, &out_len);
    if (rc != 0 or out_len == 0 or out_ptr == null) return error.HttpStatus;

    const owned = try allocator.dupe(u8, out_ptr[0..out_len]);
    curl_c.voila_curl_free(out_ptr);
    return owned;
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
