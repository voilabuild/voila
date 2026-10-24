//! `voila build`: run a parsed Dockerfile against the chunk store, one cached step at a time.
const std = @import("std");
const dockerfile = @import("../../core/dockerfile.zig");
const cache_key = @import("../../core/build_cache_key.zig");
const glob = @import("../../core/glob.zig");
const fs = @import("../../sys/fs.zig");
const clock = @import("../../sys/clock.zig");
const posix_util = @import("../../sys/posix_util.zig");
const idmap = @import("../../core/idmap.zig");
const oci_config = @import("../../codec/oci_image_config.zig");
const tree_mod = @import("../../store/ingest/ingest_tree.zig");
const dir_walk = @import("../../store/ingest/ingest_dir_walk.zig");
const from_manifest = @import("../../store/ingest/ingest_from_manifest.zig");
const manifest_mod = @import("../../store/ingest/ingest_manifest.zig");
const merge_mod = @import("../../store/ingest/ingest_merge.zig");
const ingest_build = @import("../../store/ingest/ingest_build.zig");
const chunk_store = @import("../../store/ingest/ingest_chunk_store.zig");
const build_cache = @import("../../store/build_cache.zig");
const image_store = @import("image_store.zig");
const copy_sources = @import("copy_sources.zig");
pub const steps = @import("steps.zig");

pub const RunRequest = steps.RunRequest;
pub const StepRunner = steps.StepRunner;

pub const StepEvent = struct {
    index: usize,
    total: usize,
    text: []const u8,
    cached: bool,
    elapsed_ns: u64,
};

pub const Progress = struct {
    ptr: *anyopaque,
    func: *const fn (ptr: *anyopaque, ev: StepEvent) void,
};

pub const Options = struct {
    voila_root: []const u8,
    context_dir: []const u8,
    dockerfile_text: []const u8,
    tag: []const u8,
    build_args: []const dockerfile.KeyValue = &.{},
    no_cache: bool = false,
    runner: StepRunner,
    progress: ?Progress = null,
};

pub const Diagnostic = struct {
    line: usize = 0,
    exit_code: u8 = 0,
};

pub const Result = struct {
    root: [32]u8,
    config: [32]u8,
    steps: usize,
    cached: usize,
};

pub const Error = error{ RunFailed, UnsupportedChown, EmptyBuild };

pub fn build(io: std.Io, gpa: std.mem.Allocator, opts: Options, diag: *Diagnostic) !Result {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var pdiag: dockerfile.Diagnostic = .{};
    var df = dockerfile.parse(gpa, opts.dockerfile_text, &pdiag) catch |e| {
        diag.line = pdiag.line;
        return e;
    };
    defer df.deinit();

    var b: Builder = .{ .io = io, .a = a, .opts = opts, .diag = diag };
    b.config = try oci_config.ImageConfig.parse(a, "");
    try b.loadIgnore();
    for (df.global_args) |arg| try b.declareArg(arg);
    b.globals = try b.args.toOwnedSlice(a);

    const from = df.instructions[0];
    diag.line = from.line;
    const base_ref = try b.expand(from.op.from);
    const base = try image_store.loadBase(io, a, opts.voila_root, base_ref);
    b.root = base.root;
    b.config = try oci_config.ImageConfig.parse(a, base.config_json);
    b.vars.clearRetainingCapacity();
    const env = try b.config.getStrings(a, "Env");
    for (env) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        try b.vars.put(a, kv[0..eq], kv[eq + 1 ..]);
    }

    const total = df.instructions.len;
    b.emit(0, total, from.text, false, 0);
    for (df.instructions[1..], 1..) |ins, i| {
        diag.line = ins.line;
        const t0 = clock.monotonicNs();
        const cached = try b.step(ins);
        b.emit(i, total, ins.text, cached, clock.monotonicNs() - t0);
    }
    diag.line = 0;

    const config_json = try b.config.serialize(a);
    const config_chunk = try chunk_store.putBytes(a, opts.voila_root, config_json);
    try image_store.persist(a, opts.voila_root, opts.tag, .{
        .root = b.root,
        .config = config_chunk,
        .layers = b.layers.items,
        .tree = b.tree,
    });
    return .{ .root = b.root, .config = config_chunk, .steps = total, .cached = b.cached };
}

