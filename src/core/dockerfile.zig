//! Dockerfile parser (multi-stage subset) and `$VAR` expansion.
const std = @import("std");

pub const Form = union(enum) {
    shell: []const u8,
    exec: []const []const u8,
};

pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

pub const Copy = struct {
    srcs: []const []const u8,
    dest: []const u8,
    chown: []const u8 = "",
    /// `--from=<stage name|index|image>`; empty copies from the build context.
    from: []const u8 = "",
    chmod: ?u32 = null,
};

pub const Healthcheck = struct {
    /// `NONE`, `CMD` + exec argv, or `CMD-SHELL` + command, as in the OCI config.
    test_cmd: []const []const u8,
    interval_ns: ?u64 = null,
    timeout_ns: ?u64 = null,
    start_period_ns: ?u64 = null,
    retries: ?u32 = null,
};

pub const Arg = struct {
    name: []const u8,
    default: ?[]const u8 = null,
};

pub const From = struct {
    image: []const u8,
    /// `AS name`, lowercased; empty when absent.
    name: []const u8 = "",
};

pub const Op = union(enum) {
    from: From,
    run: Form,
    cmd: Form,
    entrypoint: Form,
    copy: Copy,
    add: Copy,
    env: []const KeyValue,
    label: []const KeyValue,
    arg: Arg,
    workdir: []const u8,
    user: []const u8,
    expose: []const []const u8,
    shell: []const []const u8,
    healthcheck: Healthcheck,
    stopsignal: []const u8,
    volume: []const []const u8,
    maintainer: []const u8,
};

pub const Instruction = struct {
    line: usize,
    /// Source text after continuation joining; stable input for cache keys.
    text: []const u8,
    op: Op,
};

/// Instructions from one FROM up to the next; `instructions[0]` is the FROM.
pub const Stage = struct {
    name: []const u8,
    instructions: []const Instruction,
};

pub const Dockerfile = struct {
    arena: std.heap.ArenaAllocator,
    /// ARGs declared before FROM.
    global_args: []const Arg,
    /// Every instruction of every stage, in file order.
    instructions: []const Instruction,
    stages: []const Stage,

    pub fn deinit(self: *Dockerfile) void {
        self.arena.deinit();
    }
};

pub const Diagnostic = struct {
    line: usize = 0,
};

pub const Error = error{
    OutOfMemory,
    UnknownInstruction,
    Unsupported,
    MissingArgument,
    MissingFrom,
    DuplicateStage,
    BadQuote,
    BadValue,
};

pub fn parse(gpa: std.mem.Allocator, text: []const u8, diag: *Diagnostic) Error!Dockerfile {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var global_args: std.ArrayList(Arg) = .empty;
    var out: std.ArrayList(Instruction) = .empty;
    var seen_from = false;
    var starts: std.ArrayList(usize) = .empty;
    var lines = LogicalLines{ .text = text };
    while (try lines.next(a)) |ll| {
        diag.line = ll.line;
        const kw_end = std.mem.indexOfAny(u8, ll.text, " \t") orelse ll.text.len;
        const rest = std.mem.trim(u8, ll.text[kw_end..], " \t");
        const op = try parseOp(a, ll.text[0..kw_end], rest);
        if (op == .from) {
            seen_from = true;
            try starts.append(a, out.items.len);
        } else if (!seen_from) {
            if (op != .arg) return error.MissingFrom;
            try global_args.append(a, op.arg);
            continue;
        }
        try out.append(a, .{ .line = ll.line, .text = ll.text, .op = op });
    }
    if (!seen_from) return error.MissingFrom;
    const instructions = try out.toOwnedSlice(a);
    const stages = try a.alloc(Stage, starts.items.len);
    for (stages, starts.items, 0..) |*st, start, i| {
        const end = if (i + 1 < starts.items.len) starts.items[i + 1] else instructions.len;
        st.* = .{ .name = instructions[start].op.from.name, .instructions = instructions[start..end] };
        if (st.name.len == 0) continue;
        for (stages[0..i]) |prev| if (std.mem.eql(u8, prev.name, st.name)) {
            diag.line = instructions[start].line;
            return error.DuplicateStage;
        };
    }
    diag.line = 0;
    return .{
        .arena = arena,
        .global_args = try global_args.toOwnedSlice(a),
        .instructions = instructions,
        .stages = stages,
    };
}

