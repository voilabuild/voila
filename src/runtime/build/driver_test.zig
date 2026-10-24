const std = @import("std");
const fs = @import("../../sys/fs.zig");
const driver = @import("driver.zig");
const image_store = @import("image_store.zig");
const dir_walk = @import("../../store/ingest/ingest_dir_walk.zig");
const from_manifest = @import("../../store/ingest/ingest_from_manifest.zig");
const manifest_mod = @import("../../store/ingest/ingest_manifest.zig");
const chunk_store = @import("../../store/ingest/ingest_chunk_store.zig");
const tree_mod = @import("../../store/ingest/ingest_tree.zig");
const voila_resolve = @import("../voila_resolve.zig");
const run_config = @import("../oci/voila_image_run_config.zig");

/// Interprets `write <path> <content>` and `fail` instead of running a shell.
const FakeRunner = struct {
    calls: usize = 0,
    last_env: []const []const u8 = &.{},
    last_workdir: []const u8 = "",
    arena: std.mem.Allocator,

    fn runner(self: *FakeRunner) driver.StepRunner {
        return .{ .ptr = self, .runFn = run };
    }

    fn run(ptr: *anyopaque, _: std.Io, req: driver.RunRequest) driver.steps.RunnerError!driver.steps.RunResult {
        const self: *FakeRunner = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        var env: std.ArrayList([]const u8) = .empty;
        for (req.env) |e| env.append(self.arena, self.arena.dupe(u8, e) catch return error.OutOfMemory) catch return error.OutOfMemory;
        self.last_env = env.items;
        self.last_workdir = self.arena.dupe(u8, req.workdir) catch return error.OutOfMemory;
        const cmd = req.argv[req.argv.len - 1];
        if (std.mem.eql(u8, cmd, "fail")) return .{ .code = 1 };
        var it = std.mem.tokenizeScalar(u8, cmd, ' ');
        _ = it.next();
        const path = it.next() orelse return .{ .code = 2 };
        const body = it.rest();
        const abs = std.fmt.allocPrint(self.arena, "{s}{s}", .{ req.upper_dir, path }) catch return error.OutOfMemory;
        fs.makePath(std.fs.path.dirname(abs).?) catch return error.SpawnFailed;
        fs.writeFile(abs, body, 0o644) catch return error.SpawnFailed;
        return .{ .code = 0 };
    }
};

const Env = struct {
    arena: std.heap.ArenaAllocator,
    tmp: []u8,
    root: []const u8,
    ctx: []const u8,

    fn init() !Env {
        const gpa = std.testing.allocator;
        var e: Env = .{ .arena = .init(gpa), .tmp = try fs.makeTempDir(gpa, "voila-build-test"), .root = "", .ctx = "" };
        const a = e.arena.allocator();
        e.root = try std.fmt.allocPrint(a, "{s}/root", .{e.tmp});
        e.ctx = try std.fmt.allocPrint(a, "{s}/ctx", .{e.tmp});
        try fs.makePath(e.root);
        try fs.makePath(e.ctx);
        return e;
    }

    fn deinit(self: *Env) void {
        fs.removeTree(std.testing.allocator, self.tmp) catch {};
        std.testing.allocator.free(self.tmp);
        self.arena.deinit();
    }

    fn file(self: *Env, rel: []const u8, body: []const u8) !void {
        const p = try std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ self.ctx, rel });
        try fs.makePath(std.fs.path.dirname(p).?);
        try fs.writeFile(p, body, 0o644);
    }

    /// Ingests `ctx/base` as image `ref` with the given config JSON.
    fn baseImage(self: *Env, ref: []const u8, config_json: []const u8) !void {
        const a = self.arena.allocator();
        var w = try dir_walk.Walker.init(a, self.root, .{ .mode = .copy });
        defer w.deinit();
        try w.add(try std.fmt.allocPrint(a, "{s}/base", .{self.ctx}), "");
        const tree = w.finish().tree;
        try image_store.persist(a, self.root, ref, .{
            .root = try manifest_mod.buildAndStoreManifest(a, self.root, tree, false),
            .config = try chunk_store.putBytes(a, self.root, config_json),
            .layers = &.{},
            .tree = tree,
        });
    }

    fn build(self: *Env, runner: *FakeRunner, text: []const u8, diag: *driver.Diagnostic) !driver.Result {
        return driver.build(std.testing.io, std.testing.allocator, .{
            .voila_root = self.root,
            .context_dir = self.ctx,
            .dockerfile_text = text,
            .tag = "test/app:1",
            .build_args = &.{},
            .runner = runner.runner(),
        }, diag);
    }

    fn imageTree(self: *Env, root: [32]u8) !*tree_mod.LayerTree {
        return from_manifest.loadTree(self.arena.allocator(), self.root, root);
    }
};

const dockerfile_text =
    \\ARG GREETING=hi
    \\FROM test/base:1
    \\ARG GREETING
    \\ENV NAME=voila
    \\WORKDIR /app
    \\COPY hello.txt ./
    \\COPY src/ /app/src/
    \\RUN write /app/out.txt $NAME
    \\ENTRYPOINT ["/bin/sh"]
    \\CMD ["-c", "cat out.txt"]
;

fn hasEnv(env: []const []const u8, kv: []const u8) bool {
    for (env) |e| if (std.mem.eql(u8, e, kv)) return true;
    return false;
}

