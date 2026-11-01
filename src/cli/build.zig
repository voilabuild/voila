//! `voila build`: argument parsing, progress output and error reporting.
const std = @import("std");
const command = @import("command.zig");
const posix_util = @import("sys").posix_util;
const voila_paths = @import("sys").voila_paths;
const dockerfile = @import("core").dockerfile;
const driver = @import("runtime").build.driver;
const run_step = @import("runtime").build.run_step;
const userns_ids = @import("runtime").oci.userns_ids;
const registry_session = @import("registry").registry_session;
const voila_registry = @import("registry").voila_registry;
const voila_image_push = @import("registry").voila_image_push;
const registry_ref = @import("registry").voila_registry_ref;

const Args = struct {
    root: []const u8,
    tag: []const u8,
    file: ?[]const u8 = null,
    target: []const u8 = "",
    context: []const u8,
    build_args: []const dockerfile.KeyValue,
    no_cache: bool = false,
    push: bool = false,
};

pub const Error = error{ BadBuildArgs, NeedTag, NeedContext };

fn parseArgs(a: std.mem.Allocator, it: *std.process.Args.Iterator) !Args {
    var root: ?[]const u8 = null;
    var tag: ?[]const u8 = null;
    var file: ?[]const u8 = null;
    var target: []const u8 = "";
    var context: ?[]const u8 = null;
    var no_cache = false;
    var push = false;
    var build_args: std.ArrayList(dockerfile.KeyValue) = .empty;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-root") or std.mem.eql(u8, arg, "--root")) {
            root = it.next() orelse return error.BadBuildArgs;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--tag")) {
            tag = it.next() orelse return error.BadBuildArgs;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
            file = it.next() orelse return error.BadBuildArgs;
        } else if (std.mem.eql(u8, arg, "--target")) {
            target = it.next() orelse return error.BadBuildArgs;
        } else if (std.mem.eql(u8, arg, "--build-arg")) {
            const kv = it.next() orelse return error.BadBuildArgs;
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return error.BadBuildArgs;
            try build_args.append(a, .{ .key = kv[0..eq], .value = kv[eq + 1 ..] });
        } else if (std.mem.eql(u8, arg, "--no-cache")) {
            no_cache = true;
        } else if (std.mem.eql(u8, arg, "--push")) {
            push = true;
        } else if (context == null and (arg.len == 0 or arg[0] != '-')) {
            context = arg;
        } else return error.BadBuildArgs;
    }
    return .{
        .root = if (root) |r| try absPath(a, r) else try voila_paths.defaultVoilaRoot(a),
        .tag = tag orelse return error.NeedTag,
        .file = file,
        .target = target,
        .context = try absPath(a, context orelse return error.NeedContext),
        .build_args = try build_args.toOwnedSlice(a),
        .no_cache = no_cache,
        .push = push,
    };
}

pub fn execute(ctx: command.Ctx) !void {
    std.process.exit(try run(ctx.io, ctx.gpa(), ctx.args));
}

pub fn run(io: std.Io, gpa: std.mem.Allocator, it: *std.process.Args.Iterator) !u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const args = parseArgs(a, it) catch |e| {
        std.debug.print("usage: voila build -t <ref> [-f Dockerfile] [--target stage] [--build-arg K=V]... [--no-cache] [--push] [-root dir] <context>\n", .{});
        return e;
    };
    const df_path = args.file orelse try std.fmt.allocPrint(a, "{s}/Dockerfile", .{args.context});
    const text = posix_util.readFileAlloc(a, df_path, 1 << 20) catch |e| {
        std.debug.print("voila build: cannot read {s}: {s}\n", .{ df_path, @errorName(e) });
        return 1;
    };
    registry_session.prepare(io, gpa, args.root) catch {}; // registry is optional for a local build

    warnUidmap(a);
    var ns_runner: run_step.NamespaceRunner = .{ .allocator = gpa, .ids = userns_ids.detect(a, .{}) };
    var runner: WarnOnce = .{ .inner = ns_runner.runner() };
    var printer: Printer = .{};
    var diag: driver.Diagnostic = .{};
    const t0 = monotonic();
    const res = driver.build(io, gpa, .{
        .voila_root = args.root,
        .context_dir = args.context,
        .dockerfile_text = text,
        .tag = args.tag,
        .target = args.target,
        .build_args = args.build_args,
        .no_cache = args.no_cache,
        .runner = runner.runner(),
        .progress = printer.progress(),
    }, &diag) catch |e| {
        reportError(df_path, e, diag);
        return 1;
    };
    const ref = try registry_ref.normalizeUserRef(a, args.tag);
    std.debug.print("built {s} in {d:.2}s ({d}/{d} steps cached)\n", .{
        ref, secs(monotonic() - t0), res.cached, res.steps,
    });
    if (args.push) {
        const cfg = voila_registry.getConfigCopy(a) orelse {
            std.debug.print("voila build: --push needs a registry (run `voila login`)\n", .{});
            return 1;
        };
        try voila_image_push.pushImage(io, a, args.root, cfg, ref);
    }
    return 0;
}

