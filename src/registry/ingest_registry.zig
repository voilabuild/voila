const std = @import("std");
const ocireg = @import("./voila_ocireg.zig");
const chunk_store = @import("../store/ingest/ingest_chunk_store.zig");
const layer_walk = @import("../store/ingest/ingest_layer_walk.zig");
const tar_mod = @import("../store/ingest/ingest_tar.zig");
const build_mod = @import("../store/ingest/ingest_build.zig");

pub const OciManifest = struct {
    config_digest: []const u8,
    config_media_type: []const u8,
    layers: []LayerBlob,
    manifest_digest: []const u8,
};

pub const LayerBlob = struct {
    digest: []const u8,
    media_type: []const u8,
    size: i64,
};

pub const RegistryClient = struct {
    ptr: *anyopaque,
    resolveFn: *const fn (ptr: *anyopaque, ref: ocireg.Ref, platform: []const u8) anyerror!OciManifest,
    blobFn: *const fn (ptr: *anyopaque, ref: ocireg.Ref, digest: []const u8) anyerror![]u8,
};

pub const Options = struct {
    platform: []const u8 = "",
    ref_override: ?[]const u8 = null,
};

pub fn ingestRegistry(
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    client: RegistryClient,
    ref: ocireg.Ref,
    opts: Options,
) !build_mod.Result {
    const man = try client.resolveFn(client.ptr, ref, opts.platform);

    var layer_descs: std.ArrayList(build_mod.LayerDesc) = .empty;
    for (man.layers, 0..) |l, i| {
        try layer_descs.append(allocator, .{
            .digest = l.digest,
            .media_type = l.media_type,
            .index = i,
        });
    }

    const image_digest = digestToBytes(allocator, man.manifest_digest) catch try allocator.alloc(u8, 0);
    const ref_str = try ocireg.refString(allocator, ref);
    defer allocator.free(ref_str);

    const pl = build_mod.ParsedLayout{
        .ref = try allocator.dupe(u8, ref_str),
        .image_digest = image_digest,
        .config_digest = man.config_digest,
        .layers = try layer_descs.toOwnedSlice(allocator),
    };

    const cfg_blob = try client.blobFn(client.ptr, ref, man.config_digest);
    defer allocator.free(cfg_blob);
    const config_chunk = try chunk_store.putBytes(allocator, voila_root, cfg_blob);

    var layer_trees: std.ArrayList(*@import("../store/ingest/ingest_tree.zig").LayerTree) = .empty;
    var agg_bytes: u64 = 0;
    var agg_chunks: u64 = 0;
    var agg_deduped: u64 = 0;
    var agg_stored: u64 = 0;

    for (pl.layers) |ld| {
        const blob = try client.blobFn(client.ptr, ref, ld.digest);
        defer allocator.free(blob);
        const hint = tar_mod.mediaTypeHint(ld.media_type);
        const raw = try tar_mod.decompressLayer(allocator, blob, hint);
        defer allocator.free(raw);
        const walk = try layer_walk.walkLayer(allocator, voila_root, raw);
        try layer_trees.append(allocator, walk.tree);
        agg_bytes += walk.bytes_in;
        agg_chunks += walk.chunk_count;
        agg_deduped += walk.chunks_deduped;
        agg_stored += walk.stored_bytes;
    }

    return build_mod.buildIngestResult(
        allocator,
        voila_root,
        pl,
        try layer_trees.toOwnedSlice(allocator),
        config_chunk,
        agg_bytes,
        agg_chunks,
        agg_deduped,
        agg_stored,
        opts.ref_override,
    );
}

fn digestToBytes(allocator: std.mem.Allocator, digest: []const u8) ![]u8 {
    const prefix = "sha256:";
    if (!std.mem.startsWith(u8, digest, prefix)) return error.BadDigest;
    const hex = digest[prefix.len..];
    if (hex.len != 64) return error.BadDigest;
    const out = try allocator.alloc(u8, 32);
    _ = try std.fmt.hexToBytes(out, hex);
    return out;
}

pub const Error = error{BadDigest};

const crypto = std.crypto.hash.sha2;
const fs = @import("../sys/fs.zig");

test "ingest registry smoke" {
    const gpa = std.testing.allocator;
    const content = "hello from the registry";
    var fake = try newFakeRegistryClient(gpa, content);
    defer fake.deinit(gpa);

    const root = try fs.makeTempDir(gpa, "voila-ingest-registry-test");
    defer gpa.free(root);
    defer fs.removeTree(gpa, root) catch {};
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const ref = ocireg.Ref{
        .host = try gpa.dupe(u8, "registry.example.com"),
        .repo = try gpa.dupe(u8, "test/img"),
        .tag = try gpa.dupe(u8, "latest"),
        .digest = "",
        .is_digest = false,
    };
    defer {
        gpa.free(ref.host);
        gpa.free(ref.repo);
        gpa.free(ref.tag);
    }

    const client = fake.client();
    const res = try ingestRegistry(arena.allocator(), root, client, ref, .{});
    try std.testing.expect(res.layers.len == 1);
    try std.testing.expect(res.chunk_count == 1);
    try std.testing.expect(res.bytes_in == content.len);
}

