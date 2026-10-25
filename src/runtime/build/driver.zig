//! `voila build`: run a parsed Dockerfile against the chunk store, one cached step at a time.
const std = @import("std");
const dockerfile = @import("core").dockerfile;
const cache_key = @import("core").build_cache_key;
const build_stages = @import("core").build_stages;
const glob = @import("core").glob;
const passwd = @import("core").passwd;
const fs = @import("sys").fs;
const clock = @import("sys").clock;
const posix_util = @import("sys").posix_util;
const idmap = @import("core").idmap;
const oci_config = @import("codec").oci_image_config;
const tree_mod = @import("store").ingest.ingest_tree;
const dir_walk = @import("store").ingest.ingest_dir_walk;
const from_manifest = @import("store").ingest.ingest_from_manifest;
const manifest_mod = @import("store").ingest.ingest_manifest;
const merge_mod = @import("store").ingest.ingest_merge;
const ingest_build = @import("store").ingest.ingest_build;
const voila_chunk_load = @import("store").voila_chunk_load;
const voila_registry_fetch = @import("registry").voila_registry_fetch;
const voila_chunk_index = @import("store").voila_chunk_index;
const voila_store = @import("store").voila_store;
const chunk_store = @import("store").ingest.ingest_chunk_store;
const build_cache = @import("store").build_cache;
const image_store = @import("image_store.zig");
const copy_sources = @import("copy_sources.zig");
const copy_from = @import("copy_from.zig");
pub const steps = @import("steps.zig");

pub const RunRequest = steps.RunRequest;
pub const StepRunner = steps.StepRunner;

pub const StepEvent = struct {
    /// Stage name, `stage-N` for unnamed stages of a multi-stage build, else empty.
    stage: []const u8 = "",
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
    /// Stage to build and tag; empty means the last one.
    target: []const u8 = "",
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
    /// RUN/COPY/ADD steps of the stages that were built (metadata instructions are excluded).
    steps: usize,
    cached: usize,
};

pub const Error = error{
    RunFailed,
    UnsupportedChown,
    UnknownChownName,
    ImageFileUnreadable,
    EmptyBuild,
    Unsupported,
    StageNotBuilt,
    DuplicateStage,
    UnknownTarget,
    StageNotFound,
};

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

    var s: Session = .{ .io = io, .a = a, .opts = opts, .diag = diag, .df = &df };
    try s.init();
    const target = try build_stages.targetIndex(&df, opts.target);
    const needed = try build_stages.needed(a, &df, target, &s.global_vars);
    for (needed, 0..) |n, i| if (n) {
        try s.stage(i);
    };
    const img = s.results[target].?;
    var steps_n: usize = 0;
    var cached: usize = 0;
    for (s.results) |r| if (r) |done| {
        steps_n += done.steps;
        cached += done.cached;
    };

    const config_chunk = try chunk_store.putBytes(a, opts.voila_root, img.config_json);
    try image_store.persist(a, opts.voila_root, opts.tag, .{
        .root = img.root,
        .config = config_chunk,
        .layers = img.layers,
        .tree = img.tree,
    });
    return .{ .root = img.root, .config = config_chunk, .steps = steps_n, .cached = cached };
}

const StageResult = struct {
    root: [32]u8,
    config_json: []const u8,
    layers: []ingest_build.LayerResult,
    tree: ?*tree_mod.LayerTree,
    steps: usize,
    cached: usize,
};

