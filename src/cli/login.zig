const std = @import("std");
const command = @import("command.zig");
const voila_paths = @import("sys").voila_paths;
const voila_login_creds = @import("registry").voila_login_creds;

pub fn execute(ctx: command.Ctx) !void {
    try run(ctx.io, ctx.init);
}

pub fn run(io: std.Io, init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    _ = args.next();
    const url_arg = args.next();

    var raw_url: []const u8 = voila_paths.default_registry_url;
    if (url_arg) |u| {
        raw_url = u;
    } else if (std.c.getenv("VOILA_REGISTRY")) |e| {
        raw_url = std.mem.span(e);
    } else {
        std.debug.print("Registry URL [{s}]: ", .{voila_paths.default_registry_url});
        const line = try readLineAlloc(init.gpa);
        defer init.gpa.free(line);
        if (line.len != 0) raw_url = line;
    }

    const registry = try voila_paths.normalizeRegistryUrl(init.gpa, raw_url);
    defer init.gpa.free(registry);

    const token = if (std.c.getenv("VOILA_REGISTRY_TOKEN")) |t|
        try init.gpa.dupe(u8, std.mem.span(t))
    else blk: {
        std.debug.print("API key (dreg_...): ", .{});
        break :blk try readLineAlloc(init.gpa);
    };
    defer init.gpa.free(token);
    if (token.len == 0) return error.BadRunArgs;

    var org_default: []const u8 = "";
    if (std.c.getenv("VOILA_ORG")) |o| org_default = std.mem.span(o);
    const org_line = if (org_default.len != 0 and std.c.getenv("VOILA_REGISTRY_TOKEN") != null)
        try init.gpa.dupe(u8, org_default)
    else blk: {
        std.debug.print("Org namespace", .{});
        if (org_default.len != 0) std.debug.print(" [{s}]", .{org_default});
        std.debug.print(": ", .{});
        break :blk try readLineAlloc(init.gpa);
    };
    defer init.gpa.free(org_line);
    const org_owned = if (org_line.len != 0)
        try init.gpa.dupe(u8, org_line)
    else
        try init.gpa.dupe(u8, org_default);
    defer init.gpa.free(org_owned);

    try voila_login_creds.probeRegistryAuth(io, init.gpa, registry, token);
    try voila_login_creds.saveLoginCreds(init.gpa, registry, token, org_owned);
    std.debug.print("logged in to {s}\n", .{registry});
}

fn readLineAlloc(allocator: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var chunk: [256]u8 = undefined;
    const stdin_fd = std.posix.STDIN_FILENO;
    while (true) {
        const n = std.c.read(stdin_fd, chunk[0..].ptr, chunk.len);
        if (n == 0) break;
        if (n < 0) return error.BadRunArgs;
        for (chunk[0..@intCast(n)]) |c| {
            if (c == '\n') return try buf.toOwnedSlice(allocator);
            if (c != '\r') try buf.append(allocator, c);
        }
    }
    return try buf.toOwnedSlice(allocator);
}