test "build applies COPY/RUN/metadata, caches, and invalidates on context change" {
    var env = try Env.init();
    defer env.deinit();
    try env.file("base/etc/os-release", "ID=test\n");
    try env.file("hello.txt", "hello\n");
    try env.file("src/a.txt", "a\n");
    try env.file("src/secret.txt", "s\n");
    try env.file(".dockerignore", "src/secret.txt\n");
    try env.baseImage("test/base:1", "{\"os\":\"linux\",\"config\":{\"Env\":[\"PATH=/bin\"],\"Cmd\":[\"sh\"]}}");

    var runner: FakeRunner = .{ .arena = env.arena.allocator() };
    var diag: driver.Diagnostic = .{};
    const first = try env.build(&runner, dockerfile_text, &diag);
    try std.testing.expectEqual(@as(usize, 1), runner.calls);
    try std.testing.expectEqual(@as(usize, 0), first.cached);
    try std.testing.expectEqualStrings("/app", runner.last_workdir);
    try std.testing.expect(hasEnv(runner.last_env, "NAME=voila"));
    try std.testing.expect(hasEnv(runner.last_env, "GREETING=hi"));
    try std.testing.expect(hasEnv(runner.last_env, "PATH=/bin"));

    const t = try env.imageTree(first.root);
    try std.testing.expect(t.lookup("etc/os-release") != null);
    try std.testing.expect(t.lookup("app/hello.txt") != null);
    try std.testing.expect(t.lookup("app/src/a.txt") != null);
    try std.testing.expect(t.lookup("app/src/secret.txt") == null);
    try std.testing.expectEqual(@as(u64, 5), t.lookup("app/out.txt").?.size);

    const cfg = try run_config.loadConfigJson(std.testing.io, env.arena.allocator(), env.root, "test/app:1");
    try std.testing.expect(std.mem.indexOf(u8, cfg, "\"Entrypoint\":[\"/bin/sh\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "\"Cmd\":[\"-c\",\"cat out.txt\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "\"NAME=voila\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "\"WorkingDir\":\"/app\"") != null);

    const again = try env.build(&runner, dockerfile_text, &diag);
    try std.testing.expectEqual(@as(usize, 1), runner.calls);
    try std.testing.expectEqual(@as(usize, 3), again.cached);
    try std.testing.expectEqualSlices(u8, &first.root, &again.root);
    try std.testing.expectEqualSlices(u8, &first.config, &again.config);

    try env.file("src/secret.txt", "changed but ignored\n");
    const ignored = try env.build(&runner, dockerfile_text, &diag);
    try std.testing.expectEqual(@as(usize, 3), ignored.cached);

    try env.file("hello.txt", "bonjour\n");
    const changed = try env.build(&runner, dockerfile_text, &diag);
    try std.testing.expectEqual(@as(usize, 2), runner.calls);
    try std.testing.expectEqual(@as(usize, 0), changed.cached);
    try std.testing.expect(!std.mem.eql(u8, &first.root, &changed.root));
}

test "failing RUN reports the exit code and does not tag the image" {
    var env = try Env.init();
    defer env.deinit();
    try env.file("base/bin/sh", "#!fake\n");
    try env.baseImage("test/base:1", "");
    var runner: FakeRunner = .{ .arena = env.arena.allocator() };
    var diag: driver.Diagnostic = .{};
    try std.testing.expectError(error.RunFailed, env.build(&runner, "FROM test/base:1\nRUN write /x 1\nRUN fail\n", &diag));
    try std.testing.expectEqual(@as(usize, 3), diag.line);
    try std.testing.expectEqual(@as(u8, 1), diag.exit_code);
    try std.testing.expectError(error.NoImageMatch, voila_resolve.resolveImage(env.arena.allocator(), env.root, "test/app:1"));

    // The successful first RUN is cached even though the build failed.
    try std.testing.expectError(error.RunFailed, env.build(&runner, "FROM test/base:1\nRUN write /x 1\nRUN fail\n", &diag));
    try std.testing.expectEqual(@as(usize, 3), runner.calls);
}

test "missing base image and bad COPY source are reported" {
    var env = try Env.init();
    defer env.deinit();
    var runner: FakeRunner = .{ .arena = env.arena.allocator() };
    var diag: driver.Diagnostic = .{};
    try std.testing.expectError(error.BaseImageNotFound, env.build(&runner, "FROM nope/missing:1\n", &diag));
    try std.testing.expectEqual(@as(usize, 1), diag.line);

    try std.testing.expectError(error.CopyEscapesContext, env.build(&runner, "FROM scratch\nCOPY ../etc/passwd /\n", &diag));
    try std.testing.expectEqual(@as(usize, 2), diag.line);
    try std.testing.expectError(error.CopySourceMissing, env.build(&runner, "FROM scratch\nCOPY nothere /\n", &diag));
}

test "FROM scratch with COPY of a single file to a file path" {
    var env = try Env.init();
    defer env.deinit();
    try env.file("bin/tool", "#!/bin/sh\n");
    var runner: FakeRunner = .{ .arena = env.arena.allocator() };
    var diag: driver.Diagnostic = .{};
    const res = try env.build(&runner, "FROM scratch\nCOPY --chown=10:20 bin/tool /usr/local/bin/t\nCOPY bin/* /opt/\n", &diag);
    const t = try env.imageTree(res.root);
    const n = t.lookup("usr/local/bin/t").?;
    try std.testing.expectEqual(@as(u32, 10), n.uid);
    try std.testing.expectEqual(@as(u32, 20), n.gid);
    try std.testing.expect(t.lookup("opt/tool") != null);
}
