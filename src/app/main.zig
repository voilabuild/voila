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

    const sub = cli.commands.parse(sub_name) orelse {
        cli.usage.printUsage();
        return;
    };

    const ctx = cli.command.Ctx{ .io = io, .init = init, .args = &args, .allocator = gpa };
    try cli.dispatch.run(sub, ctx);
}
