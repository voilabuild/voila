const std = @import("std");
const trace = @import("sys").trace;
const command = @import("command.zig");
const flags = @import("flags.zig");
const voila_refkey = @import("core").voila_refkey;
const voila_runtime = @import("runtime").open;
const run_flags = @import("runtime").run_flags;
const voila_image_run_config = @import("runtime").oci.voila_image_run_config;
const registry_session = @import("registry").registry_session;
const voila_registry_fetch = @import("registry").voila_registry_fetch;
const voila_registry_hub = @import("registry").voila_registry_hub;
const posix_util = @import("sys").posix_util;

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
    /// `--entrypoint`: replaces the image ENTRYPOINT and drops its CMD, as in Docker.
    entrypoint: ?[]const u8 = null,
    /// `-u/--user`: overrides the image USER.
    user: ?[]const u8 = null,
    hostname: ?[]const u8 = null,
    network: ?[]const u8 = null,

    pub fn deinit(self: Parsed, allocator: std.mem.Allocator) void {
        if (self.hostname) |h| allocator.free(h);
        if (self.network) |n| allocator.free(n);
        if (self.entrypoint) |e| allocator.free(e);
        if (self.user) |u| allocator.free(u);
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
    var entrypoint: ?[]const u8 = null;
    var user: ?[]const u8 = null;
    var hostname: ?[]const u8 = null;
    var network: ?[]const u8 = null;
    errdefer if (hostname) |h| allocator.free(h);
    errdefer if (network) |n| allocator.free(n);
    errdefer if (entrypoint) |e| allocator.free(e);
    errdefer if (user) |u| allocator.free(u);
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
        if (std.mem.eql(u8, arg, "--env-file")) {
            const path = args.next() orelse return error.BadRunArgs;
            try appendEnvFile(allocator, &env_list, path);
            continue;
        }
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--hostname")) {
            const h = args.next() orelse return error.BadRunArgs;
            if (hostname) |old| allocator.free(old);
            hostname = try allocator.dupe(u8, h);
            continue;
        }
        if (std.mem.eql(u8, arg, "--network") or std.mem.eql(u8, arg, "--net")) {
            const n = args.next() orelse return error.BadRunArgs;
            if (!std.mem.eql(u8, n, "none") and !std.mem.eql(u8, n, "bridge") and !std.mem.eql(u8, n, "default")) {
                diag.flag = n;
                return error.UnsupportedNetwork;
            }
            if (network) |old| allocator.free(old);
            network = try allocator.dupe(u8, if (std.mem.eql(u8, n, "none")) "none" else "");
            continue;
        }
        if (std.mem.eql(u8, arg, "--entrypoint")) {
            const e = args.next() orelse return error.BadRunArgs;
            if (entrypoint) |old| allocator.free(old);
            entrypoint = try allocator.dupe(u8, e);
            continue;
        }
        if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--user")) {
            const u = args.next() orelse return error.BadRunArgs;
            if (user) |old| allocator.free(old);
            user = try allocator.dupe(u8, u);
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
        .entrypoint = entrypoint,
        .user = user,
        .hostname = hostname,
        .network = network,
    };
}

/// Docker `--env-file`: `KEY=VALUE` lines; blank lines and `#` comments are skipped.
fn appendEnvFile(allocator: std.mem.Allocator, list: *std.ArrayList(run_flags.EnvPair), path: []const u8) !void {
    const data = posix_util.readFileAlloc(allocator, path, 1 << 20) catch return error.EnvFileUnreadable;
    defer allocator.free(data);
    try parseEnvFile(allocator, list, data);
}

fn parseEnvFile(allocator: std.mem.Allocator, list: *std.ArrayList(run_flags.EnvPair), data: []const u8) !void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const pair = run_flags.parseEnvArg(line) catch continue; // a bare KEY has no value to pass
        try list.append(allocator, .{
            .key = try allocator.dupe(u8, pair.key),
            .value = try allocator.dupe(u8, pair.value),
        });
    }
}

/// ENTRYPOINT + (args or CMD), or `--entrypoint` + args.
fn commandArgv(io: std.Io, allocator: std.mem.Allocator, parsed: Parsed) ![]const []const u8 {
    if (parsed.entrypoint) |ep| {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |a| allocator.free(a);
            out.deinit(allocator);
        }
        try out.append(allocator, try allocator.dupe(u8, ep));
        for (parsed.cmd) |a| try out.append(allocator, try allocator.dupe(u8, a));
        return out.toOwnedSlice(allocator);
    }
    return voila_image_run_config.defaultArgv(io, allocator, parsed.runtime_cfg.store_root, parsed.image, parsed.cmd);
}

