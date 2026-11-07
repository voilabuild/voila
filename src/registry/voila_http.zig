const std = @import("std");
const trace = @import("sys").trace;

const log = std.log.scoped(.registry);
const request_timeout: std.Io.Duration = .fromSeconds(30);

/// Shared HTTP client for a push/pull session. Reusing the client avoids the
/// Cloudflare hang from a new client per request (#123).
pub const Session = struct {
    client: std.http.Client,
    /// Reuse the connection between requests. Off by default: see #123.
    keep_alive: bool = false,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) Session {
        return .{ .client = .{ .allocator = allocator, .io = io } };
    }

    pub fn initKeepAlive(io: std.Io, allocator: std.mem.Allocator) Session {
        return .{ .client = .{ .allocator = allocator, .io = io }, .keep_alive = true };
    }

    pub fn deinit(self: *Session) void {
        self.client.deinit();
    }

    /// Opens a connection to `url`'s host and leaves it idle in this session's pool, so
    /// the next request there skips the TCP and TLS handshakes. False when it could not.
    pub fn warm(self: *Session, url: []const u8) bool {
        const uri = std.Uri.parse(url) catch return false;
        const protocol = std.http.Client.Protocol.fromUri(uri) orelse return false;
        // `connect` does not load the CA bundle the way `request` does.
        if (protocol == .tls and !self.loadCaBundle()) return false;
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = std.Io.net.HostName.fromUri(uri, &host_buf) catch return false;
        const port: u16 = uri.port orelse switch (protocol) {
            .tls => 443,
            .plain => 80,
        };
        const conn = self.client.connect(host, port, protocol) catch return false;
        self.client.connection_pool.release(conn, self.client.io);
        return true;
    }

    fn loadCaBundle(self: *Session) bool {
        const c = &self.client;
        const io = c.io;
        {
            c.ca_bundle_lock.lockShared(io) catch return false;
            defer c.ca_bundle_lock.unlockShared(io);
            if (c.now != null) return true;
        }
        var bundle: std.crypto.Certificate.Bundle = .empty;
        defer bundle.deinit(c.allocator);
        const now = std.Io.Clock.real.now(io);
        bundle.rescan(c.allocator, io, now) catch return false;
        c.ca_bundle_lock.lock(io) catch return false;
        defer c.ca_bundle_lock.unlock(io);
        c.now = now;
        std.mem.swap(std.crypto.Certificate.Bundle, &c.ca_bundle, &bundle);
        return true;
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

    /// Like `postJson`, but returns any status with its body for the caller to map.
    pub fn postJsonStatus(self: *Session, allocator: std.mem.Allocator, url: []const u8, bearer_token: []const u8, body: []const u8) !Response {
        var response: std.Io.Writer.Allocating = .init(allocator);
        defer response.deinit();
        const result = try self.fetch(url, .POST, bearer_token, "application/json", null, body, &response.writer);
        return .{ .status = @backingInt(result.status), .body = try response.toOwnedSlice() };
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
            .keep_alive = self.keep_alive,
            .headers = .{
                .user_agent = .{ .override = "voila-zig-registry/1.0" },
                .authorization = authorization,
                .content_type = if (content_type) |ct| .{ .override = ct } else .omit,
            },
            .extra_headers = extra_headers,
            .payload = payload,
            .response_writer = response_writer,
        };
        const span = trace.begin(switch (method) {
            .GET => "http GET",
            .PUT => "http PUT",
            .POST => "http POST",
            else => "http",
        });
        const pooled = self.client.connection_pool.free_len > 0;
        var cdn: CdnInfo = .{};
        const result = fetchTimed(&self.client, opts, &cdn) catch |e| {
            span.endArgs("\"url\":{f},\"keep_alive\":{},\"pooled_conn\":{},\"error\":{f}", .{ trace.str(url), self.keep_alive, pooled, trace.str(@errorName(e)) });
            switch (e) {
                error.Timeout => {
                    log.err("registry request timed out: {s}", .{url});
                    return error.Timeout;
                },
                else => return error.HttpStatus,
            }
        };
        span.endArgs("\"url\":{f},\"keep_alive\":{},\"pooled_conn\":{},\"status\":{d},\"cdn_cache\":{f},\"cdn_colo\":{f},\"cdn_age\":{d}", .{ trace.str(url), self.keep_alive, pooled, @backingInt(result.status), trace.str(cdn.cache()), trace.str(cdn.colo()), cdn.age });
        return result;
    }
};