fn reportError(df_path: []const u8, e: anyerror, diag: driver.Diagnostic) void {
    const what: []const u8 = switch (e) {
        error.RunFailed => "RUN command failed",
        error.ReleaseFailed => "RUN finished but its new files could not be handed back to the build user (see the RUN: line above)",
        error.OverlayUpperUnsupported => "could not set up the RUN sandbox: the store is on overlayfs and a private tmpfs for the writable layer could not be mounted",
        error.OverlayFailed, error.UserNamespacesRequired => "could not set up the RUN sandbox (needs unprivileged user namespaces and overlayfs; re-run install.sh for the AppArmor profile)",
        error.UnknownUser => "USER names a user missing from the image's /etc/passwd",
        error.UnknownGroup => "USER names a group missing from the image's /etc/group",
        error.UserSwitchFailed => "could not switch to the USER for RUN",
        error.MountFailed => "could not FUSE-mount the image for RUN (is /dev/fuse available?)",
        error.BaseImageNotFound => "base image not found locally or on the registry (try `voila import <ref>` first)",
        error.CopySourceMissing => "COPY source not found in the build context",
        error.CopyEscapesContext => "COPY source is outside the build context",
        error.UnsupportedWildcard => "COPY wildcards are only supported in the last path segment",
        error.UnsupportedChown => "invalid --chown",
        error.UnknownChownName => "COPY --chown names a user or group missing from the image's /etc/passwd or /etc/group",
        error.ImageFileUnreadable => "could not read /etc/passwd or /etc/group from the image (chunk missing locally and not fetchable)",
        error.BadValue => "invalid flag value or argument",
        error.DuplicateStage => "duplicate stage name",
        error.UnknownTarget => "--target names no stage of the Dockerfile",
        error.StageNotFound => "COPY --from index must name an earlier stage",
        error.Unsupported => "instruction or flag not supported yet",
        error.UnknownInstruction => "unknown instruction",
        error.MissingFrom => "the Dockerfile must start with FROM",
        else => @errorName(e),
    };
    if (diag.line == 0) {
        std.debug.print("voila build: {s}\n", .{what});
    } else if (e == error.RunFailed) {
        std.debug.print("{s}:{d}: {s} (exit status {d})\n", .{ df_path, diag.line, what, diag.exit_code });
    } else {
        std.debug.print("{s}:{d}: {s}\n", .{ df_path, diag.line, what });
    }
}

fn warnUidmap(a: std.mem.Allocator) void {
    switch (userns_ids.detectFallback(a, .{})) {
        .range => {},
        .missing_helper => std.debug.print(
            "voila: uidmap is not installed; apt-get, useradd and chown to other users will fail. Install it with `sudo apt install uidmap`.\n",
            .{},
        ),
        .missing_subid => std.debug.print(
            "voila: no /etc/subuid range for this user; RUN is a single-uid namespace. apt-get and useradd will fail on files owned by other uids.\n",
            .{},
        ),
    }
}

/// Prints one warning per build when `USER` could not be applied to a RUN step.
const WarnOnce = struct {
    inner: driver.StepRunner,
    warned: bool = false,

    fn runner(self: *WarnOnce) driver.StepRunner {
        return .{ .ptr = self, .runFn = runStep };
    }

    fn runStep(ptr: *anyopaque, io: std.Io, req: driver.RunRequest) driver.steps.RunnerError!driver.steps.RunResult {
        const self: *WarnOnce = @ptrCast(@alignCast(ptr));
        const res = try self.inner.run(io, req);
        if (res.user_not_applied and !self.warned) {
            self.warned = true;
            std.debug.print("warning: USER {s} is not applied to RUN: install uidmap (newuidmap/newgidmap) to run as non-root\n", .{req.user});
        }
        return res;
    }
};

const Printer = struct {
    fn progress(self: *Printer) driver.Progress {
        return .{ .ptr = self, .func = onStep };
    }

    fn onStep(_: *anyopaque, ev: driver.StepEvent) void {
        const state = if (ev.cached) "CACHED" else "";
        const shown = if (ev.text.len > 72) ev.text[0..72] else ev.text;
        const ell = if (ev.text.len > 72) "..." else "";
        const sep = if (ev.stage.len > 0) " " else "";
        if (ev.index == 0) {
            std.debug.print("[{s}{s}{d}/{d}] {s}\n", .{ ev.stage, sep, ev.index + 1, ev.total, shown });
        } else {
            std.debug.print("[{s}{s}{d}/{d}] {s}{s} {s} {d:.2}s\n", .{ ev.stage, sep, ev.index + 1, ev.total, shown, ell, state, secs(ev.elapsed_ns) });
        }
    }
};

fn monotonic() u64 {
    return @import("sys").clock.monotonicNs();
}

fn secs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
}

fn absPath(a: std.mem.Allocator, p: []const u8) ![]const u8 {
    if (p.len > 0 and p[0] == '/') return std.mem.trimEnd(u8, p, "/");
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&buf, buf.len);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.BadBuildArgs;
    const cwd = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&buf)), 0);
    if (std.mem.eql(u8, p, ".")) return a.dupe(u8, cwd);
    return std.fmt.allocPrint(a, "{s}/{s}", .{ cwd, std.mem.trimEnd(u8, p, "/") });
}
