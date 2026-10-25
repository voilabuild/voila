const std = @import("std");

/// GET url with optional Authorization: Bearer header. Returns owned body.
/// Uses std.http so the CLI does not link libcurl or its shared dependencies.
pub fn httpPostStatus(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    bearer_token: []const u8,
    body: []const u8,
) !u16 {
    var auth_buf: [8192]u8 = undefined;
    const authorization: std.http.Client.Request.Headers.Value = if (bearer_token.len == 0)
        .omit
    else
        .{ .override = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{bearer_token}) catch return error.HttpStatus };

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .keep_alive = false,
        .headers = .{
            .user_agent = .{ .override = "voila-zig-registry/1.0" },
            .authorization = authorization,
            .content_type = .{ .override = "application/json" },
        },
        .payload = body,
    }) catch return error.HttpStatus;
    return @backingInt(result.status);
}

pub fn httpPostJson(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    bearer_token: []const u8,
    body: []const u8,
) ![]u8 {
    var auth_buf: [8192]u8 = undefined;
    const authorization: std.http.Client.Request.Headers.Value = if (bearer_token.len == 0)
        .omit
    else
        .{ .override = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{bearer_token}) catch return error.HttpStatus };

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    var response: std.Io.Writer.Allocating = .init(allocator);
    defer response.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .keep_alive = false,
        .headers = .{
            .user_agent = .{ .override = "voila-zig-registry/1.0" },
            .authorization = authorization,
            .content_type = .{ .override = "application/json" },
        },
        .payload = body,
        .response_writer = &response.writer,
    }) catch return error.HttpStatus;

    const code: u16 = @backingInt(result.status);
    if (code < 200 or code >= 300) return error.HttpStatus;
    return response.toOwnedSlice();
}

pub fn httpPut(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    bearer_token: []const u8,
    body: []const u8,
    content_type: []const u8,
    content_encoding: ?[]const u8,
) !u16 {
    var auth_buf: [8192]u8 = undefined;
    const authorization: std.http.Client.Request.Headers.Value = if (bearer_token.len == 0)
        .omit
    else
        .{ .override = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{bearer_token}) catch return error.HttpStatus };

    var extra: [1]std.http.Header = undefined;
    var extra_headers: []const std.http.Header = &.{};
    if (content_encoding) |enc| {
        extra[0] = .{ .name = "Content-Encoding", .value = enc };
        extra_headers = extra[0..];
    }

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .PUT,
        .keep_alive = false,
        .headers = .{
            .user_agent = .{ .override = "voila-zig-registry/1.0" },
            .authorization = authorization,
            .content_type = .{ .override = content_type },
        },
        .extra_headers = extra_headers,
        .payload = body,
    }) catch return error.HttpStatus;
    return @backingInt(result.status);
}

pub fn httpGet(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    bearer_token: []const u8,
) ![]u8 {
    const resp = try httpGetResponse(io, allocator, url, bearer_token);
    if (resp.status < 200 or resp.status >= 300 or resp.body.len == 0) {
        allocator.free(resp.body);
        return error.HttpStatus;
    }
    return resp.body;
}

pub const Response = struct {
    status: u16,
    body: []u8,
};

/// GET that returns any status with its body (owned); errors only when no response came back.
pub fn httpGetResponse(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    bearer_token: []const u8,
) !Response {
    var auth_buf: [8192]u8 = undefined;
    const authorization: std.http.Client.Request.Headers.Value = if (bearer_token.len == 0)
        .omit
    else
        .{ .override = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{bearer_token}) catch return error.HttpStatus };

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    var response: std.Io.Writer.Allocating = .init(allocator);
    defer response.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .keep_alive = false,
        .headers = .{
            .user_agent = .{ .override = "voila-zig-registry/1.0" },
            .authorization = authorization,
        },
        .response_writer = &response.writer,
    }) catch return error.HttpStatus;

    return .{ .status = @backingInt(result.status), .body = try response.toOwnedSlice() };
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