const LogicalLine = struct { line: usize, text: []const u8 };

const LogicalLines = struct {
    text: []const u8,
    pos: usize = 0,
    line_no: usize = 0,

    fn next(self: *LogicalLines, a: std.mem.Allocator) Error!?LogicalLine {
        var buf: std.ArrayList(u8) = .empty;
        var start_line: usize = 0;
        while (self.pos < self.text.len) {
            const end = std.mem.indexOfScalarPos(u8, self.text, self.pos, '\n') orelse self.text.len;
            const raw = std.mem.trimEnd(u8, self.text[self.pos..end], "\r");
            self.pos = end + 1;
            self.line_no += 1;
            const trimmed = std.mem.trim(u8, raw, " \t");
            if (trimmed.len > 0 and trimmed[0] == '#') continue;
            if (buf.items.len == 0 and trimmed.len == 0) continue;
            if (buf.items.len == 0) start_line = self.line_no;
            if (std.mem.endsWith(u8, trimmed, "\\")) {
                try buf.appendSlice(a, trimmed[0 .. trimmed.len - 1]);
                try buf.append(a, ' ');
                continue;
            }
            try buf.appendSlice(a, trimmed);
            break;
        }
        const joined = std.mem.trim(u8, buf.items, " \t");
        if (joined.len == 0) return null;
        return .{ .line = start_line, .text = joined };
    }
};

fn parseOp(a: std.mem.Allocator, keyword: []const u8, rest: []const u8) Error!Op {
    var kw_buf: [16]u8 = undefined;
    if (keyword.len > kw_buf.len) return error.UnknownInstruction;
    const kw = std.ascii.lowerString(&kw_buf, keyword);
    const eql = std.mem.eql;
    if (eql(u8, kw, "onbuild")) return error.Unsupported;
    if (rest.len == 0) return error.MissingArgument;
    if (eql(u8, kw, "from")) return .{ .from = try parseFrom(a, rest) };
    if (eql(u8, kw, "run")) {
        if (std.mem.startsWith(u8, rest, "--")) return error.Unsupported;
        return .{ .run = try parseForm(a, rest) };
    }
    if (eql(u8, kw, "cmd")) return .{ .cmd = try parseForm(a, rest) };
    if (eql(u8, kw, "entrypoint")) return .{ .entrypoint = try parseForm(a, rest) };
    if (eql(u8, kw, "copy")) return .{ .copy = try parseCopy(a, rest) };
    if (eql(u8, kw, "add")) return .{ .add = try parseCopy(a, rest) };
    if (eql(u8, kw, "env")) return .{ .env = try parseKeyValues(a, rest, true) };
    if (eql(u8, kw, "label")) return .{ .label = try parseKeyValues(a, rest, false) };
    if (eql(u8, kw, "arg")) return .{ .arg = parseArg(rest) };
    if (eql(u8, kw, "workdir")) return .{ .workdir = rest };
    if (eql(u8, kw, "user")) return .{ .user = rest };
    if (eql(u8, kw, "expose")) return .{ .expose = try splitWords(a, rest) };
    if (eql(u8, kw, "shell")) return .{ .shell = try parseShell(a, rest) };
    if (eql(u8, kw, "healthcheck")) return .{ .healthcheck = try parseHealthcheck(a, rest) };
    if (eql(u8, kw, "stopsignal")) return .{ .stopsignal = rest };
    if (eql(u8, kw, "volume")) return .{ .volume = try parseList(a, rest) };
    if (eql(u8, kw, "maintainer")) return .{ .maintainer = rest };
    return error.UnknownInstruction;
}

fn parseFrom(a: std.mem.Allocator, rest: []const u8) Error!From {
    const words = try splitWords(a, rest);
    if (words.len == 0) return error.MissingArgument;
    if (std.mem.startsWith(u8, words[0], "--")) return error.Unsupported;
    if (words.len == 1) return .{ .image = words[0] };
    if (words.len != 3 or !std.ascii.eqlIgnoreCase(words[1], "as")) return error.MissingArgument;
    return .{ .image = words[0], .name = try std.ascii.allocLowerString(a, words[2]) };
}

