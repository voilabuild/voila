const std = @import("std");
const run_flags = @import("../run_flags.zig");
const posix_util = @import("sys").posix_util;

pub const RunOpts = struct {
    env: []run_flags.EnvPair,
    workdir: []const u8,
    volumes: []run_flags.Volume,
    ports: []run_flags.PortMap,
    tty: bool,
    interactive: bool,

    pub fn deinit(self: RunOpts, allocator: std.mem.Allocator) void {
        for (self.env) |e| {
            allocator.free(e.key);
            allocator.free(e.value);
        }
        allocator.free(self.env);
        allocator.free(self.workdir);
        for (self.volumes) |v| {
            allocator.free(v.host);
            allocator.free(v.container);
        }
        allocator.free(self.volumes);
        allocator.free(self.ports);
    }
};

pub fn runOptsPath(allocator: std.mem.Allocator, voila_root: []const u8, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/containers/{s}/run.json", .{ voila_root, id });
}

pub fn writeRunOpts(allocator: std.mem.Allocator, voila_root: []const u8, id: []const u8, opts: RunOpts) !void {
    const path = try runOptsPath(allocator, voila_root, id);
    defer allocator.free(path);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try buf.appendSlice(allocator, "\"workdir\":");
    try appendJsonString(allocator, &buf, opts.workdir);
    try buf.appendSlice(allocator, ",\"tty\":");
    try buf.appendSlice(allocator, if (opts.tty) "true" else "false");
    try buf.appendSlice(allocator, ",\"interactive\":");
    try buf.appendSlice(allocator, if (opts.interactive) "true" else "false");
    try buf.appendSlice(allocator, ",\"env\":[");
    for (opts.env, 0..) |e, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '[');
        try appendJsonString(allocator, &buf, e.key);
        try buf.append(allocator, ',');
        try appendJsonString(allocator, &buf, e.value);
        try buf.append(allocator, ']');
    }
    try buf.appendSlice(allocator, "],\"volumes\":[");
    for (opts.volumes, 0..) |v, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '{');
        try buf.appendSlice(allocator, "\"host\":");
        try appendJsonString(allocator, &buf, v.host);
        try buf.appendSlice(allocator, ",\"container\":");
        try appendJsonString(allocator, &buf, v.container);
        try buf.appendSlice(allocator, ",\"read_only\":");
        try buf.appendSlice(allocator, if (v.read_only) "true" else "false");
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "],\"ports\":[");
    for (opts.ports, 0..) |p, i| {
        if (i > 0) try buf.append(allocator, ',');
        const item = try std.fmt.allocPrint(allocator, "{{\"host\":{d},\"container\":{d}}}", .{ p.host, p.container });
        defer allocator.free(item);
        try buf.appendSlice(allocator, item);
    }
    try buf.appendSlice(allocator, "]}");
    try writeFile(path, buf.items);
}

pub fn readRunOpts(allocator: std.mem.Allocator, voila_root: []const u8, id: []const u8) !RunOpts {
    const path = try runOptsPath(allocator, voila_root, id);
    defer allocator.free(path);
    const data = posix_util.readFileAlloc(allocator, path, 1024 * 1024) catch {
        return emptyOpts(allocator);
    };
    defer allocator.free(data);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{ .ignore_unknown_fields = true }) catch {
        return emptyOpts(allocator);
    };
    defer parsed.deinit();
    const o = parsed.value.object;
    const workdir = try dupStrField(allocator, o, "workdir");
    const tty = boolField(o, "tty");
    const interactive = boolField(o, "interactive");
    var env_list: std.ArrayList(run_flags.EnvPair) = .empty;
    if (o.get("env")) |ev| {
        if (ev == .array) {
            for (ev.array.items) |pair| {
                if (pair != .array or pair.array.items.len != 2) continue;
                if (pair.array.items[0] != .string or pair.array.items[1] != .string) continue;
                try env_list.append(allocator, .{
                    .key = try allocator.dupe(u8, pair.array.items[0].string),
                    .value = try allocator.dupe(u8, pair.array.items[1].string),
                });
            }
        }
    }
    var vol_list: std.ArrayList(run_flags.Volume) = .empty;
    if (o.get("volumes")) |vv| {
        if (vv == .array) {
            for (vv.array.items) |item| {
                if (item != .object) continue;
                const mo = item.object;
                try vol_list.append(allocator, .{
                    .host = try dupStrField(allocator, mo, "host"),
                    .container = try dupStrField(allocator, mo, "container"),
                    .read_only = boolField(mo, "read_only"),
                });
            }
        }
    }
    var port_list: std.ArrayList(run_flags.PortMap) = .empty;
    if (o.get("ports")) |pv| {
        if (pv == .array) {
            for (pv.array.items) |item| {
                if (item != .object) continue;
                const mo = item.object;
                const h = intField(mo, "host");
                const c = intField(mo, "container");
                if (h == 0 or c == 0) continue;
                try port_list.append(allocator, .{ .host = @intCast(h), .container = @intCast(c) });
            }
        }
    }
    return .{
        .env = try env_list.toOwnedSlice(allocator),
        .workdir = workdir,
        .volumes = try vol_list.toOwnedSlice(allocator),
        .ports = try port_list.toOwnedSlice(allocator),
        .tty = tty,
        .interactive = interactive,
    };
}

fn emptyOpts(allocator: std.mem.Allocator) RunOpts {
    return .{
        .env = &.{},
        .workdir = allocator.dupe(u8, "") catch "",
        .volumes = &.{},
        .ports = &.{},
        .tty = false,
        .interactive = false,
    };
}

fn boolField(o: std.json.ObjectMap, key: []const u8) bool {
    const v = o.get(key) orelse return false;
    return v == .bool and v.bool;
}

fn intField(o: std.json.ObjectMap, key: []const u8) i64 {
    const v = o.get(key) orelse return 0;
    return if (v == .integer) v.integer else 0;
}

fn dupStrField(allocator: std.mem.Allocator, o: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = o.get(key) orelse return allocator.dupe(u8, "");
    if (v != .string) return allocator.dupe(u8, "");
    return allocator.dupe(u8, v.string);
}

fn appendJsonString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"', '\\' => {
                try buf.append(allocator, '\\');
                try buf.append(allocator, c);
            },
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

fn writeFile(path: []const u8, data: []const u8) !void {
    const path_z = try std.heap.page_allocator.allocSentinel(u8, path.len, 0);
    defer std.heap.page_allocator.free(path_z);
    @memcpy(path_z, path);
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.FileOpenFailed;
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data[off..].ptr, data.len - off);
        if (n <= 0) return error.FileWriteFailed;
        off += @intCast(n);
    }
}

pub const Error = error{ FileOpenFailed, FileWriteFailed };