/// State shared by the stages of one build; needed stages are built once, in file order.
const Session = struct {
    io: std.Io,
    a: std.mem.Allocator,
    opts: Options,
    diag: *Diagnostic,
    df: *const dockerfile.Dockerfile,
    ignore: glob.Ignore = .{ .rules = &.{} },
    globals: []const dockerfile.KeyValue = &.{},
    global_vars: std.StringHashMapUnmanaged([]const u8) = .empty,
    results: []?StageResult = &.{},

    fn init(self: *Session) !void {
        var g = self.builder(0);
        g.config = try oci_config.ImageConfig.parse(self.a, "");
        try g.loadIgnore();
        self.ignore = g.ignore;
        for (self.df.global_args) |arg| try g.declareArg(arg);
        self.globals = try g.args.toOwnedSlice(self.a);
        self.global_vars = g.vars;
        self.results = try self.a.alloc(?StageResult, self.df.stages.len);
        @memset(self.results, null);
    }

    fn builder(self: *Session, index: usize) Builder {
        return .{ .io = self.io, .a = self.a, .opts = self.opts, .diag = self.diag, .session = self, .index = index, .ignore = self.ignore, .globals = self.globals };
    }

    fn label(self: *Session, index: usize) ![]const u8 {
        const name = self.df.stages[index].name;
        if (name.len > 0 or self.df.stages.len == 1) return name;
        return std.fmt.allocPrint(self.a, "stage-{d}", .{index});
    }

    /// Stages are built in file order, so a dependency is always done first;
    /// it is missing only when a `--from` ref needs a stage-local ARG.
    fn built(self: *Session, index: usize) Error!*const StageResult {
        if (self.results[index]) |*r| return r;
        return error.StageNotBuilt;
    }

    fn stage(self: *Session, index: usize) !void {
        var b = self.builder(index);
        b.label = try self.label(index);
        b.vars = try self.global_vars.clone(self.a);
        try b.from(self.df.stages[index].instructions[0]);
        const ins = self.df.stages[index].instructions;
        b.emit(0, ins.len, ins[0].text, false, 0);
        for (ins[1..], 1..) |in, i| {
            self.diag.line = in.line;
            const t0 = clock.monotonicNs();
            const cached = try b.step(in);
            b.emit(i, ins.len, in.text, cached, clock.monotonicNs() - t0);
        }
        self.diag.line = 0;
        self.results[index] = .{
            .root = b.root,
            .config_json = try b.config.serialize(self.a),
            .layers = b.layers.items,
            .tree = b.tree,
            .steps = b.steps,
            .cached = b.cached,
        };
    }
};