/// What a CDN in front of the registry said about a response (Cloudflare headers), for
/// the trace: whether the chunk came from the edge cache, and which edge served it.
pub const CdnInfo = struct {
    cache_buf: [16]u8 = undefined,
    cache_len: usize = 0,
    colo_buf: [8]u8 = undefined,
    colo_len: usize = 0,
    /// Seconds the edge has held the response (`age`), -1 when absent.
    age: i64 = -1,

    pub fn cache(self: *const CdnInfo) []const u8 {
        return self.cache_buf[0..self.cache_len];
    }

    pub fn colo(self: *const CdnInfo) []const u8 {
        return self.colo_buf[0..self.colo_len];
    }

    fn record(self: *CdnInfo, head: std.http.Client.Response.Head) void {
        var it = head.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "cf-cache-status")) {
                self.cache_len = @min(h.value.len, self.cache_buf.len);
                @memcpy(self.cache_buf[0..self.cache_len], h.value[0..self.cache_len]);
            } else if (std.ascii.eqlIgnoreCase(h.name, "cf-ray")) {
                // `<id>-<colo>`: the edge location, e.g. YUL.
                const dash = std.mem.lastIndexOfScalar(u8, h.value, '-') orelse continue;
                const c = h.value[dash + 1 ..];
                self.colo_len = @min(c.len, self.colo_buf.len);
                @memcpy(self.colo_buf[0..self.colo_len], c[0..self.colo_len]);
            } else if (std.ascii.eqlIgnoreCase(h.name, "age")) {
                self.age = std.fmt.parseInt(i64, h.value, 10) catch -1;
            }
        }
    }
};

fn fetchTimed(client: *std.http.Client, opts: std.http.Client.FetchOptions, cdn: *CdnInfo) !std.http.Client.FetchResult {
    const Result = union(enum) {
        fetch: std.http.Client.FetchError!std.http.Client.FetchResult,
        timeout: void,
    };
    var buf: [2]Result = undefined;
    var sel = std.Io.Select(Result).init(client.io, &buf);
    sel.concurrent(.fetch, runFetch, .{ client, opts, cdn }) catch return fetchRecording(client, opts, cdn);
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

fn runFetch(client: *std.http.Client, opts: std.http.Client.FetchOptions, cdn: *CdnInfo) std.http.Client.FetchError!std.http.Client.FetchResult {
    return fetchRecording(client, opts, cdn);
}

/// `std.http.Client.fetch` for the options voila uses (no redirect buffer, no
/// decompress buffer), plus recording the CDN headers of the response.
fn fetchRecording(client: *std.http.Client, options: std.http.Client.FetchOptions, cdn: *CdnInfo) std.http.Client.FetchError!std.http.Client.FetchResult {
    const uri = switch (options.location) {
        .url => |u| try std.Uri.parse(u),
        .uri => |u| u,
    };
    const method: std.http.Method = options.method orelse if (options.payload != null) .POST else .GET;
    const redirect_behavior: std.http.Client.Request.RedirectBehavior = options.redirect_behavior orelse
        if (options.payload == null) @fromBackingInt(@intCast(3)) else .unhandled;

    var req = try client.request(method, uri, .{
        .redirect_behavior = redirect_behavior,
        .headers = options.headers,
        .extra_headers = options.extra_headers,
        .privileged_headers = options.privileged_headers,
        .keep_alive = options.keep_alive,
    });
    defer req.deinit();

    if (options.payload) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        var body = try req.sendBodyUnflushed(&.{});
        try body.writer.writeAll(payload);
        try body.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    const redirect_buffer: []u8 = if (redirect_behavior == .unhandled) &.{} else try client.allocator.alloc(u8, 8 * 1024);
    defer client.allocator.free(redirect_buffer);

    var response = try req.receiveHead(redirect_buffer);
    if (trace.enabled()) cdn.record(response.head);

    const response_writer = options.response_writer orelse {
        const reader = response.reader(&.{});
        _ = reader.discardRemaining() catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
        };
        return .{ .status = response.head.status };
    };

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try client.allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try client.allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer client.allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = reader.streamRemaining(response_writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };
    return .{ .status = response.head.status };
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