const FakeRegistry = struct {
    manifest: OciManifest,
    config: []const u8,
    layers: []const []const u8,
    config_digest: []const u8,
    layer_digests: []const []const u8,

    fn deinit(self: *const FakeRegistry, gpa: std.mem.Allocator) void {
        gpa.free(self.config);
        for (self.layers) |l| gpa.free(l);
        gpa.free(self.layers);
        gpa.free(self.config_digest);
        for (self.layer_digests) |d| gpa.free(d);
        gpa.free(self.layer_digests);
        gpa.free(self.manifest.config_media_type);
        for (self.manifest.layers) |l| gpa.free(l.media_type);
        gpa.free(self.manifest.layers);
        gpa.free(self.manifest.manifest_digest);
    }

    fn client(self: *FakeRegistry) RegistryClient {
        return .{
            .ptr = self,
            .resolveFn = fakeResolve,
            .blobFn = fakeBlob,
        };
    }
};

fn newFakeRegistryClient(gpa: std.mem.Allocator, content: []const u8) !FakeRegistry {
    var layer_buf: std.ArrayList(u8) = .empty;
    const hdr = try tarHeader("hello.txt", content.len);
    try layer_buf.appendSlice(gpa, &hdr);
    try layer_buf.appendSlice(gpa, content);
    const pad = (512 - (layer_buf.items.len % 512)) % 512;
    try layer_buf.appendNTimes(gpa, 0, pad);
    try layer_buf.appendNTimes(gpa, 0, 512);
    const layer = try layer_buf.toOwnedSlice(gpa);

    const config_json = "{\"architecture\":\"amd64\",\"os\":\"linux\",\"config\":{},\"rootfs\":{\"type\":\"layers\",\"digests\":[]},\"history\":[]}";
    const config = try gpa.dupe(u8, config_json);
    const config_digest = try digestPrefixed(gpa, config);
    const layer_digest = try digestPrefixed(gpa, layer);

    const man_digest = try digestPrefixed(gpa, "{}");
    const layers_slice = try gpa.alloc(LayerBlob, 1);
    layers_slice[0] = .{
        .digest = layer_digest,
        .media_type = try gpa.dupe(u8, "application/vnd.oci.image.layer.v1.tar"),
        .size = @intCast(layer.len),
    };
    const layer_store = try gpa.alloc([]const u8, 1);
    layer_store[0] = layer;
    const digest_store = try gpa.alloc([]const u8, 1);
    digest_store[0] = layer_digest;

    return .{
        .manifest = .{
            .config_digest = config_digest,
            .config_media_type = try gpa.dupe(u8, "application/vnd.oci.image.config.v1+json"),
            .layers = layers_slice,
            .manifest_digest = man_digest,
        },
        .config = config,
        .layers = layer_store,
        .config_digest = config_digest,
        .layer_digests = digest_store,
    };
}

fn tarHeader(name: []const u8, size: usize) ![512]u8 {
    var block: [512]u8 = @splat(0);
    if (name.len > 100) return error.NameTooLong;
    @memcpy(block[0..name.len], name);
    writeOct(&block, 100, 0o644);
    writeOct(&block, 124, size);
    block[156] = '0';
    return block;
}

fn writeOct(block: *[512]u8, off: usize, value: usize) void {
    _ = std.fmt.bufPrint(block[off .. off + 12], "{o:0>11}", .{value}) catch unreachable;
}

fn digestPrefixed(gpa: std.mem.Allocator, data: []const u8) ![]const u8 {
    var h = crypto.Sha256.init(.{});
    h.update(data);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(&digest, .lower);
    return std.fmt.allocPrint(gpa, "sha256:{s}", .{&hex});
}

fn fakeResolve(ptr: *anyopaque, _: ocireg.Ref, _: []const u8) anyerror!OciManifest {
    const self: *FakeRegistry = @ptrCast(@alignCast(ptr));
    return self.manifest;
}

fn fakeBlob(ptr: *anyopaque, _: ocireg.Ref, digest: []const u8) anyerror![]u8 {
    const self: *FakeRegistry = @ptrCast(@alignCast(ptr));
    const gpa = std.heap.page_allocator;
    if (std.mem.eql(u8, digest, self.config_digest)) return gpa.dupe(u8, self.config);
    if (self.layer_digests.len > 0 and std.mem.eql(u8, digest, self.layer_digests[0])) return gpa.dupe(u8, self.layers[0]);
    return error.UnknownBlob;
}

const NameTooLong = error{NameTooLong};
const UnknownBlob = error{UnknownBlob};
