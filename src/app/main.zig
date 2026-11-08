const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const cli = @import("cli");
const trace = @import("sys").trace;

pub const std_options_debug_io = zio.debug_io;

pub fn main(init: std.process.Init) !void {
    const gpa = if (builtin.mode == .debug) init.gpa else std.heap.smp_allocator;
    const zio_rt = try zio.Runtime.init(gpa, .{});
    defer zio_rt.deinit();
    const io = zio_rt.io();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const sub_name = args.next() orelse {
        cli.usage.printUsage();
        std.process.exit(2);
    };

    if (isVersion(sub_name)) {
        cli.version.print();
        return;
    }
    if (isHelp(sub_name)) {
        cli.usage.printUsage();
        return;
    }

    const sub = cli.commands.parse(sub_name) orelse {
        std.debug.print("voila: unknown command {s}\n", .{sub_name});
        cli.usage.printUsage();
        std.process.exit(2);
    };

    if (restWantsHelp(init, sub)) {
        cli.usage.printCommand(sub);
        return;
    }

    var name_buf: [64]u8 = undefined;
    trace.init(std.fmt.bufPrint(&name_buf, "voila {s}", .{sub_name}) catch "voila");

    const ctx = cli.command.Ctx{ .io = io, .init = init, .args = &args, .allocator = gpa };
    cli.dispatch.run(sub, ctx) catch |e| {
        cli.user_error.print(e);
        std.process.exit(cli.user_error.exitStatus(e));
    };
}

fn isVersion(s: []const u8) bool {
    return std.mem.eql(u8, s, "--version") or std.mem.eql(u8, s, "-v") or std.mem.eql(u8, s, "version");
}

fn isHelp(s: []const u8) bool {
    return std.mem.eql(u8, s, "--help") or std.mem.eql(u8, s, "-h") or std.mem.eql(u8, s, "help");
}

fn restWantsHelp(init: std.process.Init, sub: cli.commands.Name) bool {
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    _ = it.next();
    return wantsHelp(sub, &it);
}

/// `--help` before the first operand. `-h` too, except for `run`, where it is `--hostname` (as in Docker).
fn wantsHelp(sub: cli.commands.Name, it: anytype) bool {
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--help")) return true;
        if (std.mem.eql(u8, a, "-h") and sub != .run) return true;
        if (std.mem.eql(u8, a, "--") or (a.len > 0 and a[0] != '-')) return false;
        if (flagTakesValue(sub, a)) _ = it.next();
    }
    return false;
}

fn flagTakesValue(sub: cli.commands.Name, a: []const u8) bool {
    if (eqlAny(a, &.{ "-root", "--root", "-backend", "--backend" })) return true;
    return switch (sub) {
        .run => eqlAny(a, &.{
            "--name",     "-e", "--env",  "-v",           "--volume", "-p",         "--publish", "-w",    "--workdir",
            "--env-file", "-u", "--user", "--entrypoint", "-h",       "--hostname", "--network", "--net",
        }),
        .build => eqlAny(a, &.{ "-t", "--tag", "-f", "--file", "--target", "--build-arg" }),
        .kill => eqlAny(a, &.{ "-s", "--signal" }),
        .container_worker => eqlAny(a, &.{ "-id", "--ready-fd" }),
        else => false,
    };
}

fn eqlAny(a: []const u8, names: []const []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, a, n)) return true;
    }
    return false;
}

const SliceIter = struct {
    items: []const []const u8,
    i: usize = 0,
    fn next(self: *SliceIter) ?[]const u8 {
        if (self.i == self.items.len) return null;
        defer self.i += 1;
        return self.items[self.i];
    }
};

fn helpFor(sub: cli.commands.Name, args: []const []const u8) bool {
    var it: SliceIter = .{ .items = args };
    return wantsHelp(sub, &it);
}

test "run -h is the hostname, not help" {
    try std.testing.expect(!helpFor(.run, &.{ "-h", "box1", "alpine", "hostname" }));
    try std.testing.expect(!helpFor(.run, &.{ "--rm", "-h", "--help", "alpine" }));
    try std.testing.expect(helpFor(.run, &.{ "--rm", "--help" }));
    try std.testing.expect(!helpFor(.run, &.{ "alpine", "--help" }));
    try std.testing.expect(!helpFor(.run, &.{ "--entrypoint", "--help", "alpine" }));
    try std.testing.expect(helpFor(.build, &.{"-h"}));
}
