const std = @import("std");
const ocireg = @import("./voila_ocireg.zig");
const builtin = @import("builtin");
const crypto = std.crypto.hash.sha2;

pub const Credentials = struct {
    username: []const u8 = "",
    password: []const u8 = "",
};

pub const Descriptor = struct {
    digest: []const u8,
    media_type: []const u8,
    size: i64,
};

pub const Manifest = struct {
    config: Descriptor,
    layers: []Descriptor,
    raw_manifest: []const u8,
    digest: []const u8,
};

pub const Client = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    creds: Credentials,
    plain_http: bool,
    tokens: std.StringHashMap([]const u8),

    pub fn init(io: std.Io, allocator: std.mem.Allocator, creds: Credentials) Client {
        return .{
            .io = io,
            .allocator = allocator,
            .creds = creds,
            .plain_http = false,
            .tokens = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Client) void {
        var it = self.tokens.iterator();
        while (it.next()) |e| self.allocator.free(e.value_ptr.*);
        self.tokens.deinit();
    }

    pub fn withPlainHttp(self: *Client, allow: bool) void {
        self.plain_http = allow;
    }

    pub fn resolve(self: *Client, ref: ocireg.Ref, platform: []const u8) !Manifest {
        var fetched = try self.fetchManifest(ref, false);
        defer self.allocator.free(fetched.media_type);

        if (isIndexMediaType(fetched.media_type)) {
            const desc = try selectDescriptor(self.allocator, fetched.body, platform);
            defer self.allocator.free(desc.digest);
            var dref = ref;
            dref.digest = try self.allocator.dupe(u8, desc.digest);
            dref.is_digest = true;
            dref.tag = "";
            self.allocator.free(fetched.body);
            fetched = try self.fetchManifest(dref, false);
            defer self.allocator.free(fetched.media_type);
        }

        const digest = if (fetched.header_digest.len != 0)
            try self.allocator.dupe(u8, fetched.header_digest)
        else
            try sha256DigestPrefixed(self.allocator, fetched.body);
        defer self.allocator.free(digest);

        return parseImageManifest(self.allocator, fetched.body, digest);
    }

    pub fn blob(self: *Client, ref: ocireg.Ref, digest: []const u8) ![]u8 {
        const url = try self.blobUrl(ref, digest);
        defer self.allocator.free(url);
        return self.httpGet(url, ref, false);
    }

    const FetchedManifest = struct {
        body: []const u8,
        media_type: []const u8,
        header_digest: []const u8,
    };

    fn fetchManifest(self: *Client, ref: ocireg.Ref, reauth: bool) !FetchedManifest {
        const url = try self.manifestUrl(ref);
        defer self.allocator.free(url);
        const accept =
            "application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json";
        const resp = try self.httpGetWithHeaders(url, ref, reauth, accept);
        if (resp.status == 401 and !reauth) {
            self.invalidateToken(ref);
            resp.deinit(self.allocator);
            return self.fetchManifest(ref, true);
        }
        if (resp.status != 200) {
            resp.deinit(self.allocator);
            return error.HttpStatus;
        }
        return .{
            .body = resp.body,
            .media_type = resp.content_type,
            .header_digest = resp.docker_digest,
        };
    }

    fn scheme(self: *Client) []const u8 {
        return if (self.plain_http) "http" else "https";
    }

    fn manifestUrl(self: *Client, ref: ocireg.Ref) ![]const u8 {
        const repo = try escapeRepoPath(self.allocator, ref.repo);
        defer self.allocator.free(repo);
        const reference = if (ref.is_digest) ref.digest else ref.tag;
        return std.fmt.allocPrint(self.allocator, "{s}://{s}/v2/{s}/manifests/{s}", .{
            self.scheme(),
            ref.host,
            repo,
            reference,
        });
    }

    fn blobUrl(self: *Client, ref: ocireg.Ref, digest: []const u8) ![]const u8 {
        const repo = try escapeRepoPath(self.allocator, ref.repo);
        defer self.allocator.free(repo);
        return std.fmt.allocPrint(self.allocator, "{s}://{s}/v2/{s}/blobs/{s}", .{
            self.scheme(),
            ref.host,
            repo,
            digest,
        });
    }

    const RawResponse = struct {
        status: u16,
        body: []const u8,
        content_type: []const u8,
        docker_digest: []const u8,

        fn deinit(self: RawResponse, allocator: std.mem.Allocator) void {
            allocator.free(self.body);
            allocator.free(self.content_type);
            allocator.free(self.docker_digest);
        }
    };

    fn httpGet(self: *Client, url: []const u8, ref: ocireg.Ref, reauth: bool) ![]u8 {
        const resp = try self.httpGetWithHeaders(url, ref, reauth, null);
        if (resp.status == 401 and !reauth) {
            self.invalidateToken(ref);
            resp.deinit(self.allocator);
            return self.httpGet(url, ref, true);
        }
        if (resp.status != 200) {
            resp.deinit(self.allocator);
            return error.HttpStatus;
        }
        const body = try self.allocator.dupe(u8, resp.body);
        self.allocator.free(resp.body);
        self.allocator.free(resp.content_type);
        self.allocator.free(resp.docker_digest);
        return body;
    }

    fn httpGetWithHeaders(self: *Client, url: []const u8, ref: ocireg.Ref, reauth: bool, accept: ?[]const u8) !RawResponse {
        self.ensureAuth(ref, reauth);
        var auth_buf: [8192]u8 = undefined;
        const tok = self.tokenFor(ref);
        const authorization: std.http.Client.Request.Headers.Value = if (tok.len == 0)
            .omit
        else
            .{ .override = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{tok}) catch return error.HttpStatus };

        var extra: [1]std.http.Header = undefined;
        var extra_headers: []const std.http.Header = &.{};
        if (accept) |a| {
            extra[0] = .{ .name = "Accept", .value = a };
            extra_headers = extra[0..];
        }

        var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        var response: std.Io.Writer.Allocating = .init(self.allocator);
        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .keep_alive = false,
            .headers = .{
                .user_agent = .{ .override = "voila-ocireg/1.0" },
                .authorization = authorization,
            },
            .extra_headers = extra_headers,
            .response_writer = &response.writer,
        }) catch return error.HttpStatus;

        const code: u16 = @backingInt(result.status);
        const body = try response.toOwnedSlice();
        return .{
            .status = code,
            .body = body,
            .content_type = "",
            .docker_digest = "",
        };
    }

    fn ensureAuth(self: *Client, ref: ocireg.Ref, force: bool) void {
        if (!force and self.tokenFor(ref).len != 0) return;
        if (self.creds.username.len != 0 or self.creds.password.len != 0) return;
    }

    fn tokenFor(self: *Client, ref: ocireg.Ref) []const u8 {
        const key = tokenKey(self.allocator, ref) catch return "";
        defer self.allocator.free(key);
        return self.tokens.get(key) orelse "";
    }

    fn invalidateToken(self: *Client, ref: ocireg.Ref) void {
        const key = tokenKey(self.allocator, ref) catch return;
        defer self.allocator.free(key);
        if (self.tokens.fetchRemove(key)) |kv| self.allocator.free(kv.value);
    }

    fn tokenKey(allocator: std.mem.Allocator, ref: ocireg.Ref) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ ref.host, ref.repo });
    }
};