fn parseForm(a: std.mem.Allocator, rest: []const u8) Error!Form {
    if (rest[0] == '[') {
        if (std.json.parseFromSliceLeaky([]const []const u8, a, rest, .{})) |argv| {
            if (argv.len == 0) return error.MissingArgument;
            return .{ .exec = argv };
        } else |_| {}
    }
    return .{ .shell = rest };
}

fn parseCopy(a: std.mem.Allocator, rest: []const u8) Error!Copy {
    var words: []const []const u8 = undefined;
    var flags_end: usize = 0;
    const all = if (rest[0] == '[')
        std.json.parseFromSliceLeaky([]const []const u8, a, rest, .{}) catch try splitWords(a, rest)
    else
        try splitWords(a, rest);
    var chown: []const u8 = "";
    var from: []const u8 = "";
    var chmod: ?u32 = null;
    while (flags_end < all.len and std.mem.startsWith(u8, all[flags_end], "--")) : (flags_end += 1) {
        const flag = all[flags_end];
        if (std.mem.startsWith(u8, flag, "--chown=")) {
            chown = flag["--chown=".len..];
        } else if (std.mem.startsWith(u8, flag, "--from=")) {
            from = flag["--from=".len..];
            if (from.len == 0) return error.MissingArgument;
        } else if (std.mem.startsWith(u8, flag, "--chmod=")) {
            const v = flag["--chmod=".len..];
            if (std.mem.indexOfScalar(u8, v, '$') != null) return error.Unsupported;
            chmod = std.fmt.parseInt(u32, v, 8) catch return error.BadValue;
            if (chmod.? > 0o7777) return error.BadValue;
        } else return error.Unsupported;
    }
    words = all[flags_end..];
    if (words.len < 2) return error.MissingArgument;
    return .{ .srcs = words[0 .. words.len - 1], .dest = words[words.len - 1], .chown = chown, .from = from, .chmod = chmod };
}

fn parseShell(a: std.mem.Allocator, rest: []const u8) Error![]const []const u8 {
    if (rest[0] != '[') return error.BadValue;
    const argv = std.json.parseFromSliceLeaky([]const []const u8, a, rest, .{}) catch return error.BadValue;
    if (argv.len == 0) return error.BadValue;
    return argv;
}

/// JSON array or whitespace-separated words.
fn parseList(a: std.mem.Allocator, rest: []const u8) Error![]const []const u8 {
    if (rest[0] == '[') {
        if (std.json.parseFromSliceLeaky([]const []const u8, a, rest, .{})) |list| return list else |_| {}
    }
    return splitWords(a, rest);
}

fn parseHealthcheck(a: std.mem.Allocator, rest: []const u8) Error!Healthcheck {
    var hc: Healthcheck = .{ .test_cmd = &.{} };
    var tail = rest;
    while (std.mem.startsWith(u8, tail, "--")) {
        const end = std.mem.indexOfAny(u8, tail, " \t") orelse return error.MissingArgument;
        const flag = tail[0..end];
        tail = std.mem.trimStart(u8, tail[end..], " \t");
        const eq = std.mem.indexOfScalar(u8, flag, '=') orelse return error.BadValue;
        const name = flag[2..eq];
        const val = flag[eq + 1 ..];
        if (std.mem.eql(u8, name, "interval")) {
            hc.interval_ns = parseDuration(val) orelse return error.BadValue;
        } else if (std.mem.eql(u8, name, "timeout")) {
            hc.timeout_ns = parseDuration(val) orelse return error.BadValue;
        } else if (std.mem.eql(u8, name, "start-period")) {
            hc.start_period_ns = parseDuration(val) orelse return error.BadValue;
        } else if (std.mem.eql(u8, name, "retries")) {
            hc.retries = std.fmt.parseInt(u32, val, 10) catch return error.BadValue;
        } else return error.Unsupported;
    }
    const end = std.mem.indexOfAny(u8, tail, " \t") orelse tail.len;
    const sub = std.mem.trim(u8, tail[end..], " \t");
    if (std.ascii.eqlIgnoreCase(tail[0..end], "none")) {
        if (sub.len != 0) return error.BadValue;
        hc.test_cmd = try a.dupe([]const u8, &.{"NONE"});
        return hc;
    }
    if (!std.ascii.eqlIgnoreCase(tail[0..end], "cmd") or sub.len == 0) return error.MissingArgument;
    switch (try parseForm(a, sub)) {
        .exec => |argv| {
            const t = try a.alloc([]const u8, argv.len + 1);
            t[0] = "CMD";
            @memcpy(t[1..], argv);
            hc.test_cmd = t;
        },
        .shell => |cmd| hc.test_cmd = try a.dupe([]const u8, &.{ "CMD-SHELL", cmd }),
    }
    return hc;
}

