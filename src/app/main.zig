const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const cli = @import("cli");

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

    if (restWantsHelp(init)) {
        cli.usage.printCommand(sub);
        return;
    }

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

fn restWantsHelp(init: std.process.Init) bool {
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    _ = it.next();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) return true;
        if (std.mem.eql(u8, a, "--") or (a.len > 0 and a[0] != '-')) return false;
        if (flagTakesValue(a)) _ = it.next();
    }
    return false;
}

fn flagTakesValue(a: []const u8) bool {
    const names = [_][]const u8{
        "-root",       "--root", "-backend", "--backend", "--name",     "-e",
        "--env",       "-v",     "--volume", "-p",        "--publish",  "-w",
        "--workdir",   "-t",     "--tag",    "-f",        "--file",     "--target",
        "--build-arg", "-s",     "--signal", "-id",       "--ready-fd",
    };
    for (names) |n| {
        if (std.mem.eql(u8, a, n)) return true;
    }
    return false;
}
