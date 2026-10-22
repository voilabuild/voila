const std = @import("std");
const posix_util = @import("../../sys/posix_util.zig");

pub const State = struct {
    id: []const u8,
    name: []const u8,
    image: []const u8,
    status: []const u8,
    pid: i32,
    mount_dir: []const u8,
    log_path: []const u8,
    rm_on_exit: bool,
};

pub fn containersRoot(allocator: std.mem.Allocator, voila_root: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/containers", .{voila_root});
}

pub fn containerDir(allocator: std.mem.Allocator, voila_root: []const u8, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/containers/{s}", .{ voila_root, id });
}

pub fn statePath(allocator: std.mem.Allocator, voila_root: []const u8, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/containers/{s}/state.json", .{ voila_root, id });
}

pub fn logPath(allocator: std.mem.Allocator, voila_root: []const u8, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/containers/{s}/container.log", .{ voila_root, id });
}

pub fn indexPath(allocator: std.mem.Allocator, voila_root: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/containers/index.txt", .{voila_root});
}

pub fn newId(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [6]u8 = undefined;
    const fd = std.c.open("/dev/urandom", .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd >= 0) {
        defer _ = std.c.close(fd);
        _ = std.c.read(fd, &buf, buf.len);
    }
    const hex = std.fmt.bytesToHex(buf, .lower);
    return try allocator.dupe(u8, &hex);
}

pub fn writeState(allocator: std.mem.Allocator, voila_root: []const u8, st: State) !void {
    const root = try containersRoot(allocator, voila_root);
    defer allocator.free(root);
    try posix_util.makePath(root);
    const dir = try containerDir(allocator, voila_root, st.id);
    defer allocator.free(dir);
    try posix_util.makePath(dir);
    const path = try statePath(allocator, voila_root, st.id);
    defer allocator.free(path);
    const json = try std.fmt.allocPrint(allocator,
        \\{{"id":"{s}","name":"{s}","image":"{s}","status":"{s}","pid":{d},"mount_dir":"{s}","log_path":"{s}","rm_on_exit":{s}}}
    , .{
        st.id,                                  st.name, st.image, st.status, st.pid, st.mount_dir, st.log_path,
        if (st.rm_on_exit) "true" else "false",
    });
    defer allocator.free(json);
    try writeFile(path, json);
    try appendIndex(allocator, voila_root, st.id);
}

pub fn readState(allocator: std.mem.Allocator, voila_root: []const u8, id: []const u8) !State {
    const path = try statePath(allocator, voila_root, id);
    defer allocator.free(path);
    const data = try posix_util.readFileAlloc(allocator, path, 64 * 1024);
    defer allocator.free(data);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const o = parsed.value.object;
    const pid_val = o.get("pid") orelse return error.BadState;
    const pid: i32 = switch (pid_val) {
        .integer => @intCast(pid_val.integer),
        else => 0,
    };
    return .{
        .id = try dupField(allocator, o, "id"),
        .name = try dupField(allocator, o, "name"),
        .image = try dupField(allocator, o, "image"),
        .status = try dupField(allocator, o, "status"),
        .pid = pid,
        .mount_dir = try dupField(allocator, o, "mount_dir"),
        .log_path = try dupField(allocator, o, "log_path"),
        .rm_on_exit = blk: {
            const v = o.get("rm_on_exit");
            break :blk v != null and v.? == .bool and v.?.bool;
        },
    };
}

pub fn listStates(allocator: std.mem.Allocator, voila_root: []const u8) ![]State {
    const ids = try listIds(allocator, voila_root);
    defer {
        for (ids) |id| allocator.free(id);
        allocator.free(ids);
    }
    var out: std.ArrayList(State) = .empty;
    for (ids) |id| {
        const st = readState(allocator, voila_root, id) catch continue;
        try out.append(allocator, st);
    }
    return try out.toOwnedSlice(allocator);
}

