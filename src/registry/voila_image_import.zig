const std = @import("std");
const ocireg = @import("./voila_ocireg.zig");
const ocireg_client = @import("./ocireg_client.zig");
const voila_registry_hub = @import("./voila_registry_hub.zig");
const voila_manifest_cache = @import("./voila_manifest_cache.zig");
const voila_manifest_json = @import("../codec/voila_manifest_json.zig");
const voila_image_push = @import("./voila_image_push.zig");
const voila_image_pull = @import("./voila_image_pull.zig");
const ingest_registry = @import("./ingest_registry.zig");
const ingest_build = @import("../store/ingest/ingest_build.zig");
const chunk_store = @import("../store/ingest/ingest_chunk_store.zig");
const posix_util = @import("../sys/posix_util.zig");

pub const ImportOpts = struct {
    /// Upload chunks and manifest to the configured voila registry after local ingest.
    push: bool = false,
};

pub fn importImage(
    io: std.Io,
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    cfg: voila_registry_hub.Config,
    hub_ref: []const u8,
    push_ref: []const u8,
    opts: ImportOpts,
) !void {
    try posix_util.makePath(voila_root);

    const parsed = try ocireg.parseRef(allocator, hub_ref);
    defer freeRef(allocator, parsed);

    var client = ocireg_client.Client.init(io, allocator, .{});
    defer client.deinit();

    const reg_client = registryClient(&client);
    const res = try ingest_registry.ingestRegistry(allocator, voila_root, reg_client, parsed, .{
        .ref_override = push_ref,
    });
    defer freeResult(allocator, res);

    const manifest_json = try buildManifestJson(allocator, res);
    defer allocator.free(manifest_json);

    try voila_manifest_cache.save(allocator, voila_root, push_ref, manifest_json);
    const man = try voila_manifest_json.parse(allocator, manifest_json);
    defer {
        allocator.free(man.image_ref);
        allocator.free(man.image_digest);
        allocator.free(man.merged_root);
    }
    try voila_image_pull.persistManifest(allocator, voila_root, push_ref, manifest_json, man);

    std.debug.print("imported {s} from {s}\n", .{ push_ref, hub_ref });
    std.debug.print("  bytes in: {d}, chunks: {d}\n", .{ res.bytes_in, res.chunk_count });

    if (opts.push) try voila_image_push.pushImage(io, allocator, voila_root, cfg, push_ref);
}

fn registryClient(client: *ocireg_client.Client) ingest_registry.RegistryClient {
    return .{
        .ptr = client,
        .resolveFn = resolveBridge,
        .blobFn = blobBridge,
    };
}

fn resolveBridge(ptr: *anyopaque, ref: ocireg.Ref, platform: []const u8) anyerror!ingest_registry.OciManifest {
    const self: *ocireg_client.Client = @ptrCast(@alignCast(ptr));
    const man = try self.resolve(ref, platform);
    var layers: std.ArrayList(ingest_registry.LayerBlob) = .empty;
    for (man.layers) |l| {
        try layers.append(self.allocator, .{
            .digest = l.digest,
            .media_type = l.media_type,
            .size = l.size,
        });
    }
    return .{
        .config_digest = man.config.digest,
        .config_media_type = man.config.media_type,
        .layers = try layers.toOwnedSlice(self.allocator),
        .manifest_digest = man.digest,
    };
}

fn blobBridge(ptr: *anyopaque, ref: ocireg.Ref, digest: []const u8) anyerror![]u8 {
    const self: *ocireg_client.Client = @ptrCast(@alignCast(ptr));
    return self.blob(ref, digest);
}

/// ImageManifest JSON (as served by the registry) for an ingest result.
pub fn buildManifestJson(allocator: std.mem.Allocator, res: ingest_build.Result) ![]u8 {
    var layers_parts: std.ArrayList([]const u8) = .empty;
    for (res.layers) |layer| {
        const hex = chunk_store.idToHex(layer.root_manifest_chunk);
        const part = try std.fmt.allocPrint(allocator, "{{\"root_manifest_chunk\":\"{s}\",\"whiteouts_count\":{d}}}", .{
            &hex,
            layer.whiteouts_count,
        });
        try layers_parts.append(allocator, part);
    }
    const layers_json = try std.mem.join(allocator, ",", layers_parts.items);
    defer allocator.free(layers_json);
    for (layers_parts.items) |p| allocator.free(p);
    layers_parts.deinit(allocator);

    const cfg_hex = chunk_store.idToHex(res.config_chunk);
    const root_hex = chunk_store.idToHex(res.merged_root_manifest_chunk);
    var digest_buf: [64]u8 = undefined;
    const digest_hex: []const u8 = if (res.image_digest.len == 32) blk: {
        if (res.image_digest.len == 32) {
            const h = std.fmt.bytesToHex(res.image_digest[0..32], .lower);
            @memcpy(digest_buf[0..64], &h);
        }
        break :blk digest_buf[0..];
    } else "";

    return std.fmt.allocPrint(allocator,
        \\{{"image_ref":"{s}","image_digest":"{s}","config_chunk":"{s}","merged_root_manifest_chunk":"{s}","provenance_layers":[{s}],"total_size":{d},"chunk_count":{d}}}
    , .{
        res.ref,
        digest_hex,
        &cfg_hex,
        &root_hex,
        layers_json,
        res.bytes_in,
        res.chunk_count,
    });
}

fn freeRef(allocator: std.mem.Allocator, r: ocireg.Ref) void {
    allocator.free(r.host);
    allocator.free(r.repo);
    if (r.tag.len != 0) allocator.free(r.tag);
    if (r.digest.len != 0) allocator.free(r.digest);
}

fn freeResult(allocator: std.mem.Allocator, res: ingest_build.Result) void {
    allocator.free(res.ref);
    allocator.free(res.image_digest);
    allocator.free(res.layers);
}