pub fn execute(ctx: command.Ctx) !void {
    const gpa = ctx.gpa();
    var diag: Diag = .{};
    const parsed = parseArgs(gpa, ctx.args, &diag) catch |e| {
        if (e == error.UnknownFlag) {
            std.debug.print("voila run: unknown flag {s}\n", .{diag.flag});
            std.process.exit(2);
        }
        if (e == error.UnsupportedNetwork) {
            std.debug.print("voila run: --network {s} is not supported yet (use the default or none)\n", .{diag.flag});
            std.process.exit(2);
        }
        return e;
    };
    defer parsed.deinit(gpa);
    if (parsed.network != null and parsed.network.?.len > 0 and parsed.ports.len > 0) {
        std.debug.print("voila run: -p cannot be used with --network none\n", .{});
        std.process.exit(2);
    }
    const t_prepare = trace.begin("registry session");
    try registry_session.prepare(ctx.io, gpa, parsed.runtime_cfg.store_root);
    t_prepare.end();
    const t_runtime = trace.begin("open runtime");
    var worker = try command.openRuntime(gpa, parsed.runtime_cfg);
    defer worker.deinit(gpa);
    t_runtime.end();
    const t_config = trace.begin("image config (cmd, env, workdir, user)");
    const argv = try commandArgv(ctx.io, gpa, parsed);
    defer {
        for (argv) |s| gpa.free(s);
        gpa.free(argv);
    }
    const image_env = try voila_image_run_config.imageEnv(ctx.io, gpa, parsed.runtime_cfg.store_root, parsed.image);
    defer {
        for (image_env) |e| {
            gpa.free(e.key);
            gpa.free(e.value);
        }
        gpa.free(image_env);
    }
    const term: []const run_flags.EnvPair = if (parsed.tty and !hasEnv(image_env, "TERM") and !hasEnv(parsed.env, "TERM"))
        &.{.{ .key = "TERM", .value = "xterm" }}
    else
        &.{};
    const env = try std.mem.concat(gpa, run_flags.EnvPair, &.{ image_env, term, parsed.env });
    defer gpa.free(env);
    var workdir = parsed.workdir;
    var workdir_from_image: ?[]const u8 = null;
    if (workdir.len == 0) {
        workdir_from_image = try voila_image_run_config.imageWorkdir(ctx.io, gpa, parsed.runtime_cfg.store_root, parsed.image);
        workdir = workdir_from_image.?;
    }
    defer if (workdir_from_image) |w| gpa.free(w);
    const image_user = try voila_image_run_config.imageUser(ctx.io, gpa, parsed.runtime_cfg.store_root, parsed.image);
    defer gpa.free(image_user);
    const user = parsed.user orelse image_user;
    t_config.end();
    voila_registry_fetch.exportChunkEndpoint(voila_registry_hub.defaultHub(), gpa);
    const code = try worker.run(ctx.io, gpa, .{
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
        .user = user,
        .hostname = parsed.hostname orelse "",
        .network = parsed.network orelse "",
    });
    std.process.exit(code);
}

fn hasEnv(env: []const run_flags.EnvPair, key: []const u8) bool {
    for (env) |e| if (std.mem.eql(u8, e.key, key)) return true;
    return false;
}

test "run parses --entrypoint, -u and keeps args for the entrypoint" {
    const alloc = std.testing.allocator;
    const argv: []const [*:0]const u8 = &.{ "-root", "/voila-test-root", "--entrypoint", "/bin/echo", "-u", "1000:1000", "alpine:3", "hi" };
    var it = std.process.Args.Iterator.init(.{ .vector = argv });
    var diag: Diag = .{};
    const parsed = try parseArgs(alloc, &it, &diag);
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("/bin/echo", parsed.entrypoint.?);
    try std.testing.expectEqualStrings("1000:1000", parsed.user.?);
    try std.testing.expectEqualStrings("hi", parsed.cmd[0]);
}

test "parseEnvFile skips comments, blanks and bare keys" {
    const alloc = std.testing.allocator;
    var list: std.ArrayList(run_flags.EnvPair) = .empty;
    defer {
        for (list.items) |e| {
            alloc.free(e.key);
            alloc.free(e.value);
        }
        list.deinit(alloc);
    }
    try parseEnvFile(alloc, &list, "# c\n\nA=1\r\nBARE\nB=x=y\n");
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("A", list.items[0].key);
    try std.testing.expectEqualStrings("1", list.items[0].value);
    try std.testing.expectEqualStrings("x=y", list.items[1].value);
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
