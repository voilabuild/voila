#!/usr/bin/env python3
"""Generate src/cli from src/app/main.zig (pre-split). Run once on issue-87 branch."""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "src/cli"
ORIG = (ROOT / "src/app/main.zig").read_text()


def w(name: str, text: str) -> None:
    (CLI / name).write_text(text)


FLAGS = r'''//! Shared CLI flags (`-root`, `-backend`) and path helpers.

const std = @import("std");
const voila_runtime = @import("runtime").open;
const voila_paths = @import("sys").voila_paths;

pub fn parseBackendArg(arg: []const u8) ?voila_runtime.Kind {
    if (std.mem.eql(u8, arg, "local")) return .local;
    if (std.mem.eql(u8, arg, "remote")) return .remote;
    return null;
}

pub fn resolveStoreRoot(allocator: std.mem.Allocator, root: ?[]const u8) ![]const u8 {
    if (root) |r| return resolveAbs(allocator, r);
    return voila_paths.defaultVoilaRoot(allocator);
}

pub fn resolveAbs(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (path.len > 0 and path[0] == '/') return allocator.dupe(u8, path);
    var cwd: [4096]u8 = undefined;
    const cwd_rc = std.os.linux.getcwd(cwd[0..].ptr, cwd.len);
    const cwd_err = std.posix.errno(cwd_rc);
    if (cwd_err != .SUCCESS) return allocator.dupe(u8, path);
    const cwd_slice = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(cwd[0..].ptr)), 0);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd_slice, path });
}

pub fn tryRuntimeFlag(
    allocator: std.mem.Allocator,
    arg: []const u8,
    args: *std.process.Args.Iterator,
    root: *?[]const u8,
    kind: *voila_runtime.Kind,
) !bool {
    if (std.mem.eql(u8, arg, "-root")) {
        const r = args.next() orelse return error.NeedVoilaRoot;
        if (root.*) |owned| allocator.free(owned);
        root.* = try allocator.dupe(u8, r);
        return true;
    }
    if (std.mem.eql(u8, arg, "-backend")) {
        const b = args.next() orelse return error.BadRunArgs;
        kind.* = parseBackendArg(b) orelse return error.BadRunArgs;
        return true;
    }
    return false;
}

pub fn finishRuntimeConfig(
    allocator: std.mem.Allocator,
    root: ?[]const u8,
    kind: voila_runtime.Kind,
) !voila_runtime.Config {
    const root_abs = try resolveStoreRoot(allocator, root);
    if (root) |owned| allocator.free(owned);
    return .{ .kind = kind, .store_root = root_abs };
}
'''


def extract(struct: str, fn: str) -> str:
    pat = rf"const {struct} = struct.*?^}};\n\nfn {fn}\(.*?\n}}\n"
    m = re.search(pat, ORIG, re.M | re.S)
    if not m:
        raise SystemExit(f"missing {fn}")
    return m.group(0)