/// Go-style duration (`30s`, `1m30s`, `500ms`) in nanoseconds.
pub fn parseDuration(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var total: u64 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const ds = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == ds) return null;
        const n = std.fmt.parseInt(u64, s[ds..i], 10) catch return null;
        const us = i;
        while (i < s.len and std.ascii.isAlphabetic(s[i])) i += 1;
        const unit = s[us..i];
        const mult: u64 = if (std.mem.eql(u8, unit, "ns")) 1 else if (std.mem.eql(u8, unit, "us")) 1_000 else if (std.mem.eql(u8, unit, "ms")) 1_000_000 else if (std.mem.eql(u8, unit, "s")) 1_000_000_000 else if (std.mem.eql(u8, unit, "m")) 60_000_000_000 else if (std.mem.eql(u8, unit, "h")) 3_600_000_000_000 else return null;
        const part = std.math.mul(u64, n, mult) catch return null;
        total = std.math.add(u64, total, part) catch return null;
    }
    if (total > std.math.maxInt(i64)) return null;
    return total;
}

fn parseArg(rest: []const u8) Arg {
    if (std.mem.indexOfScalar(u8, rest, '=')) |eq| {
        return .{ .name = rest[0..eq], .default = unquote(rest[eq + 1 ..]) };
    }
    return .{ .name = rest };
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '"' or s[0] == '\'') and s[s.len - 1] == s[0]) return s[1 .. s.len - 1];
    return s;
}

/// `K=V K2="a b"`; with `legacy_ok`, also the `ENV K some value` form.
fn parseKeyValues(a: std.mem.Allocator, rest: []const u8, legacy_ok: bool) Error![]const KeyValue {
    const first = std.mem.indexOfAny(u8, rest, " \t=") orelse rest.len;
    if (legacy_ok and (first == rest.len or rest[first] != '=')) {
        if (first == rest.len) return error.MissingArgument;
        const kv = try a.alloc(KeyValue, 1);
        kv[0] = .{ .key = rest[0..first], .value = std.mem.trim(u8, rest[first..], " \t") };
        return kv;
    }
    const words = try splitWords(a, rest);
    const out = try a.alloc(KeyValue, words.len);
    for (words, out) |w, *kv| {
        const eq = std.mem.indexOfScalar(u8, w, '=') orelse return error.MissingArgument;
        kv.* = .{ .key = w[0..eq], .value = w[eq + 1 ..] };
    }
    return out;
}

/// Splits on whitespace, honoring quotes and backslash escapes; quotes are removed.
fn splitWords(a: std.mem.Allocator, s: []const u8) Error![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var in_word = false;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (quote != 0) {
            if (c == quote) {
                quote = 0;
            } else if (c == '\\' and quote == '"' and i + 1 < s.len) {
                i += 1;
                try cur.append(a, s[i]);
            } else try cur.append(a, c);
            continue;
        }
        switch (c) {
            ' ', '\t' => if (in_word) {
                try words.append(a, try cur.toOwnedSlice(a));
                in_word = false;
            },
            '"', '\'' => {
                quote = c;
                in_word = true;
            },
            '\\' => {
                in_word = true;
                if (i + 1 < s.len) i += 1;
                try cur.append(a, s[i]);
            },
            else => {
                in_word = true;
                try cur.append(a, c);
            },
        }
    }
    if (quote != 0) return error.BadQuote;
    if (in_word) try words.append(a, try cur.toOwnedSlice(a));
    return words.toOwnedSlice(a);
}

