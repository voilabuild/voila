const std = @import("std");
const flags = @import("flags.zig");
const voila_refkey = @import("core").voila_refkey;
const voila_runtime = @import("runtime").open;
const run_flags = @import("runtime").run_flags;

pub const Parsed = struct {
    runtime_cfg: voila_runtime.Config,
    image: []const u8,
    cmd: []const []const u8,
    detach: bool,
    name: []const u8,
    rm_on_exit: bool,
    env: []run_flags.EnvPair,
    workdir: []const u8,
    volumes: []run_flags.Volume,
    ports: []run_flags.PortMap,
    tty: bool,
    interactive: bool,

    pub fn deinit(self: Parsed, allocator: std.mem.Allocator) void {
        allocator.free(self.runtime_cfg.store_root);
        allocator.free(self.image);
        allocator.free(self.name);
        allocator.free(self.workdir);
        for (self.cmd) |a| allocator.free(a);
        allocator.free(self.cmd);
        for (self.env) |e| {
            allocator.free(e.key);
            allocator.free(e.value);
        }
        allocator.free(self.env);
        for (self.volumes) |v| {
            allocator.free(v.host);
            allocator.free(v.container);
        }
        allocator.free(self.volumes);
        allocator.free(self.ports);
    }
};

pub fn parseArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !Parsed {
    var root: ?[]const u8 = null;
    var kind = voila_runtime.kindFromEnv();
    var image: ?[]const u8 = null;
    var cmd_list: std.ArrayList([]const u8) = .empty;
    var after_sep = false;
    var detach = false;
    var name: ?[]const u8 = null;
    var rm_on_exit = false;
    var env_list: std.ArrayList(run_flags.EnvPair) = .empty;
    var vol_list: std.ArrayList(run_flags.Volume) = .empty;
    var port_list: std.ArrayList(run_flags.PortMap) = .empty;
    var workdir: ?[]const u8 = null;
    var tty = false;
    var interactive = false;
    while (args.next()) |arg| {
        if (after_sep) {
            try cmd_list.append(allocator, try allocator.dupe(u8, arg));
            continue;
        }
        if (image != null) {
            if (cmd_list.items.len == 0 and std.mem.eql(u8, arg, "--")) {
                after_sep = true;
                continue;
            }
            try cmd_list.append(allocator, try allocator.dupe(u8, arg));
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            after_sep = true;
            continue;
        }
        if (try flags.tryRuntimeFlag(allocator, arg, args, &root, &kind)) continue;
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--detach")) {
            detach = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--name")) {
            const n = args.next() orelse return error.BadRunArgs;
            name = try allocator.dupe(u8, n);
            continue;
        }
        if (std.mem.eql(u8, arg, "--rm")) {
            rm_on_exit = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--env")) {
            const e = args.next() orelse return error.BadRunArgs;
            const pair = try run_flags.parseEnvArg(e);
            try env_list.append(allocator, .{
                .key = try allocator.dupe(u8, pair.key),
                .value = try allocator.dupe(u8, pair.value),
            });
            continue;
        }
        if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--workdir")) {
            const w = args.next() orelse return error.BadRunArgs;
            workdir = try allocator.dupe(u8, w);
            continue;
        }
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--volume")) {
            const v = args.next() orelse return error.BadRunArgs;
            const vol = try run_flags.parseVolumeSpec(v);
            try vol_list.append(allocator, .{
                .host = try allocator.dupe(u8, vol.host),
                .container = try allocator.dupe(u8, vol.container),
                .read_only = vol.read_only,
            });
            continue;
        }
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--publish")) {
            const p = args.next() orelse return error.BadRunArgs;
            try port_list.append(allocator, try run_flags.parsePortSpec(p));
            continue;
        }
        if (std.mem.eql(u8, arg, "-i")) {
            interactive = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-t")) {
            tty = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-it") or std.mem.eql(u8, arg, "-ti")) {
            interactive = true;
            tty = true;
            continue;
        }
        if (root == null and image == null and !voila_refkey.looksLikeRef(arg)) {
            root = try allocator.dupe(u8, arg);
            continue;
        }
        if (image == null) {
            image = try allocator.dupe(u8, arg);
            continue;
        }
        return error.BadRunArgs;
    }

    var image_ref = image;
    if (image_ref == null and root != null and voila_refkey.looksLikeRef(root.?)) {
        image_ref = root;
        root = null;
    }
    const image_final = image_ref orelse return error.NeedImage;

    const root_abs = try flags.resolveStoreRoot(allocator, root);
    if (root) |owned| allocator.free(owned);
    const name_final = name orelse try allocator.dupe(u8, "");
    const workdir_final = workdir orelse try allocator.dupe(u8, "");

    return .{
        .runtime_cfg = .{ .kind = kind, .store_root = root_abs },
        .image = image_final,
        .cmd = try cmd_list.toOwnedSlice(allocator),
        .detach = detach,
        .name = name_final,
        .rm_on_exit = rm_on_exit,
        .env = try env_list.toOwnedSlice(allocator),
        .workdir = workdir_final,
        .volumes = try vol_list.toOwnedSlice(allocator),
        .ports = try port_list.toOwnedSlice(allocator),
        .tty = tty,
        .interactive = interactive,
    };
}
test "run drops -- right after image ref" {
    const alloc = std.testing.allocator;
    const argv: []const [*:0]const u8 = &.{ "-root", "/voila-test-root", "alpine:3", "--", "echo", "--", "hi" };
    var it = std.process.Args.Iterator.init(.{ .vector = argv });
    const parsed = try parseArgs(alloc, &it);
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("alpine:3", parsed.image);
    try std.testing.expectEqual(@as(usize, 3), parsed.cmd.len);
    try std.testing.expectEqualStrings("echo", parsed.cmd[0]);
    try std.testing.expectEqualStrings("--", parsed.cmd[1]);
    try std.testing.expectEqualStrings("hi", parsed.cmd[2]);
}

test "run keeps argv without separator after image ref" {
    const alloc = std.testing.allocator;
    const argv: []const [*:0]const u8 = &.{ "-root", "/voila-test-root", "alpine:3", "echo", "hi" };
    var it = std.process.Args.Iterator.init(.{ .vector = argv });
    const parsed = try parseArgs(alloc, &it);
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("alpine:3", parsed.image);
    try std.testing.expectEqual(@as(usize, 2), parsed.cmd.len);
    try std.testing.expectEqualStrings("echo", parsed.cmd[0]);
    try std.testing.expectEqualStrings("hi", parsed.cmd[1]);
}