def migrate_parsers(block: str, fn_name: str) -> str:
    block = block.replace(f"fn {fn_name}", "pub fn parseArgs")
    for old in (
        "PullParsed",
        "RunParsed",
        "ExecParsed",
        "RmiParsed",
        "LogsParsed",
        "ContextParsed",
    ):
        block = block.replace(f"const {old}", "pub const Parsed")
        block = block.replace(f"self: {old}", "self: Parsed")
    block = block.replace("const KillParsed", "pub const KillParsed")
    block = block.replace("self: KillParsed", "self: KillParsed")
    block = block.replace("fn parseKillArgs", "pub fn parseKillArgs")
    block = re.sub(
        r"        if \(std\.mem\.eql\(u8, arg, \"-root\"\)\) \{\n"
        r"            const r = args\.next\(\) orelse return error\.NeedVoilaRoot;\n"
        r"            root = try allocator\.dupe\(u8, r\);\n"
        r"            continue;\n"
        r"        \}\n"
        r"        if \(std\.mem\.eql\(u8, arg, \"-backend\"\)\) \{\n"
        r"            const b = args\.next\(\) orelse return error\.BadRunArgs;\n"
        r"            kind = parseBackendArg\(b\) orelse return error\.BadRunArgs;\n"
        r"            continue;\n"
        r"        \}",
        "        if (try flags.tryRuntimeFlag(allocator, arg, args, &root, &kind)) continue;",
        block,
    )
    block = re.sub(
        r"        if \(std\.mem\.eql\(u8, arg, \"-root\"\)\) \{\n"
        r"            const r = args\.next\(\) orelse return error\.NeedVoilaRoot;\n"
        r"            root = try allocator\.dupe\(u8, r\);\n"
        r"        \} else if \(std\.mem\.eql\(u8, arg, \"-backend\"\)\) \{\n"
        r"            const b = args\.next\(\) orelse return error\.BadRunArgs;\n"
        r"            kind = parseBackendArg\(b\) orelse return error\.BadRunArgs;\n"
        r"        \} else",
        "        if (try flags.tryRuntimeFlag(allocator, arg, args, &root, &kind)) continue;\n        else",
        block,
    )
    block = block.replace("resolveStoreRoot(", "flags.resolveStoreRoot(")
    block = block.replace("resolveAbs(", "flags.resolveAbs(")
    block = block.replace("parseBackendArg(", "flags.parseBackendArg(")
    block = re.sub(
        r"    const root_abs = try flags\.resolveStoreRoot\(allocator, root\);\n"
        r"    if \(root\) \|owned\) allocator\.free\(owned\);\n"
        r"    return \.\{\n"
        r"        \.runtime_cfg = \. \{ \.kind = kind, \.store_root = root_abs \},",
        "    return .{\n        .runtime_cfg = try flags.finishRuntimeConfig(allocator, root, kind),",
        block,
    )
    block = block.replace("fn deinit", "pub fn deinit")
    return block


