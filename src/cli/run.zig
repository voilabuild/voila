const std = @import("std");
const command = @import("command.zig");
const flags = @import("flags.zig");
const voila_refkey = @import("core").voila_refkey;
const voila_runtime = @import("runtime").open;
const run_flags = @import("runtime").run_flags;
const voila_image_run_config = @import("runtime").oci.voila_image_run_config;
const registry_session = @import("registry").registry_session;

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

/// Filled by `parseArgs` when it returns `error.UnknownFlag`; points into argv.
pub const Diag = struct { flag: []const u8 = "" };

pub fn parseArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator, diag: *Diag) !Parsed {
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
        if (arg.len > 1 and arg[0] == '-') {
            diag.flag = arg;
            return error.UnknownFlag;
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

pub fn execute(ctx: command.Ctx) !void {
    const gpa = ctx.gpa();
    var diag: Diag = .{};
    const parsed = parseArgs(gpa, ctx.args, &diag) catch |e| {
        if (e == error.UnknownFlag) {
            std.debug.print("voila run: unknown flag {s}\n", .{diag.flag});
            std.process.exit(2);
        }
        return e;
    };
    defer parsed.deinit(gpa);
    try registry_session.prepare(ctx.io, gpa, parsed.runtime_cfg.store_root);
    var worker = try command.openRuntime(gpa, parsed.runtime_cfg);
    defer worker.deinit(gpa);
    var argv = parsed.cmd;
    var default_argv: ?[]const []const u8 = null;
    if (argv.len == 0) {
        default_argv = try voila_image_run_config.defaultArgv(ctx.io, gpa, parsed.runtime_cfg.store_root, parsed.image, &.{});
        argv = default_argv.?;
    }
    defer if (default_argv) |a| {
        for (a) |s| gpa.free(s);
        gpa.free(a);
    };
    const image_env = try voila_image_run_config.imageEnv(ctx.io, gpa, parsed.runtime_cfg.store_root, parsed.image);
    defer {
        for (image_env) |e| {
            gpa.free(e.key);
            gpa.free(e.value);
        }
        gpa.free(image_env);
    }
    const env = try std.mem.concat(gpa, run_flags.EnvPair, &.{ image_env, parsed.env });
    defer gpa.free(env);
    var workdir = parsed.workdir;
    var workdir_from_image: ?[]const u8 = null;
    if (workdir.len == 0) {
        workdir_from_image = try voila_image_run_config.imageWorkdir(ctx.io, gpa, parsed.runtime_cfg.store_root, parsed.image);
        workdir = workdir_from_image.?;
    }
    defer if (workdir_from_image) |w| gpa.free(w);
    const code = worker.run(ctx.io, gpa, .{
        .image = parsed.image,
        .argv = argv,
        .detach = parsed.detach,
        .name = parsed.name,
        .rm_on_exit = parsed.rm_on_exit,
        .env = env,
        .workdir = workdir,
        .volumes = parsed.volumes,
        .ports = parsed.ports,
        .tty = parsed.tty,
        .interactive = parsed.interactive,
    }) catch |e| {
        if (e == error.UserNamespacesRequired) std.process.exit(1);
        return e;
    };
    std.process.exit(code);
}

test "run drops -- right after image ref" {
    const alloc = std.testing.allocator;
    const argv: []const [*:0]const u8 = &.{ "-root", "/voila-test-root", "alpine:3", "--", "echo", "--", "hi" };
    var it = std.process.Args.Iterator.init(.{ .vector = argv });
    var diag: Diag = .{};
    const parsed = try parseArgs(alloc, &it, &diag);
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
    var diag: Diag = .{};
    const parsed = try parseArgs(alloc, &it, &diag);
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("alpine:3", parsed.image);
    try std.testing.expectEqual(@as(usize, 2), parsed.cmd.len);
    try std.testing.expectEqualStrings("echo", parsed.cmd[0]);
    try std.testing.expectEqualStrings("hi", parsed.cmd[1]);
}

test "run rejects unknown flags before the image ref" {
    const alloc = std.testing.allocator;
    for ([_][:0]const u8{ "--bogus", "--detatch", "-x" }) |flag| {
        const argv: []const [*:0]const u8 = &.{ "-d", flag.ptr, "alpine:3", "true" };
        var it = std.process.Args.Iterator.init(.{ .vector = argv });
        var diag: Diag = .{};
        try std.testing.expectError(error.UnknownFlag, parseArgs(alloc, &it, &diag));
        try std.testing.expectEqualStrings(flag, diag.flag);
    }
}

test "run passes flags after the image ref to the command" {
    const alloc = std.testing.allocator;
    const argv: []const [*:0]const u8 = &.{ "-root", "/voila-test-root", "alpine:3", "ls", "-la" };
    var it = std.process.Args.Iterator.init(.{ .vector = argv });
    var diag: Diag = .{};
    const parsed = try parseArgs(alloc, &it, &diag);
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("-la", parsed.cmd[1]);
}
