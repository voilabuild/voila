const std = @import("std");

const log = std.log.scoped(.registry);
const request_timeout: std.Io.Duration = .fromSeconds(30);

/// Shared HTTP client for a push/pull session. Reusing the client avoids the
/// Cloudflare hang from a new client per request (#123).
pub const Session = struct {
    client: std.http.Client,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) Session {
        return .{ .client = .{ .allocator = allocator, .io = io } };
    }

    pub fn deinit(self: *Session) void {
        self.client.deinit();
    }

    pub fn postStatus(self: *Session, url: []const u8, bearer_token: []const u8, body: []const u8) !u16 {
        const result = try self.fetch(url, .POST, bearer_token, "application/json", null, body, null);
        return @backingInt(result.status);
    }

    pub fn postJson(self: *Session, allocator: std.mem.Allocator, url: []const u8, bearer_token: []const u8, body: []const u8) ![]u8 {
        var response: std.Io.Writer.Allocating = .init(allocator);
        defer response.deinit();
        const result = try self.fetch(url, .POST, bearer_token, "application/json", null, body, &response.writer);
        const code: u16 = @backingInt(result.status);
        if (code < 200 or code >= 300) return error.HttpStatus;
        return response.toOwnedSlice();
    }

    pub fn put(
        self: *Session,
        url: []const u8,
        bearer_token: []const u8,
        body: []const u8,
        content_type: []const u8,
        content_encoding: ?[]const u8,
    ) !u16 {
        const result = try self.fetch(url, .PUT, bearer_token, content_type, content_encoding, body, null);
        return @backingInt(result.status);
    }

    pub fn get(self: *Session, allocator: std.mem.Allocator, url: []const u8, bearer_token: []const u8) ![]u8 {
        const resp = try self.getResponse(allocator, url, bearer_token);
        if (resp.status < 200 or resp.status >= 300 or resp.body.len == 0) {
            allocator.free(resp.body);
            return error.HttpStatus;
        }
        return resp.body;
    }

    pub fn getResponse(self: *Session, allocator: std.mem.Allocator, url: []const u8, bearer_token: []const u8) !Response {
        var response: std.Io.Writer.Allocating = .init(allocator);
        defer response.deinit();
        const result = try self.fetch(url, .GET, bearer_token, null, null, null, &response.writer);
        return .{ .status = @backingInt(result.status), .body = try response.toOwnedSlice() };
    }

    fn fetch(
        self: *Session,
        url: []const u8,
        method: std.http.Method,
        bearer_token: []const u8,
        content_type: ?[]const u8,
        content_encoding: ?[]const u8,
        payload: ?[]const u8,
        response_writer: ?*std.Io.Writer,
    ) !std.http.Client.FetchResult {
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

        const opts: std.http.Client.FetchOptions = .{
            .location = .{ .url = url },
            .method = method,
            .keep_alive = false,
            .headers = .{
                .user_agent = .{ .override = "voila-zig-registry/1.0" },
                .authorization = authorization,
                .content_type = if (content_type) |ct| .{ .override = ct } else .omit,
            },
            .extra_headers = extra_headers,
            .payload = payload,
            .response_writer = response_writer,
        };
        return fetchTimed(&self.client, opts) catch |e| switch (e) {
            error.Timeout => {
                log.err("registry request timed out: {s}", .{url});
                return error.Timeout;
            },
            else => return error.HttpStatus,
        };
    }
};

fn fetchTimed(client: *std.http.Client, opts: std.http.Client.FetchOptions) !std.http.Client.FetchResult {
    const Result = union(enum) {
        fetch: std.http.Client.FetchError!std.http.Client.FetchResult,
        timeout: void,
    };
    var buf: [2]Result = undefined;
    var sel = std.Io.Select(Result).init(client.io, &buf);
    sel.concurrent(.fetch, runFetch, .{ client, opts }) catch return client.fetch(opts);
    sel.async(.timeout, sleepRequestTimeout, .{client.io});
    const first = sel.await() catch {
        sel.cancelDiscard();
        return error.HttpStatus;
    };
    sel.cancelDiscard();
    return switch (first) {
        .fetch => |r| r,
        .timeout => error.Timeout,
    };
}

fn runFetch(client: *std.http.Client, opts: std.http.Client.FetchOptions) std.http.Client.FetchError!std.http.Client.FetchResult {
    return client.fetch(opts);
}

fn sleepRequestTimeout(io: std.Io) void {
    io.sleep(request_timeout, .awake) catch {};
}

pub fn httpPostStatus(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    bearer_token: []const u8,
    body: []const u8,
) !u16 {
    var s = Session.init(io, allocator);
    defer s.deinit();
    return s.postStatus(url, bearer_token, body);
}

pub fn httpPostJson(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    bearer_token: []const u8,
    body: []const u8,
) ![]u8 {
    var s = Session.init(io, allocator);
    defer s.deinit();
    return s.postJson(allocator, url, bearer_token, body);
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
    var s = Session.init(io, allocator);
    defer s.deinit();
    return s.put(url, bearer_token, body, content_type, content_encoding);
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
    var s = Session.init(io, allocator);
    defer s.deinit();
    return s.getResponse(allocator, url, bearer_token);
}

/// Encode `# ? %` so they cannot break the URL; keep `/` and `:` (#122).
pub fn pathEscape(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (c == '#' or c == '?' or c == '%') {
            const hex = "0123456789ABCDEF";
            try out.append(allocator, '%');
            try out.append(allocator, hex[c >> 4]);
            try out.append(allocator, hex[c & 0xf]);
        } else {
            try out.append(allocator, c);
        }
    }
    return out.toOwnedSlice(allocator);
}

pub const Error = error{
    BadUrl,
    HttpStatus,
    Timeout,
};

test "pathEscape keeps slash and colon" {
    const a = std.testing.allocator;
    const s = try pathEscape(a, "org/name:tag");
    defer a.free(s);
    try std.testing.expectEqualStrings("org/name:tag", s);
    const q = try pathEscape(a, "a?b#c%");
    defer a.free(q);
    try std.testing.expectEqualStrings("a%3Fb%23c%25", q);
}
