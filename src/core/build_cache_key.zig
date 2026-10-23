//! Content key for one build step: parent image state + instruction + its inputs.
const std = @import("std");

pub const Key = [32]u8;

pub const Inputs = struct {
    /// Merged root manifest chunk id of the image the step runs on.
    parent_root: [32]u8,
    /// Instruction source text after continuation joining.
    instruction: []const u8,
    /// Effective `K=V` environment the step sees, in declaration order.
    env: []const []const u8 = &.{},
    workdir: []const u8 = "",
    user: []const u8 = "",
    /// Digest of the step's file inputs (COPY/ADD sources); zero when none.
    inputs_digest: [32]u8 = @splat(0),
};

pub fn compute(in: Inputs) Key {
    var h = std.crypto.hash.Blake3.init(.{});
    h.update("voila-build-step-v1");
    h.update(&in.parent_root);
    field(&h, normalize(in.instruction));
    var n: [8]u8 = undefined;
    std.mem.writeInt(u64, &n, in.env.len, .little);
    h.update(&n);
    for (in.env) |e| field(&h, e);
    field(&h, in.workdir);
    field(&h, in.user);
    h.update(&in.inputs_digest);
    var out: Key = undefined;
    h.final(&out);
    return out;
}

fn field(h: *std.crypto.hash.Blake3, s: []const u8) void {
    var n: [8]u8 = undefined;
    std.mem.writeInt(u64, &n, s.len, .little);
    h.update(&n);
    h.update(s);
}

/// Surrounding whitespace does not affect the key.
fn normalize(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}

/// Streaming digest of COPY sources; feed entries in a deterministic (sorted) order.
pub const InputsHasher = struct {
    h: std.crypto.hash.Blake3 = .init(.{}),

    pub fn entry(self: *InputsHasher, rel_path: []const u8, mode: u32, content_or_target: []const u8) void {
        field(&self.h, rel_path);
        var m: [4]u8 = undefined;
        std.mem.writeInt(u32, &m, mode, .little);
        self.h.update(&m);
        field(&self.h, content_or_target);
    }

    pub fn final(self: *InputsHasher) [32]u8 {
        var out: [32]u8 = undefined;
        self.h.final(&out);
        return out;
    }
};

const testing = std.testing;

test "cache key is stable and sensitive to every input" {
    const base: Inputs = .{
        .parent_root = @splat(1),
        .instruction = "RUN make",
        .env = &.{"A=1"},
        .workdir = "/src",
        .user = "root",
    };
    const k = compute(base);
    try testing.expectEqualSlices(u8, &k, &compute(base));

    var ws = base;
    ws.instruction = "  RUN make\t";
    try testing.expectEqualSlices(u8, &k, &compute(ws));

    var variants: [6]Inputs = @splat(base);
    variants[0].parent_root = @splat(2);
    variants[1].instruction = "RUN make all";
    variants[2].env = &.{"A=2"};
    variants[3].workdir = "/";
    variants[4].user = "nobody";
    variants[5].inputs_digest = @splat(9);
    for (variants) |v| {
        try testing.expect(!std.mem.eql(u8, &k, &compute(v)));
    }

    var split = base;
    split.env = &.{ "A=1", "" };
    try testing.expect(!std.mem.eql(u8, &k, &compute(split)));
}

test "inputs hasher distinguishes content, mode and path" {
    var a: InputsHasher = .{};
    a.entry("a.txt", 0o644, "hi");
    const da = a.final();
    var b: InputsHasher = .{};
    b.entry("a.txt", 0o755, "hi");
    var c: InputsHasher = .{};
    c.entry("a.txt", 0o644, "ho");
    var d: InputsHasher = .{};
    d.entry("a.tx", 0o644, "thi");
    try testing.expect(!std.mem.eql(u8, &da, &b.final()));
    try testing.expect(!std.mem.eql(u8, &da, &c.final()));
    try testing.expect(!std.mem.eql(u8, &da, &d.final()));
}