const Builder = struct {
    io: std.Io,
    a: std.mem.Allocator,
    opts: Options,
    diag: *Diagnostic,
    vars: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// ARG values visible to RUN, in declaration order.
    args: std.ArrayList(dockerfile.KeyValue) = .empty,
    /// ARGs declared before FROM: only FROM sees them, unless redeclared by name.
    globals: []const dockerfile.KeyValue = &.{},
    config: oci_config.ImageConfig = undefined,
    root: [32]u8 = undefined,
    /// Current merged tree; null until a step needs it (cache hits never load it).
    tree: ?*tree_mod.LayerTree = null,
    layers: std.ArrayList(ingest_build.LayerResult) = .empty,
    ignore: glob.Ignore = .{ .rules = &.{} },
    cached: usize = 0,
    cmd_from_build: bool = false,

    fn emit(self: *Builder, index: usize, total: usize, text: []const u8, cached: bool, ns: u64) void {
        const p = self.opts.progress orelse return;
        p.func(p.ptr, .{ .index = index, .total = total, .text = text, .cached = cached, .elapsed_ns = ns });
    }

    fn loadIgnore(self: *Builder) !void {
        const path = try std.fmt.allocPrint(self.a, "{s}/.dockerignore", .{self.opts.context_dir});
        const f = fs.File.openRead(path) catch return;
        defer f.close();
        const buf = try self.a.alloc(u8, 1 << 20);
        const n = try f.readFull(buf);
        self.ignore = try glob.Ignore.parse(self.a, buf[0..n]);
    }

    fn expand(self: *Builder, s: []const u8) ![]u8 {
        return dockerfile.expand(self.a, s, &self.vars);
    }

    fn declareArg(self: *Builder, arg: dockerfile.Arg) !void {
        var value: ?[]const u8 = null;
        for (self.opts.build_args) |kv| {
            if (std.mem.eql(u8, kv.key, arg.name)) value = kv.value;
        }
        if (value == null) if (arg.default) |d| {
            value = try self.expand(d);
        };
        if (value == null) for (self.globals) |g| {
            if (std.mem.eql(u8, g.key, arg.name)) value = g.value;
        };
        const v = value orelse return;
        try self.args.append(self.a, .{ .key = arg.name, .value = v });
        if (!self.envHas(arg.name)) try self.vars.put(self.a, arg.name, v);
    }

    fn envHas(self: *Builder, key: []const u8) bool {
        const env = self.config.getStrings(self.a, "Env") catch return false;
        for (env) |kv| {
            if (std.mem.startsWith(u8, kv, key) and kv.len > key.len and kv[key.len] == '=') return true;
        }
        return false;
    }

    /// Returns true when the step was served from the cache.
    fn step(self: *Builder, ins: dockerfile.Instruction) !bool {
        switch (ins.op) {
            .from => unreachable,
            .arg => |arg| try self.declareArg(arg),
            .env => |kvs| for (kvs) |kv| {
                const v = try self.expand(kv.value);
                try self.config.setEnv(kv.key, v);
                try self.vars.put(self.a, kv.key, v);
            },
            .label => |kvs| for (kvs) |kv| try self.config.setLabel(try self.expand(kv.key), try self.expand(kv.value)),
            .expose => |ports| for (ports) |p| try self.config.addExposedPort(try self.expand(p)),
            .user => |u| try self.config.setString("User", try self.expand(u)),
            .workdir => |w| try self.config.setString("WorkingDir", try steps.joinPath(self.a, try self.config.getString("WorkingDir"), try self.expand(w))),
            .cmd => |f| {
                try self.config.setStrings("Cmd", try steps.formArgv(self.a, f));
                self.cmd_from_build = true;
            },
            .entrypoint => |f| {
                try self.config.setStrings("Entrypoint", try steps.formArgv(self.a, f));
                if (!self.cmd_from_build) try self.config.setStrings("Cmd", null);
            },
            .run => |f| return self.run(ins.text, f),
            .copy, .add => |c| return self.copy(c),
        }
        return false;
    }

    fn runEnv(self: *Builder) ![]const []const u8 {
        var env: std.ArrayList([]const u8) = .empty;
        const base = try self.config.getStrings(self.a, "Env");
        try env.appendSlice(self.a, base);
        for (self.args.items) |kv| {
            if (self.envHas(kv.key)) continue;
            try env.append(self.a, try std.fmt.allocPrint(self.a, "{s}={s}", .{ kv.key, kv.value }));
        }
        if (!self.envHas("PATH")) try env.append(self.a, steps.default_path);
        return env.toOwnedSlice(self.a);
    }

    fn run(self: *Builder, text: []const u8, form: dockerfile.Form) !bool {
        const env = try self.runEnv();
        const workdir = try self.config.getString("WorkingDir");
        const user = try self.config.getString("User");
        const key = cache_key.compute(.{ .parent_root = self.root, .instruction = text, .env = env, .workdir = workdir, .user = user });
        if (self.cacheHit(key)) return true;

        const scratch = try fs.makeTempDir(self.a, "voila-build");
        defer fs.removeTree(self.a, scratch) catch {};
        const upper = try std.fmt.allocPrint(self.a, "{s}/upper", .{scratch});
        try fs.mkdir(upper, 0o755);
        const owners_path = try std.fmt.allocPrint(self.a, "{s}/owners", .{scratch});
        const res = try self.opts.runner.run(self.io, .{
            .voila_root = self.opts.voila_root,
            .root = self.root,
            .scratch_dir = scratch,
            .upper_dir = upper,
            .argv = try steps.formArgv(self.a, form),
            .env = env,
            .workdir = workdir,
            .user = user,
            .owners_path = owners_path,
        });
        if (res.code != 0) {
            self.diag.exit_code = res.code;
            return error.RunFailed;
        }
        var owners: dir_walk.Owners = .empty;
        if (posix_util.readFileAlloc(self.a, owners_path, 1 << 30)) |bytes| {
            owners = try dir_walk.parseOwners(self.a, bytes);
        } else |e| if (e != error.FileNotFound) return e;
        var skip: steps.MountpointSkip = .{};
        var w = try dir_walk.Walker.init(self.a, self.opts.voila_root, .{
            .mode = .overlay_upper,
            .ids = res.ids orelse idmap.Mapping.single(std.os.linux.getuid(), std.os.linux.getgid()),
            .owners = &owners,
            .skip = skip.skip(),
        });
        defer w.deinit();
        try w.add(upper, "");
        try self.commit(key, w.finish().tree);
        return false;
    }

    fn copy(self: *Builder, c: dockerfile.Copy) !bool {
        var srcs: std.ArrayList([]const u8) = .empty;
        for (c.srcs) |s| try srcs.append(self.a, try self.expand(s));
        const dest_raw = try self.expand(c.dest);
        const owner = try steps.parseChown(try self.expand(c.chown));
        const sources = try copy_sources.resolve(self.a, self.opts.context_dir, srcs.items, self.ignore);
        const dest = try steps.joinPath(self.a, try self.config.getString("WorkingDir"), dest_raw);
        const into_dir = std.mem.endsWith(u8, dest_raw, "/") or sources.len > 1 or
            (sources.len == 1 and sources[0].is_dir) or glob.hasWildcard(srcs.items[0]);

        const norm = try std.fmt.allocPrint(self.a, "COPY {d}:{d} {s} {s}", .{ owner.uid, owner.gid, dest, if (into_dir) "dir" else "file" });
        const key = cache_key.compute(.{
            .parent_root = self.root,
            .instruction = norm,
            .inputs_digest = try copy_sources.digest(self.a, sources, self.ignore),
        });
        if (self.cacheHit(key)) return true;

        var w = try dir_walk.Walker.init(self.a, self.opts.voila_root, .{ .mode = .copy, .owner = owner });
        defer w.deinit();
        const dest_rel = std.mem.trimStart(u8, dest, "/");
        for (sources) |s| {
            var ig: copy_sources.IgnoreSkip = .{ .ignore = self.ignore, .prefix = s.rel };
            w.opts.skip = ig.skip();
            const target = if (s.is_dir or !into_dir) dest_rel else try steps.joinRel(self.a, dest_rel, std.fs.path.basename(s.rel));
            try w.add(s.abs, target);
        }
        try self.commit(key, w.finish().tree);
        return false;
    }

    fn cacheHit(self: *Builder, key: cache_key.Key) bool {
        if (self.opts.no_cache) return false;
        const hit = build_cache.get(self.a, self.opts.voila_root, key) orelse return false;
        self.root = hit.root;
        self.tree = null;
        self.layers.append(self.a, .{ .root_manifest_chunk = hit.layer, .whiteouts_count = hit.whiteouts }) catch return false;
        self.cached += 1;
        return true;
    }

    fn commit(self: *Builder, key: cache_key.Key, diff: *tree_mod.LayerTree) !void {
        const current = self.tree orelse try from_manifest.loadTree(self.a, self.opts.voila_root, self.root);
        var pair = [_]*tree_mod.LayerTree{ current, diff };
        const merged = try merge_mod.mergeTrees(self.a, &pair);
        const layer = try manifest_mod.buildAndStoreManifest(self.a, self.opts.voila_root, diff, true);
        self.root = try manifest_mod.buildAndStoreManifest(self.a, self.opts.voila_root, merged, false);
        self.tree = merged;
        const whiteouts = diff.whiteouts_n + diff.opaque_n;
        try self.layers.append(self.a, .{ .root_manifest_chunk = layer, .whiteouts_count = whiteouts });
        try build_cache.put(self.a, self.opts.voila_root, key, .{ .root = self.root, .layer = layer, .whiteouts = whiteouts });
    }
};