/// Expands `$A`, `${A}`, `${A:-def}`, `${A:+alt}`; `\$` is a literal `$`. Unset vars expand to "".
pub fn expand(a: std.mem.Allocator, s: []const u8, vars: *const std.StringHashMapUnmanaged([]const u8)) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len and s[i + 1] == '$') {
            try out.append(a, '$');
            i += 2;
            continue;
        }
        if (c != '$' or i + 1 >= s.len) {
            try out.append(a, c);
            i += 1;
            continue;
        }
        if (s[i + 1] == '{') {
            const close = std.mem.indexOfScalarPos(u8, s, i + 2, '}') orelse return error.BadQuote;
            try expandBraced(a, &out, s[i + 2 .. close], vars);
            i = close + 1;
            continue;
        }
        var j = i + 1;
        while (j < s.len and isNameChar(s[j])) j += 1;
        if (j == i + 1) {
            try out.append(a, '$');
            i += 1;
            continue;
        }
        try out.appendSlice(a, vars.get(s[i + 1 .. j]) orelse "");
        i = j;
    }
    return out.toOwnedSlice(a);
}

fn expandBraced(a: std.mem.Allocator, out: *std.ArrayList(u8), body: []const u8, vars: *const std.StringHashMapUnmanaged([]const u8)) Error!void {
    if (std.mem.indexOf(u8, body, ":-")) |p| {
        const v = vars.get(body[0..p]) orelse "";
        return out.appendSlice(a, if (v.len > 0) v else body[p + 2 ..]);
    }
    if (std.mem.indexOf(u8, body, ":+")) |p| {
        const v = vars.get(body[0..p]) orelse "";
        return out.appendSlice(a, if (v.len > 0) body[p + 2 ..] else "");
    }
    try out.appendSlice(a, vars.get(body) orelse "");
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

const testing = std.testing;

fn parseOk(text: []const u8) !Dockerfile {
    var diag: Diagnostic = .{};
    return parse(testing.allocator, text, &diag);
}

test "parse basic dockerfile with continuations, comments and forms" {
    var df = try parseOk(
        \\# syntax comment
        \\ARG BASE=alpine:3.20
        \\FROM ${BASE} AS app
        \\
        \\ENV A=1 B="two words"
        \\ENV LEGACY some value
        \\RUN apk add \
        \\    curl \
        \\  # interleaved comment
        \\    git
        \\COPY --chown=1:1 a.txt b/ /app/
        \\WORKDIR /app
        \\cmd ["sh", "-c", "echo hi"]
        \\ENTRYPOINT [not json
        \\EXPOSE 80 443/tcp
        \\LABEL org.x="y z"
        \\USER nobody
    );
    defer df.deinit();
    try testing.expectEqual(@as(usize, 1), df.global_args.len);
    try testing.expectEqualStrings("alpine:3.20", df.global_args[0].default.?);
    const ins = df.instructions;
    try testing.expectEqualStrings("${BASE}", ins[0].op.from.image);
    try testing.expectEqualStrings("app", ins[0].op.from.name);
    try testing.expectEqual(@as(usize, 1), df.stages.len);
    try testing.expectEqualStrings("two words", ins[1].op.env[1].value);
    try testing.expectEqualStrings("some value", ins[2].op.env[0].value);
    try testing.expectEqualStrings("apk add  curl  git", ins[3].op.run.shell);
    try testing.expectEqual(@as(usize, 7), ins[3].line);
    try testing.expectEqual(@as(usize, 2), ins[4].op.copy.srcs.len);
    try testing.expectEqualStrings("/app/", ins[4].op.copy.dest);
    try testing.expectEqualStrings("1:1", ins[4].op.copy.chown);
    try testing.expectEqualStrings("echo hi", ins[6].op.cmd.exec[2]);
    try testing.expectEqualStrings("[not json", ins[7].op.entrypoint.shell);
    try testing.expectEqualStrings("443/tcp", ins[8].op.expose[1]);
    try testing.expectEqualStrings("y z", ins[9].op.label[0].value);
}

test "parse errors carry the line number" {
    const cases = [_]struct { text: []const u8, err: Error, line: usize }{
        .{ .text = "RUN true", .err = error.MissingFrom, .line = 1 },
        .{ .text = "FROM a\n\nFROBNICATE x", .err = error.UnknownInstruction, .line = 3 },
        .{ .text = "FROM a AS x\nFROM b as X", .err = error.DuplicateStage, .line = 2 },
        .{ .text = "FROM a\nRUN --mount=type=cache true", .err = error.Unsupported, .line = 2 },
        .{ .text = "FROM a\nCOPY --from= a b", .err = error.MissingArgument, .line = 2 },
        .{ .text = "FROM a AS\n", .err = error.MissingArgument, .line = 1 },
        .{ .text = "FROM a\nCOPY onlyone", .err = error.MissingArgument, .line = 2 },
        .{ .text = "FROM a\nENV X=\"open", .err = error.BadQuote, .line = 2 },
        .{ .text = "# only comments\n", .err = error.MissingFrom, .line = 0 },
    };
    for (cases) |c| {
        var diag: Diagnostic = .{};
        try testing.expectError(c.err, parse(testing.allocator, c.text, &diag));
        try testing.expectEqual(c.line, diag.line);
    }
}

test "parse splits stages and COPY --from" {
    var df = try parseOk(
        \\ARG V=1
        \\FROM golang:$V AS Builder
        \\RUN make
        \\FROM builder
        \\ARG X
        \\FROM scratch
        \\COPY --from=builder --chown=1:2 /out/app /bin/
        \\COPY --from=0 /etc/os-release /etc/
    );
    defer df.deinit();
    try testing.expectEqual(@as(usize, 1), df.global_args.len);
    try testing.expectEqual(@as(usize, 3), df.stages.len);
    try testing.expectEqual(@as(usize, 7), df.instructions.len);
    const s = df.stages;
    try testing.expectEqualStrings("builder", s[0].name);
    try testing.expectEqual(@as(usize, 2), s[0].instructions.len);
    try testing.expectEqualStrings("builder", s[1].instructions[0].op.from.image);
    try testing.expectEqualStrings("", s[1].name);
    try testing.expectEqualStrings("X", s[1].instructions[1].op.arg.name);
    const c = s[2].instructions[1].op.copy;
    try testing.expectEqualStrings("builder", c.from);
    try testing.expectEqualStrings("1:2", c.chown);
    try testing.expectEqualStrings("/bin/", c.dest);
    try testing.expectEqualStrings("0", s[2].instructions[2].op.copy.from);
    try testing.expectEqual(@as(usize, 8), s[2].instructions[2].line);
}

test "expand variables" {
    var vars: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer vars.deinit(testing.allocator);
    try vars.put(testing.allocator, "A", "x");
    try vars.put(testing.allocator, "EMPTY", "");
    const cases = [_][2][]const u8{
        .{ "$A/${A}", "x/x" },
        .{ "${MISSING:-def} ${A:-def}", "def x" },
        .{ "${EMPTY:-def}", "def" },
        .{ "${A:+alt}${MISSING:+alt}", "alt" },
        .{ "\\$A $ $1x", "$A $ " },
        .{ "$A_B-$A", "-x" },
    };
    for (cases) |c| {
        const got = try expand(testing.allocator, c[0], &vars);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
}

test "parse SHELL, STOPSIGNAL, VOLUME and MAINTAINER" {
    var df = try parseOk(
        \\FROM a
        \\SHELL ["/bin/bash", "-eo", "pipefail", "-c"]
        \\STOPSIGNAL SIGQUIT
        \\VOLUME ["/data", "/logs"]
        \\VOLUME /a /b
        \\MAINTAINER Jane <jane@example.com>
    );
    defer df.deinit();
    const ins = df.instructions;
    try testing.expectEqual(@as(usize, 4), ins[1].op.shell.len);
    try testing.expectEqualStrings("pipefail", ins[1].op.shell[2]);
    try testing.expectEqualStrings("SIGQUIT", ins[2].op.stopsignal);
    try testing.expectEqualStrings("/logs", ins[3].op.volume[1]);
    try testing.expectEqualStrings("/b", ins[4].op.volume[1]);
    try testing.expectEqualStrings("Jane <jane@example.com>", ins[5].op.maintainer);
}

test "parse HEALTHCHECK" {
    var df = try parseOk(
        \\FROM a
        \\HEALTHCHECK --interval=30s --timeout=1m30s --start-period=500ms --retries=3 CMD curl -f http://localhost/
        \\HEALTHCHECK CMD ["pg_isready", "-q"]
        \\HEALTHCHECK NONE
    );
    defer df.deinit();
    const a = df.instructions[1].op.healthcheck;
    try testing.expectEqualStrings("CMD-SHELL", a.test_cmd[0]);
    try testing.expectEqualStrings("curl -f http://localhost/", a.test_cmd[1]);
    try testing.expectEqual(@as(?u64, 30_000_000_000), a.interval_ns);
    try testing.expectEqual(@as(?u64, 90_000_000_000), a.timeout_ns);
    try testing.expectEqual(@as(?u64, 500_000_000), a.start_period_ns);
    try testing.expectEqual(@as(?u32, 3), a.retries);
    const b = df.instructions[2].op.healthcheck;
    try testing.expectEqual(@as(usize, 3), b.test_cmd.len);
    try testing.expectEqualStrings("CMD", b.test_cmd[0]);
    try testing.expectEqual(@as(?u64, null), b.interval_ns);
    try testing.expectEqualStrings("NONE", df.instructions[3].op.healthcheck.test_cmd[0]);
}

test "parse COPY --chmod and malformed extras" {
    var df = try parseOk("FROM a\nCOPY --chmod=0755 --chown=app x /y\n");
    defer df.deinit();
    try testing.expectEqual(@as(?u32, 0o755), df.instructions[1].op.copy.chmod);
    try testing.expectEqualStrings("app", df.instructions[1].op.copy.chown);

    const cases = [_]struct { text: []const u8, err: Error }{
        .{ .text = "FROM a\nCOPY --chmod=u+x x /y", .err = error.BadValue },
        .{ .text = "FROM a\nCOPY --chmod=9 x /y", .err = error.BadValue },
        .{ .text = "FROM a\nSHELL /bin/bash -c", .err = error.BadValue },
        .{ .text = "FROM a\nSHELL []", .err = error.BadValue },
        .{ .text = "FROM a\nHEALTHCHECK --interval=xx CMD true", .err = error.BadValue },
        .{ .text = "FROM a\nHEALTHCHECK --retries=-1 CMD true", .err = error.BadValue },
        .{ .text = "FROM a\nHEALTHCHECK --interval=3000000h CMD true", .err = error.BadValue },
        .{ .text = "FROM a\nHEALTHCHECK --interval=1s", .err = error.MissingArgument },
        .{ .text = "FROM a\nHEALTHCHECK CMD", .err = error.MissingArgument },
        .{ .text = "FROM a\nHEALTHCHECK NONE x", .err = error.BadValue },
        .{ .text = "FROM a\nVOLUME", .err = error.MissingArgument },
    };
    for (cases) |c| {
        var diag: Diagnostic = .{};
        try testing.expectError(c.err, parse(testing.allocator, c.text, &diag));
        try testing.expectEqual(@as(usize, 2), diag.line);
    }
}

test "parseDuration" {
    try testing.expectEqual(@as(?u64, null), parseDuration("3000000h"));
    try testing.expectEqual(@as(?u64, null), parseDuration("1.5s"));
    try testing.expectEqual(@as(?u64, 1_500_000_000), parseDuration("1s500ms"));
    try testing.expectEqual(@as(?u64, 3_600_000_000_000), parseDuration("1h"));
    try testing.expectEqual(@as(?u64, null), parseDuration("10"));
    try testing.expectEqual(@as(?u64, null), parseDuration(""));
    try testing.expectEqual(@as(?u64, null), parseDuration("s"));
}
