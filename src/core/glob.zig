//! Path globbing for COPY sources and `.dockerignore` (`*`, `?`, `**`, `!` negation).
const std = @import("std");

/// Matches one path segment against a pattern segment (`*` and `?`, no `/`).
pub fn matchSegment(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star_p: ?usize = null;
    var star_n: usize = 0;
    while (n < name.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == name[n])) {
            p += 1;
            n += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star_p = p;
            star_n = n;
            p += 1;
        } else if (star_p) |sp| {
            p = sp + 1;
            star_n += 1;
            n = star_n;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// Matches a `/`-separated path; a `**` segment matches zero or more segments.
pub fn match(pattern: []const u8, path: []const u8) bool {
    var pi = std.mem.splitScalar(u8, pattern, '/');
    var segs_buf: [64][]const u8 = undefined;
    var psegs: [64][]const u8 = undefined;
    var np: usize = 0;
    while (pi.next()) |s| {
        if (np == psegs.len) return false;
        psegs[np] = s;
        np += 1;
    }
    var ni = std.mem.splitScalar(u8, path, '/');
    var nn: usize = 0;
    while (ni.next()) |s| {
        if (nn == segs_buf.len) return false;
        segs_buf[nn] = s;
        nn += 1;
    }
    return matchSegs(psegs[0..np], segs_buf[0..nn]);
}

fn matchSegs(p: []const []const u8, n: []const []const u8) bool {
    if (p.len == 0) return n.len == 0;
    if (std.mem.eql(u8, p[0], "**")) {
        var i: usize = 0;
        while (i <= n.len) : (i += 1) if (matchSegs(p[1..], n[i..])) return true;
        return false;
    }
    if (n.len == 0) return false;
    return matchSegment(p[0], n[0]) and matchSegs(p[1..], n[1..]);
}

pub fn hasWildcard(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "*?") != null;
}

pub const Ignore = struct {
    rules: []const Rule,

    const Rule = struct { pattern: []const u8, negate: bool };

    /// Parses `.dockerignore` text; patterns borrow from `text`.
    pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Ignore {
        var rules: std.ArrayList(Rule) = .empty;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            var line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const negate = line[0] == '!';
            if (negate) line = std.mem.trim(u8, line[1..], " \t");
            while (std.mem.startsWith(u8, line, "./")) line = line[2..];
            line = std.mem.trim(u8, line, "/");
            if (line.len == 0) continue;
            try rules.append(allocator, .{ .pattern = line, .negate = negate });
        }
        return .{ .rules = try rules.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: Ignore, allocator: std.mem.Allocator) void {
        allocator.free(self.rules);
    }

    /// Last matching rule wins; a rule matching a parent directory covers its contents.
    pub fn excluded(self: Ignore, rel: []const u8) bool {
        var out = false;
        for (self.rules) |r| {
            if (matchSelfOrParent(r.pattern, rel)) out = !r.negate;
        }
        return out;
    }

    fn matchSelfOrParent(pattern: []const u8, rel: []const u8) bool {
        if (match(pattern, rel)) return true;
        var i: usize = rel.len;
        while (std.mem.lastIndexOfScalar(u8, rel[0..i], '/')) |slash| {
            if (match(pattern, rel[0..slash])) return true;
            i = slash;
        }
        return false;
    }
};

const testing = std.testing;

test "segment and path matching" {
    const yes = [_][2][]const u8{
        .{ "*.go", "main.go" },     .{ "a?c", "abc" },       .{ "*", "" },
        .{ "**/*.md", "a/b/c.md" }, .{ "**/*.md", "c.md" },  .{ "src/**", "src/a/b" },
        .{ "a*b*c", "aXXbYYc" },    .{ "docs/*", "docs/x" },
    };
    const no = [_][2][]const u8{
        .{ "*.go", "a/main.go" }, .{ "a?c", "ac" }, .{ "docs/*", "docs/x/y" },
        .{ "a*b*c", "aXXbYY" },   .{ "x", "xy" },
    };
    for (yes) |c| try testing.expect(match(c[0], c[1]));
    for (no) |c| try testing.expect(!match(c[0], c[1]));
}

test "dockerignore: dirs cover contents, negation re-includes, last rule wins" {
    const ig = try Ignore.parse(testing.allocator,
        \\# comment
        \\.git
        \\node_modules/
        \\*.log
        \\!keep.log
        \\/build
        \\docs/**/*.tmp
    );
    defer ig.deinit(testing.allocator);
    try testing.expect(ig.excluded(".git"));
    try testing.expect(ig.excluded(".git/objects/ab"));
    try testing.expect(ig.excluded("node_modules/x/index.js"));
    try testing.expect(ig.excluded("debug.log"));
    try testing.expect(!ig.excluded("keep.log"));
    try testing.expect(ig.excluded("build/out"));
    try testing.expect(ig.excluded("docs/a/b/x.tmp"));
    try testing.expect(!ig.excluded("src/main.zig"));
    try testing.expect(!ig.excluded("sub/debug.log"));
}
