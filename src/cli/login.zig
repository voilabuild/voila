const std = @import("std");
const command = @import("command.zig");
const voila_paths = @import("sys").voila_paths;
const voila_login_creds = @import("registry").voila_login_creds;

pub fn execute(ctx: command.Ctx) !void {
    try run(ctx.io, ctx.gpa(), ctx.init);
}

pub fn run(io: std.Io, gpa: std.mem.Allocator, init: std.process.Init) !void {
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
        const line = try readLineAlloc(gpa);
        defer gpa.free(line);
        if (line.len != 0) raw_url = line;
    }

    const registry = try voila_paths.normalizeRegistryUrl(gpa, raw_url);
    defer gpa.free(registry);

    const token = if (std.c.getenv("VOILA_REGISTRY_TOKEN")) |t|
        try gpa.dupe(u8, std.mem.span(t))
    else blk: {
        std.debug.print("API key (dreg_...): ", .{});
        break :blk try readLineAlloc(gpa);
    };
    defer gpa.free(token);
    if (token.len == 0) return error.BadRunArgs;

    // Check the key before asking anything else.
    voila_login_creds.probeRegistryAuth(io, gpa, registry, token) catch |e| switch (e) {
        error.InvalidApiKey => {
            std.debug.print("voila login: {s} rejected this API key (check it and try again)\n", .{registry});
            std.process.exit(1);
        },
        else => return e,
    };

    // Default org: $VOILA_ORG, else the one saved for this registry by an earlier login.
    const previous = voila_login_creds.loadLoginCreds(gpa) catch null;
    defer if (previous) |p| {
        gpa.free(p.registry);
        gpa.free(p.token);
        gpa.free(p.org);
    };
    var org_default: []const u8 = "";
    if (previous) |p| if (std.mem.eql(u8, p.registry, registry)) {
        org_default = p.org;
    };
    if (std.c.getenv("VOILA_ORG")) |o| org_default = std.mem.span(o);
    const org_line = if (org_default.len != 0 and std.c.getenv("VOILA_REGISTRY_TOKEN") != null)
        try gpa.dupe(u8, org_default)
    else blk: {
        std.debug.print("Org namespace", .{});
        if (org_default.len != 0) std.debug.print(" [{s}]", .{org_default});
        std.debug.print(": ", .{});
        break :blk try readLineAlloc(gpa);
    };
    defer gpa.free(org_line);
    const org = std.mem.trim(u8, if (org_line.len != 0) org_line else org_default, " \t");

    voila_login_creds.saveLoginCreds(gpa, registry, token, org) catch |e| {
        std.debug.print("voila login: could not write ~/.config/voila/credentials: {s}\n", .{@errorName(e)});
        return e;
    };
    if (org.len == 0) std.debug.print("no org saved: push as <org>/<name>:<tag>, or set VOILA_ORG\n", .{});
    std.debug.print("logged in to {s}\n", .{registry});
}

/// One byte at a time: a buffered read would swallow the next answer when stdin is piped.
fn readLineAlloc(allocator: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var c: u8 = 0;
    while (true) {
        const n = std.c.read(std.posix.STDIN_FILENO, @ptrCast(&c), 1);
        if (n == 0) break;
        if (n < 0) return error.BadRunArgs;
        if (c == '\n') break;
        if (c != '\r') try buf.append(allocator, c);
    }
    return buf.toOwnedSlice(allocator);
}
