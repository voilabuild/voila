//! Shared request/response types for the voila runtime interface.
const std = @import("std");

pub const RunSpec = struct {
    image: []const u8,
    argv: []const []const u8,
};

pub const PsRow = struct {
    id: []const u8,
    image: []const u8,
    status: []const u8,
    pid: i32,
};

pub const LogsOptions = struct {
    context_id: []const u8,
    follow: bool = false,
};

pub const KillSpec = struct {
    context_id: []const u8,
    signal: i32 = 0,
};