pub fn escapeRepoPath(allocator: std.mem.Allocator, repo: []const u8) ![]const u8 {
    var parts = std.mem.splitScalar(u8, repo, '/');
    var out: std.ArrayList(u8) = .empty;
    var first = true;
    while (parts.next()) |p| {
        if (!first) try out.append(allocator, '/');
        first = false;
        for (p) |c| {
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
    }
    return out.toOwnedSlice(allocator);
}

fn sha256DigestPrefixed(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var h = crypto.Sha256.init(.{});
    h.update(body);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(&digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{&hex});
}

fn stripMediaType(ct: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, ct, ';')) |i| return std.mem.trim(u8, ct[0..i], " \t");
    return std.mem.trim(u8, ct, " \t");
}

fn isIndexMediaType(mt: []const u8) bool {
    return std.mem.eql(u8, mt, "application/vnd.oci.image.index.v1+json") or
        std.mem.eql(u8, mt, "application/vnd.docker.distribution.manifest.list.v2+json");
}

pub fn parseImageManifest(allocator: std.mem.Allocator, body: []const u8, digest: []const u8) !Manifest {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const root = parsed.value.object;
    const cfg = root.get("config") orelse return error.BadManifest;
    if (cfg != .object) return error.BadManifest;
    const config_digest = try dupStr(allocator, cfg.object.get("digest"));
    const config_mt = try dupStr(allocator, cfg.object.get("mediaType"));
    const config_size: i64 = @intCast(jsonInt(cfg.object.get("size")));

    var layers: std.ArrayList(Descriptor) = .empty;
    const layers_val = root.get("layers") orelse return error.BadManifest;
    if (layers_val != .array) return error.BadManifest;
    for (layers_val.array.items) |item| {
        if (item != .object) continue;
        try layers.append(allocator, .{
            .digest = try dupStr(allocator, item.object.get("digest")),
            .media_type = try dupStr(allocator, item.object.get("mediaType")),
            .size = @intCast(jsonInt(item.object.get("size"))),
        });
    }

    return .{
        .config = .{ .digest = config_digest, .media_type = config_mt, .size = config_size },
        .layers = try layers.toOwnedSlice(allocator),
        .raw_manifest = try allocator.dupe(u8, body),
        .digest = try allocator.dupe(u8, digest),
    };
}

