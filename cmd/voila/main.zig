//! Thin executable root for the voila CLI.
const std = @import("std");
const app = @import("app");

pub fn main(init: std.process.Init) !void {
    try app.main(init);
}