def main() -> None:
    CLI.mkdir(exist_ok=True)
    w("flags.zig", FLAGS)

    prove_body = ORIG[ORIG.index("fn rootMountProve(") : ORIG.index("fn openRuntime(")]
    prove_body = prove_body.replace("resolveAbs(", "flags.resolveAbs(")
    run_store = ORIG[ORIG.index("fn proveStore(") : ORIG.index("fn proveStoreDistroExtras")]
    run_store = run_store.replace("fn proveStore", "pub fn runStore").replace(
        "resolveAbs(", "flags.resolveAbs("
    )
    prove_hdr = """const std = @import("std");
const flags = @import("flags.zig");
const vfs_mod = @import("mount").fuse.vfs;
const fuse_vfs_mod = @import("mount").fuse.fuse_vfs;
const voila_vfs_mod = @import("mount").fuse.voila_vfs;
const fuse_linux = @import("mount").fuse.fuse_linux;
const posix_util = @import("sys").posix_util;
const constants = @import("core").constants;
const voila_loader = @import("runtime").voila_loader;

pub fn run(io: std.Io, init: std.process.Init, fixture_dir: []const u8) !void {
    try ensureFixture(init, fixture_dir);
    const fixture_abs = try flags.resolveAbs(init.gpa, fixture_dir);
    defer init.gpa.free(fixture_abs);
    var fixture_vfs = try vfs_mod.Vfs.load(init.gpa, fixture_abs);
    defer fixture_vfs.deinit();
    var fuse_vfs: fuse_vfs_mod.FuseVfs = .{ .fixture = fixture_vfs };
    if (!fuse_linux.canUseFuse()) {
        std.debug.print("skip: need root and /dev/fuse (read walker unit tests: zig build test)\\n", .{});
        return;
    }
    try rootMountProve(io, init, &fuse_vfs);
}

"""
    w("prove.zig", prove_hdr + run_store + "\n" + prove_body)

    login = ORIG[ORIG.index("fn cmdLogin(") : ORIG.index("fn rootMountProve(")]
    login = login.replace("fn cmdLogin", "pub fn run")
    w(
        "login.zig",
        """const std = @import("std");
const voila_paths = @import("sys").voila_paths;
const voila_login_creds = @import("registry").voila_login_creds;

"""
        + login,
    )

    w(
        "usage.zig",
        """const std = @import("std");

pub fn printUsage() void {
    std.debug.print(
        \\\\voila — daemonless voila container CLI (Linux, rootless FUSE)
        \\\\
        \\\\  voila login [registry-url]
        \\\\  voila logout
        \\\\  voila pull|push|import [-root <dir>] <image-ref>
        \\\\  voila build -t <ref> [-f Dockerfile] [--build-arg K=V] [--no-cache] [--push] <context>
        \\\\  voila run [-root <dir>] [-d] [--name NAME] [--rm] <image-ref> -- <cmd> [args...]
        \\\\  voila exec <id> -- <cmd> [args...]
        \\\\  voila ps|logs|images|rmi|stop|kill|rm [-root <dir>] ...
        \\\\
        \\\\  voila prove [fixture-dir]
        \\\\
    ,
        .{},
    );
}
""",
    )

    w(
        "logout.zig",
        """const std = @import("std");
const voila_login_creds = @import("registry").voila_login_creds;

pub fn run(allocator: std.mem.Allocator) !void {
    try voila_login_creds.deleteLoginCreds(allocator);
    std.debug.print("logged out\\n", .{});
}
""",
    )

    w(
        "userns_probe.zig",
        """const container_bind = @import("runtime").oci.container_bind;

pub fn exitCode() u8 {
    return if (container_bind.probeUserNamespaces()) 0 else 1;
}
""",
    )

    names = [
        ("userns-probe", "userns_probe"),
        ("login", "login"),
        ("logout", "logout"),
        ("prove", "prove"),
        ("prove-store", "prove_store"),
        ("serve", "serve"),
        ("serve-index", "serve_index"),
        ("container-fuse-serve", "container_fuse_serve"),
        ("container-isolated-exec", "container_isolated_exec"),
        ("container-worker", "container_worker"),
        ("build", "build"),
        ("run", "run"),
        ("exec", "exec"),
        ("ps", "ps"),
        ("logs", "logs"),
        ("pull", "pull"),
        ("push", "push"),
        ("import", "import"),
        ("rmi", "rmi"),
        ("images", "images"),
        ("kill", "kill"),
        ("stop", "stop"),
        ("rm", "rm"),
        ("serve-store", "serve_store"),
    ]
    cmd = "const std = @import(\"std\");\n\npub const Name = enum {\n"
    for _cli, tag in names:
        cmd += f"    {tag},\n"
    cmd += "};\n\npub fn parse(name: []const u8) ?Name {\n"
    for cli_name, tag in names:
        cmd += f'    if (std.mem.eql(u8, name, "{cli_name}")) return .{tag};\n'
    cmd += "    return null;\n}\n"
    w("commands.zig", cmd)

    hdr_pull = "const std = @import(\"std\");\nconst flags = @import(\"flags.zig\");\nconst voila_runtime = @import(\"runtime\").open;\n\n"
    w("pull.zig", hdr_pull + migrate_parsers(extract("PullParsed", "parsePullArgs"), "parsePullArgs"))

    w(
        "runtime_only.zig",
        hdr_pull
        + """pub fn parseArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !voila_runtime.Config {
    var root: ?[]const u8 = null;
    var kind = voila_runtime.kindFromEnv();
    while (args.next()) |arg| {
        if (try flags.tryRuntimeFlag(allocator, arg, args, &root, &kind)) continue;
    }
    return flags.finishRuntimeConfig(allocator, root, kind);
}
""",
    )

    worker = extract("WorkerParsed", "parseWorkerArgs")
    worker = worker.replace("const WorkerParsed", "pub const Parsed").replace(
        "fn parseWorkerArgs", "pub fn parseArgs"
    )
    worker = worker.replace("resolveAbs(", "flags.resolveAbs(")
    w(
        "worker.zig",
        "const std = @import(\"std\");\nconst flags = @import(\"flags.zig\");\n\n" + worker,
    )

    hdr_run = (
        "const std = @import(\"std\");\nconst flags = @import(\"flags.zig\");\n"
        "const voila_refkey = @import(\"core\").voila_refkey;\n"
        "const voila_runtime = @import(\"runtime\").open;\n"
        "const run_flags = @import(\"runtime\").run_flags;\n\n"
    )
    run = hdr_run + migrate_parsers(extract("RunParsed", "parseRunArgs"), "parseRunArgs")
    run += ORIG[ORIG.index('test "run drops') :].replace("parseRunArgs", "parseArgs")
    w("run.zig", run)

    hdr_rt = "const std = @import(\"std\");\nconst flags = @import(\"flags.zig\");\nconst voila_runtime = @import(\"runtime\").open;\n\n"
    for file, struct, fn in [
        ("exec.zig", "ExecParsed", "parseExecArgs"),
        ("rmi.zig", "RmiParsed", "parseRmiArgs"),
        ("logs.zig", "LogsParsed", "parseLogsArgs"),
    ]:
        b = hdr_rt + migrate_parsers(extract(struct, fn), fn)
        b = re.sub(
            r"    const root_abs = try flags\.resolveStoreRoot\(allocator, root\);\n"
            r"    if \(root\) \|owned\) allocator\.free\(owned\);\n",
            "",
            b,
        )
        w(file, b)

    w(
        "context.zig",
        hdr_rt
        + """pub const Parsed = struct {
    runtime_cfg: voila_runtime.Config,
    ref: voila_runtime.ContextRef,

    pub fn deinit(self: Parsed, allocator: std.mem.Allocator) void {
        allocator.free(self.runtime_cfg.store_root);
        allocator.free(self.ref.context_id);
    }
};

pub fn parseArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !Parsed {
    var root: ?[]const u8 = null;
    var kind = voila_runtime.kindFromEnv();
    var context_id: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (try flags.tryRuntimeFlag(allocator, arg, args, &root, &kind)) continue;
        if (context_id == null) {
            context_id = try allocator.dupe(u8, arg);
        }
    }
    const cid = context_id orelse return error.NeedContextId;
    return .{
        .runtime_cfg = try flags.finishRuntimeConfig(allocator, root, kind),
        .ref = .{ .context_id = cid },
    };
}

pub const KillParsed = struct {
    runtime_cfg: voila_runtime.Config,
    opts: voila_runtime.KillSpec,

    pub fn deinit(self: KillParsed, allocator: std.mem.Allocator) void {
        allocator.free(self.runtime_cfg.store_root);
        allocator.free(self.opts.context_id);
    }
};

pub fn parseKillArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !KillParsed {
    var root: ?[]const u8 = null;
    var kind = voila_runtime.kindFromEnv();
    var context_id: ?[]const u8 = null;
    var signal: i32 = 0;
    while (args.next()) |arg| {
        if (try flags.tryRuntimeFlag(allocator, arg, args, &root, &kind)) continue;
        if (context_id == null) {
            context_id = try allocator.dupe(u8, arg);
        } else {
            signal = std.fmt.parseInt(i32, arg, 10) catch continue;
        }
    }
    const cid = context_id orelse return error.NeedContextId;
    return .{
        .runtime_cfg = try flags.finishRuntimeConfig(allocator, root, kind),
        .opts = .{ .context_id = cid, .signal = signal },
    };
}
""",
    )

    w(
        "root.zig",
        """//! The `cli` layer: argv parsing, subcommand names, and command entry points.

pub const commands = @import("commands.zig");
pub const context = @import("context.zig");
pub const exec = @import("exec.zig");
pub const flags = @import("flags.zig");
pub const login = @import("login.zig");
pub const logout = @import("logout.zig");
pub const logs = @import("logs.zig");
pub const prove = @import("prove.zig");
pub const pull = @import("pull.zig");
pub const rmi = @import("rmi.zig");
pub const run = @import("run.zig");
pub const runtime_only = @import("runtime_only.zig");
pub const usage = @import("usage.zig");
pub const userns_probe = @import("userns_probe.zig");
pub const worker = @import("worker.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
""",
    )

    print(f"generated {len(list(CLI.glob('*.zig')))} files in src/cli")


if __name__ == "__main__":
    main()