pub fn listIds(allocator: std.mem.Allocator, voila_root: []const u8) ![][]const u8 {
    const path = try indexPath(allocator, voila_root);
    defer allocator.free(path);
    const data = posix_util.readFileAlloc(allocator, path, 1024 * 1024) catch return try allocator.alloc([]const u8, 0);
    defer allocator.free(data);
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        try out.append(allocator, try allocator.dupe(u8, t));
    }
    return try out.toOwnedSlice(allocator);
}

pub fn resolveId(allocator: std.mem.Allocator, voila_root: []const u8, query: []const u8) ![]const u8 {
    const ids = try listIds(allocator, voila_root);
    defer {
        for (ids) |id| allocator.free(id);
        allocator.free(ids);
    }
    for (ids) |id| {
        if (std.mem.eql(u8, id, query)) return allocator.dupe(u8, id);
        const st = readState(allocator, voila_root, id) catch continue;
        defer freeState(allocator, st);
        if (st.name.len != 0 and std.mem.eql(u8, st.name, query)) return allocator.dupe(u8, id);
    }
    return error.NotFound;
}

pub fn freeState(allocator: std.mem.Allocator, st: State) void {
    allocator.free(st.id);
    allocator.free(st.name);
    allocator.free(st.image);
    allocator.free(st.status);
    allocator.free(st.mount_dir);
    allocator.free(st.log_path);
}

pub fn removeContainer(allocator: std.mem.Allocator, voila_root: []const u8, id: []const u8) void {
    const dir = containerDir(allocator, voila_root, id) catch return;
    defer allocator.free(dir);
    const cmd = std.fmt.allocPrint(allocator, "rm -rf {s}", .{dir}) catch return;
    defer allocator.free(cmd);
    const cmd_z = allocator.allocSentinel(u8, cmd.len, 0) catch return;
    defer allocator.free(cmd_z);
    @memcpy(cmd_z, cmd);
    _ = posix_util.shell(cmd_z);
    removeIndexLine(allocator, voila_root, id) catch {};
}

fn appendIndex(allocator: std.mem.Allocator, voila_root: []const u8, id: []const u8) !void {
    const existing = try listIds(allocator, voila_root);
    defer {
        for (existing) |i| allocator.free(i);
        allocator.free(existing);
    }
    for (existing) |i| {
        if (std.mem.eql(u8, i, id)) return;
    }
    const path = try indexPath(allocator, voila_root);
    defer allocator.free(path);
    const line = try std.fmt.allocPrint(allocator, "{s}\n", .{id});
    defer allocator.free(line);
    try appendFile(path, line);
}

fn removeIndexLine(allocator: std.mem.Allocator, voila_root: []const u8, id: []const u8) !void {
    const ids = try listIds(allocator, voila_root);
    defer {
        for (ids) |i| allocator.free(i);
        allocator.free(ids);
    }
    const path = try indexPath(allocator, voila_root);
    defer allocator.free(path);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (ids) |i| {
        if (std.mem.eql(u8, i, id)) continue;
        try buf.appendSlice(allocator, i);
        try buf.append(allocator, '\n');
    }
    try writeFile(path, buf.items);
}

fn dupField(allocator: std.mem.Allocator, o: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = o.get(key) orelse return allocator.dupe(u8, "");
    if (v != .string) return allocator.dupe(u8, "");
    return allocator.dupe(u8, v.string);
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

fn appendFile(path: []const u8, data: []const u8) !void {
    const path_z = try std.heap.page_allocator.allocSentinel(u8, path.len, 0);
    defer std.heap.page_allocator.free(path_z);
    @memcpy(path_z, path);
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.FileOpenFailed;
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data[off..].ptr, data.len - off);
        if (n <= 0) return error.FileWriteFailed;
        off += @intCast(n);
    }
}

pub const Error = error{ NotFound, BadState, FileOpenFailed, FileWriteFailed };