const Builder = struct {
    io: std.Io,
    a: std.mem.Allocator,
    opts: Options,
    diag: *Diagnostic,
    session: *Session,
    index: usize,
    label: []const u8 = "",
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
    /// RUN/COPY/ADD instructions executed in this stage.
    steps: usize = 0,
    cmd_from_build: bool = false,
    shell: []const []const u8 = &steps.default_shell,

    fn emit(self: *Builder, index: usize, total: usize, text: []const u8, cached: bool, ns: u64) void {
        const p = self.opts.progress orelse return;
        p.func(p.ptr, .{ .stage = self.label, .index = index, .total = total, .text = text, .cached = cached, .elapsed_ns = ns });
    }

    /// Starts the stage from an image or an earlier stage's result.
    fn from(self: *Builder, ins: dockerfile.Instruction) !void {
        self.diag.line = ins.line;
        const ref = try self.expand(ins.op.from.image);
        var config_json: []const u8 = "";
        switch (try build_stages.resolve(self.session.df, self.index, ref, false)) {
            .stage => |i| {
                const base = try self.session.built(i);
                self.root = base.root;
                self.tree = base.tree;
                try self.layers.appendSlice(self.a, base.layers);
                config_json = base.config_json;
            },
            .image => {
                const base = try image_store.loadBase(self.io, self.a, self.opts.voila_root, ref);
                self.root = base.root;
                config_json = base.config_json;
            },
        }
        self.config = try oci_config.ImageConfig.parse(self.a, config_json);
        self.vars.clearRetainingCapacity();
        const env = try self.config.getStrings(self.a, "Env");
        for (env) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            try self.vars.put(self.a, kv[0..eq], kv[eq + 1 ..]);
        }
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
            .shell => |sh| {
                self.shell = sh;
                try self.config.setStrings("Shell", sh);
            },
            .healthcheck => |hc| try self.config.setHealthcheck(hc),
            .stopsignal => |s| try self.config.setString("StopSignal", try self.expand(s)),
            .volume => |vols| for (vols) |v| try self.config.addVolume(try self.expand(v)),
            .maintainer => |m| try self.config.setAuthor(m),
            .cmd => |f| {
                try self.config.setStrings("Cmd", try steps.formArgv(self.a, f, self.shell));
                self.cmd_from_build = true;
            },
            .entrypoint => |f| {
                try self.config.setStrings("Entrypoint", try steps.formArgv(self.a, f, self.shell));
                if (!self.cmd_from_build) try self.config.setStrings("Cmd", null);
            },
            .run => |f| {
                self.steps += 1;
                return self.run(ins.text, f);
            },
            .copy => |c| {
                self.steps += 1;
                return if (c.from.len > 0) self.copyFrom(c) else self.copy(c);
            },
            .add => |c| {
                self.steps += 1;
                return if (c.from.len > 0) error.Unsupported else self.copy(c);
            },
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
        const shell_key = try std.mem.join(self.a, "\x00", self.shell);
        const instruction = if (form == .shell and !std.mem.eql(u8, shell_key, "/bin/sh\x00-c"))
            try std.fmt.allocPrint(self.a, "{s}\x00SHELL {s}", .{ text, shell_key })
        else
            text;
        const key = cache_key.compute(.{ .parent_root = self.root, .instruction = instruction, .env = env, .workdir = workdir, .user = user });
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
            .argv = try steps.formArgv(self.a, form, self.shell),
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
        try self.commit(key, (try w.finish()).tree);
        return false;
    }

    fn copy(self: *Builder, c: dockerfile.Copy) !bool {
        var srcs: std.ArrayList([]const u8) = .empty;
        for (c.srcs) |s| try srcs.append(self.a, try self.expand(s));
        const dest_raw = try self.expand(c.dest);
        const owner = try self.resolveOwner(try self.expand(c.chown));
        const sources = try copy_sources.resolve(self.a, self.opts.context_dir, srcs.items, self.ignore);
        const dest = try steps.joinPath(self.a, try self.config.getString("WorkingDir"), dest_raw);
        const into_dir = std.mem.endsWith(u8, dest_raw, "/") or sources.len > 1 or
            (sources.len == 1 and sources[0].is_dir) or glob.hasWildcard(srcs.items[0]);

        const chmod_key = if (c.chmod) |m| try std.fmt.allocPrint(self.a, "{o}", .{m}) else "-";
        const norm = try std.fmt.allocPrint(self.a, "COPY {d}:{d} {s} {s} {s}", .{ owner.uid, owner.gid, chmod_key, dest, if (into_dir) "dir" else "file" });
        const key = cache_key.compute(.{
            .parent_root = self.root,
            .instruction = norm,
            .inputs_digest = try copy_sources.digest(self.a, sources, self.ignore),
        });
        if (self.cacheHit(key)) return true;

        var w = try dir_walk.Walker.init(self.a, self.opts.voila_root, .{ .mode = .copy, .owner = owner, .chmod = c.chmod });
        defer w.deinit();
        const dest_rel = std.mem.trimStart(u8, dest, "/");
        for (sources) |s| {
            var ig: copy_sources.IgnoreSkip = .{ .ignore = self.ignore, .prefix = s.rel };
            w.opts.skip = ig.skip();
            const target = if (s.is_dir or !into_dir) dest_rel else try steps.joinRel(self.a, dest_rel, std.fs.path.basename(s.rel));
            try w.add(s.abs, target);
        }
        try self.commit(key, (try w.finish()).tree);
        return false;
    }

    fn currentTree(self: *Builder) !*tree_mod.LayerTree {
        if (self.tree) |t| return t;
        const t = try from_manifest.loadTree(self.a, self.opts.voila_root, self.root, voila_registry_fetch.fetcher(self.io));
        self.tree = t;
        return t;
    }

    fn readImageFile(self: *Builder, path: []const u8) ![]const u8 {
        const tree = try self.currentTree();
        var cur = path;
        for (0..8) |_| {
            const node = tree.lookup(cur) orelse return "";
            switch (node.node_type) {
                .regular => {
                    var out: std.ArrayList(u8) = .empty;
                    for (node.blocks.items) |blk| {
                        const hex = chunk_store.idToHex(blk.chunk_id);
                        const algo = voila_chunk_index.compAlgoForChunk(self.opts.voila_root, &blk.chunk_id) catch voila_store.AlgoRaw;
                        const data = voila_chunk_load.loadChunkRaw(voila_registry_fetch.fetcher(self.io), self.a, self.opts.voila_root, &hex, algo) catch return error.ImageFileUnreadable;
                        try out.appendSlice(self.a, data);
                    }
                    return out.items;
                },
                .symlink => {
                    const dir = try std.fmt.allocPrint(self.a, "/{s}", .{std.fs.path.dirname(cur) orelse ""});
                    cur = (try steps.joinPath(self.a, dir, node.target))[1..];
                },
                else => return "",
            }
        }
        return "";
    }

    fn resolveOwner(self: *Builder, spec: []const u8) !dir_walk.Owner {
        if (steps.parseChown(spec)) |o| return o else |_| {}
        const ids = passwd.resolveChown(spec, try self.readImageFile("etc/passwd"), try self.readImageFile("etc/group")) catch return error.UnknownChownName;
        return .{ .uid = ids.uid, .gid = ids.gid };
    }

    fn copyFrom(self: *Builder, c: dockerfile.Copy) !bool {
        var srcs: std.ArrayList([]const u8) = .empty;
        for (c.srcs) |s| try srcs.append(self.a, try self.expand(s));
        const dest_raw = try self.expand(c.dest);
        const chown = try self.expand(c.chown);
        const owner = if (chown.len > 0) try self.resolveOwner(chown) else dir_walk.Owner{ .uid = 0, .gid = 0 };
        const dest = try steps.joinPath(self.a, try self.config.getString("WorkingDir"), dest_raw);
        const src_root, const src_tree = switch (try build_stages.resolve(self.session.df, self.index, try self.expand(c.from), true)) {
            .stage => |i| blk: {
                const r = try self.session.built(i);
                break :blk .{ r.root, r.tree };
            },
            .image => |ref| .{ (try image_store.loadBase(self.io, self.a, self.opts.voila_root, ref)).root, null },
        };

        var h: cache_key.InputsHasher = .{};
        h.entry("from", 0, &src_root);
        for (srcs.items) |s| h.entry(s, 0, "");
        const norm = try std.fmt.allocPrint(self.a, "COPY --from {s} {s} {s}", .{ chown, dest, dest_raw });
        const key = cache_key.compute(.{ .parent_root = self.root, .instruction = norm, .inputs_digest = h.final() });
        if (self.cacheHit(key)) return true;

        const tree = src_tree orelse try from_manifest.loadTree(self.a, self.opts.voila_root, src_root, voila_registry_fetch.fetcher(self.io));
        const matches = try copy_from.resolve(self.a, tree, srcs.items);
        const into_dir = std.mem.endsWith(u8, dest_raw, "/") or matches.len > 1 or
            (matches.len == 1 and matches[0].node.node_type == .dir) or glob.hasWildcard(srcs.items[0]);
        const diff = try copy_from.graft(self.a, matches, std.mem.trimStart(u8, dest, "/"), into_dir, if (chown.len > 0) owner else null);
        try self.commit(key, diff);
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
        const current = self.tree orelse try from_manifest.loadTree(self.a, self.opts.voila_root, self.root, voila_registry_fetch.fetcher(self.io));
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
