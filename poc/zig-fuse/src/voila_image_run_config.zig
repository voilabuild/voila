//! Default container argv from stored ImageManifest + OCI config chunk.
const std = @import("std");
const voila_refkey = @import("voila_refkey.zig");
const voila_resolve = @import("voila_resolve.zig");
const voila_chunk_index = @import("voila_chunk_index.zig");
const voila_store = @import("voila_store.zig");
const hex_util = @import("hex_util.zig");
const posix_util = @import("posix_util.zig");

const OciConfig = struct {
    entrypoint: []const []const u8,
    cmd: []const []const u8,
    workdir: []const u8,
};

fn readPbConfigChunk(allocator: std.mem.Allocator, pb_path: []const u8) ![]u8 {
    const data = try posix_util.readFileAlloc(allocator, pb_path, 4 * 1024 * 1024);
    defer allocator.free(data);
    var off: usize = 0;
    while (off < data.len) {
        const key = readVarint(data, &off) orelse break;
        const wire: u32 = @intCast(key & 7);
        const field: u32 = @intCast(key >> 3);
        if (wire == 2) {
            const len = readVarint(data, &off) orelse return error.BadPb;
            if (off + len > data.len) return error.BadPb;
            const slice = data[off .. off + len];
            off += len;
            if (field == 3 and len == 32) return try allocator.dupe(u8, slice);
            continue;
        }
        if (wire == 0) {
            _ = readVarint(data, &off);
            continue;
        }
        if (wire == 1) {
            off += 8;
            continue;
        }
        if (wire == 5) {
            off += 4;
            continue;
        }
        return error.BadPb;
    }
    return error.NoConfigChunk;
}

fn readVarint(data: []const u8, off: *usize) ?u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (off.* < data.len) {
        const b = data[off.*];
        off.* += 1;
        result |= @as(u64, b & 0x7f) << shift;
        if ((b & 0x80) == 0) return result;
        shift += 7;
        if (shift > 63) return null;
    }
    return null;
}

fn parseOciConfig(allocator: std.mem.Allocator, json: []const u8) !OciConfig {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.BadConfig;
    const cfg = root.object.get("Config") orelse root.object.get("config") orelse return error.BadConfig;
    if (cfg != .object) return error.BadConfig;
    const obj = cfg.object;
    return .{
        .entrypoint = try dupStrArray(allocator, obj.get("Entrypoint")),
        .cmd = try dupStrArray(allocator, obj.get("Cmd")),
        .workdir = try dupOptStr(allocator, obj.get("WorkingDir")),
    };
}

fn dupOptStr(allocator: std.mem.Allocator, v: ?std.json.Value) ![]const u8 {
    if (v) |val| {
        if (val == .string) return allocator.dupe(u8, val.string);
    }
    return allocator.dupe(u8, "");
}

fn dupStrArray(allocator: std.mem.Allocator, v: ?std.json.Value) ![]const []const u8 {
    if (v) |val| {
        if (val == .array) {
            var out: std.ArrayList([]const u8) = .empty;
            for (val.array.items) |item| {
                if (item != .string) continue;
                try out.append(allocator, try allocator.dupe(u8, item.string));
            }
            return try out.toOwnedSlice(allocator);
        }
    }
    return try allocator.alloc([]const u8, 0);
}

fn freeOci(allocator: std.mem.Allocator, c: OciConfig) void {
    for (c.entrypoint) |s| allocator.free(s);
    allocator.free(c.entrypoint);
    for (c.cmd) |s| allocator.free(s);
    allocator.free(c.cmd);
    allocator.free(c.workdir);
}

fn mergeArgv(allocator: std.mem.Allocator, c: OciConfig, override: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (c.entrypoint) |s| try out.append(allocator, try allocator.dupe(u8, s));
    if (override.len != 0) {
        for (override) |s| try out.append(allocator, try allocator.dupe(u8, s));
    } else {
        for (c.cmd) |s| try out.append(allocator, try allocator.dupe(u8, s));
    }
    return try out.toOwnedSlice(allocator);
}

pub fn defaultArgv(
    allocator: std.mem.Allocator,
    voila_root: []const u8,
    image_ref: []const u8,
    override: []const []const u8,
) ![]const []const u8 {
    const rec = try voila_resolve.resolveImage(allocator, voila_root, image_ref);
    defer {
        allocator.free(rec.ref);
        allocator.free(rec.image_digest);
        allocator.free(rec.merged_root_manifest);
    }
    const key = try voila_refkey.refKey(allocator, rec.ref);
    defer allocator.free(key);
    const pb_path = try std.fmt.allocPrint(allocator, "{s}/images/{s}.pb", .{ voila_root, key });
    defer allocator.free(pb_path);
    const chunk_id = readPbConfigChunk(allocator, pb_path) catch return error.NoImageConfig;
    defer allocator.free(chunk_id);
    var hex_buf: [64]u8 = undefined;
    if (chunk_id.len * 2 > hex_buf.len) return error.BadConfigChunk;
    hex_util.encodeHexLower(hex_buf[0 .. chunk_id.len * 2], chunk_id);
    const chunk_hex = hex_buf[0 .. chunk_id.len * 2];
    const algo = voila_chunk_index.compAlgoForChunk(voila_root, chunk_id) catch voila_store.AlgoRaw;
    const raw = try voila_store.loadChunkRaw(allocator, voila_root, chunk_hex, algo);
    defer allocator.free(raw);
    const oci = try parseOciConfig(allocator, raw);
    defer freeOci(allocator, oci);
    const argv = try mergeArgv(allocator, oci, override);
    if (argv.len == 0) return error.NoDefaultCommand;
    return argv;
}

pub const Error = error{
    BadPb,
    NoConfigChunk,
    BadConfig,
    BadConfigChunk,
    NoImageConfig,
    NoDefaultCommand,
};