fn dupStr(allocator: std.mem.Allocator, v: ?std.json.Value) ![]const u8 {
    const val = v orelse return error.BadManifest;
    if (val != .string) return error.BadManifest;
    return allocator.dupe(u8, val.string);
}

fn jsonInt(v: ?std.json.Value) i64 {
    const val = v orelse return 0;
    return switch (val) {
        .integer => val.integer,
        .float => @intFromFloat(val.float),
        else => 0,
    };
}

const IndexDesc = struct { digest: []const u8 };

fn selectDescriptor(allocator: std.mem.Allocator, body: []const u8, platform: []const u8) !IndexDesc {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const manifests = parsed.value.object.get("manifests") orelse return error.BadIndex;
    if (manifests != .array or manifests.array.items.len == 0) return error.BadIndex;
    if (manifests.array.items.len == 1) {
        const item = manifests.array.items[0];
        if (item != .object) return error.BadIndex;
        return .{ .digest = try dupStr(allocator, item.object.get("digest")) };
    }
    var want_os: []const u8 = @tagName(builtin.target.os.tag);
    var want_arch: []const u8 = @tagName(builtin.target.cpu.arch);
    if (platform.len != 0) {
        var parts = std.mem.splitScalar(u8, platform, '/');
        want_os = parts.next() orelse want_os;
        want_arch = parts.next() orelse want_arch;
    }
    for (manifests.array.items) |item| {
        if (item != .object) continue;
        const plat_val = item.object.get("platform") orelse continue;
        if (plat_val != .object) continue;
        const os = jsonStr(plat_val.object.get("os"));
        const arch = jsonStr(plat_val.object.get("architecture"));
        if (std.mem.eql(u8, os, want_os) and std.mem.eql(u8, arch, want_arch)) {
            return .{ .digest = try dupStr(allocator, item.object.get("digest")) };
        }
    }
    const item = manifests.array.items[0];
    if (item != .object) return error.BadIndex;
    return .{ .digest = try dupStr(allocator, item.object.get("digest")) };
}

fn jsonStr(v: ?std.json.Value) []const u8 {
    const val = v orelse return "";
    if (val != .string) return "";
    return val.string;
}

pub const Error = error{
    HttpStatus,
    BadManifest,
    BadIndex,
};

test "parse image manifest" {
    const gpa = std.testing.allocator;
    const body =
        \\{"schemaVersion":2,"config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:abc","size":1},"layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar","digest":"sha256:def","size":2}]}
    ;
    const man = try parseImageManifest(gpa, body, "sha256:111");
    defer gpa.free(man.config.digest);
    defer gpa.free(man.config.media_type);
    defer gpa.free(man.raw_manifest);
    defer gpa.free(man.digest);
    for (man.layers) |l| {
        gpa.free(l.digest);
        gpa.free(l.media_type);
    }
    gpa.free(man.layers);
    try std.testing.expectEqualStrings("sha256:abc", man.config.digest);
    try std.testing.expect(man.layers.len == 1);
}
