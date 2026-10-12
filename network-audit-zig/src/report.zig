//! Offline HTML report and text summary for a captured session.
//!
//! Native Zig port of network-audit/report.py and report.html.jinja. Captured
//! content is data, never HTML: every value is HTML-escaped or embedded as
//! script-safe JSON, and the template is split into static segments at compile
//! time so user content is never re-processed as template markers.
//!
//! The static markup, styling, theme toggle and explorer/filter JavaScript are
//! duplicated from network-audit/report.html.jinja into report/report.html for
//! this experimental port (no Python, Jinja or other rendering dependency).
//! Keep the two copies in sync when the report changes.
//!
//! Output mirrors the Python implementation byte for byte for the data that
//! capture.py writes: Python json.loads/json.dumps(sort_keys=True,
//! ensure_ascii=True) semantics (including lone surrogate escapes and NaN /
//! Infinity), Jinja/markupsafe escaping, urllib.parse.urlsplit (Python 3.14)
//! and parse_qsl(keep_blank_values=True) with UTF-8 "replace" decoding.
//!
//! Deliberate deviations where Python would crash instead of reporting:
//! records that are valid JSON but not objects, lack an "id" or have an
//! unhashable id are reported as unreadable records; missing "host", "error"
//! or "response" fields count as null; non-numeric statuses and byte counts
//! are ignored; a truthy non-string "url" yields unparseable url_parts; lone
//! surrogates are written as U+FFFD in HTML/text (Python raises on write).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Reads `<session>/session.json` and `<session>/events.jsonl` (left
/// unchanged), writes `<session>/report.html` and `<session>/report.txt`, and
/// returns the report.html path (`session` joined with "report.html"), owned by
/// `allocator`.
pub fn generate(allocator: Allocator, io: Io, session: []const u8) ![]const u8 {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = Io.Dir.cwd();

    const metadata_text = try cwd.readFileAlloc(io, try std.fs.path.join(arena, &.{ session, "session.json" }), arena, .unlimited);
    const metadata_value = parseJson(arena, metadata_text) catch return error.InvalidSessionMetadata;
    if (metadata_value != .object) return error.InvalidSessionMetadata;
    const metadata = metadata_value.object;

    const events_path = try std.fs.path.join(arena, &.{ session, "events.jsonl" });
    const events_text: []const u8 = cwd.readFileAlloc(io, events_path, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    var recovered = try readEvents(arena, events_text);
    const flows = recovered.flows;
    var diagnostics = &recovered.diagnostics;

    for (flows) |flow| {
        const url: Value = flow.get("url") orelse .{ .string = "" };
        try flow.put(arena, "url_parts", try urlParts(arena, url));
    }
    if (metadata.get("failure")) |failure| {
        if (truthy(failure)) try diagnostics.insert(arena, 0, failure);
    }
    if (flows.len == 0) try diagnostics.append(arena, .{ .string = "No matching HTTP exchanges captured. This does not prove the app made no network requests; check the domain filters and TLS diagnostics." });

    // Counter(...).most_common(): count descending, ties in first-seen order.
    var host_map: std.array_hash_map.String(HostCount) = .empty;
    for (flows) |flow| {
        const host = flow.get("host") orelse .null;
        const key = try hashKey(arena, host) orelse try std.fmt.allocPrint(arena, "u{f}", .{JsonFmt{ .gpa = arena, .value = host }});
        const entry = try host_map.getOrPut(arena, key);
        if (entry.found_existing) entry.value_ptr.count += 1 else entry.value_ptr.* = .{ .host = host, .count = 1 };
    }
    const host_counts = host_map.values();
    std.mem.sort(HostCount, host_counts, {}, HostCount.moreFrequent);
    var max_host_count: usize = 0;
    for (host_counts) |host| max_host_count = @max(max_host_count, host.count);

    var errors: usize = 0;
    var bytes: ByteTotal = .{};
    for (flows) |flow| {
        const response = flow.get("response") orelse .null;
        if (truthy(flow.get("error") orelse .null) or !truthy(response) or statusIsError(response)) errors += 1;
        if (response == .object) bytes.add(response.object.get("bytes") orelse .null);
    }

    const html = try renderHtml(arena, .{
        .metadata = metadata,
        .flows = flows,
        .diagnostics = diagnostics.items,
        .host_counts = host_counts,
        .max_host_count = max_host_count,
        .errors = errors,
        .kilobytes = bytes.kilobytes(),
    });
    const report_path = try std.fs.path.join(allocator, &.{ session, "report.html" });
    errdefer allocator.free(report_path);
    try cwd.writeFile(io, .{ .sub_path = report_path, .data = html });

    var summary: std.ArrayList(u8) = .empty;
    try summary.appendSlice(arena, "Requests per domain:\n");
    for (host_counts) |host| {
        try appendPyStr(arena, &summary, host.host, .text);
        try summary.print(arena, ": {d}\n", .{host.count});
    }
    if (host_counts.len == 0) try summary.appendSlice(arena, "No matching HTTP requests captured.\n");
    try summary.print(arena, "Total requests: {d}\n", .{flows.len});
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ session, "report.txt" }), .data = summary.items });
    return report_path;
}

// ---------------------------------------------------------------------------
// JSON values with Python json.loads semantics.

const Object = std.array_hash_map.String(Value);

const Value = union(enum) {
    null,
    bool: bool,
    /// Canonical decimal text of an arbitrary-precision integer.
    int: []const u8,
    float: f64,
    /// WTF-8: lone UTF-16 surrogates are kept as three-byte sequences.
    string: []const u8,
    array: []Value,
    object: *Object,
};

const ParseError = error{ InvalidJson, OutOfMemory };

fn parseJson(arena: Allocator, text: []const u8) ParseError!Value {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidJson;
    var parser: JsonParser = .{ .arena = arena, .text = text };
    parser.skipSpace();
    const value = try parser.value(0);
    parser.skipSpace();
    if (parser.pos != text.len) return error.InvalidJson;
    return value;
}

const JsonParser = struct {
    arena: Allocator,
    text: []const u8,
    pos: usize = 0,

    const max_depth = 512;

    fn skipSpace(p: *JsonParser) void {
        while (p.pos < p.text.len) : (p.pos += 1) switch (p.text[p.pos]) {
            ' ', '\t', '\n', '\r' => {},
            else => return,
        };
    }

    fn literal(p: *JsonParser, word: []const u8) bool {
        if (!std.mem.startsWith(u8, p.text[p.pos..], word)) return false;
        p.pos += word.len;
        return true;
    }

    fn value(p: *JsonParser, depth: usize) ParseError!Value {
        if (depth > max_depth or p.pos >= p.text.len) return error.InvalidJson;
        switch (p.text[p.pos]) {
            '"' => return .{ .string = try p.string() },
            '{' => {
                p.pos += 1;
                const object = try p.arena.create(Object);
                object.* = .empty;
                p.skipSpace();
                if (p.literal("}")) return .{ .object = object };
                while (true) {
                    if (p.pos >= p.text.len or p.text[p.pos] != '"') return error.InvalidJson;
                    const key = try p.string();
                    p.skipSpace();
                    if (!p.literal(":")) return error.InvalidJson;
                    p.skipSpace();
                    // Duplicate keys: last value wins at the first key's position.
                    try object.put(p.arena, key, try p.value(depth + 1));
                    p.skipSpace();
                    if (p.literal("}")) return .{ .object = object };
                    if (!p.literal(",")) return error.InvalidJson;
                    p.skipSpace();
                }
            },
            '[' => {
                p.pos += 1;
                var items: std.ArrayList(Value) = .empty;
                p.skipSpace();
                if (p.literal("]")) return .{ .array = items.items };
                while (true) {
                    try items.append(p.arena, try p.value(depth + 1));
                    p.skipSpace();
                    if (p.literal("]")) return .{ .array = items.items };
                    if (!p.literal(",")) return error.InvalidJson;
                    p.skipSpace();
                }
            },
            else => {
                if (p.literal("null")) return .null;
                if (p.literal("true")) return .{ .bool = true };
                if (p.literal("false")) return .{ .bool = false };
                if (p.literal("NaN")) return .{ .float = std.math.nan(f64) };
                if (p.literal("Infinity")) return .{ .float = std.math.inf(f64) };
                if (p.literal("-Infinity")) return .{ .float = -std.math.inf(f64) };
                return p.number();
            },
        }
    }

    fn digits(p: *JsonParser) usize {
        const start = p.pos;
        while (p.pos < p.text.len and std.ascii.isDigit(p.text[p.pos])) p.pos += 1;
        return p.pos - start;
    }

    fn number(p: *JsonParser) ParseError!Value {
        const start = p.pos;
        if (p.pos < p.text.len and p.text[p.pos] == '-') p.pos += 1;
        if (p.pos >= p.text.len or !std.ascii.isDigit(p.text[p.pos])) return error.InvalidJson;
        if (p.text[p.pos] == '0') p.pos += 1 else _ = p.digits();
        var is_float = false;
        if (p.pos + 1 < p.text.len and p.text[p.pos] == '.' and std.ascii.isDigit(p.text[p.pos + 1])) {
            p.pos += 1;
            _ = p.digits();
            is_float = true;
        }
        if (p.pos < p.text.len and (p.text[p.pos] == 'e' or p.text[p.pos] == 'E')) {
            const mark = p.pos;
            p.pos += 1;
            if (p.pos < p.text.len and (p.text[p.pos] == '+' or p.text[p.pos] == '-')) p.pos += 1;
            if (p.digits() == 0) p.pos = mark else is_float = true;
        }
        const lexeme = p.text[start..p.pos];
        if (is_float) return .{ .float = std.fmt.parseFloat(f64, lexeme) catch return error.InvalidJson };
        return .{ .int = if (std.mem.eql(u8, lexeme, "-0")) "0" else lexeme };
    }

    fn hex4(p: *JsonParser) ParseError!u16 {
        if (p.pos + 4 > p.text.len) return error.InvalidJson;
        const unit = std.fmt.parseInt(u16, p.text[p.pos..][0..4], 16) catch return error.InvalidJson;
        for (p.text[p.pos..][0..4]) |c| if (!std.ascii.isHex(c)) return error.InvalidJson;
        p.pos += 4;
        return unit;
    }

    fn string(p: *JsonParser) ParseError![]const u8 {
        p.pos += 1; // opening quote
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (p.pos >= p.text.len) return error.InvalidJson;
            const c = p.text[p.pos];
            p.pos += 1;
            switch (c) {
                '"' => return out.items,
                0...0x1f => return error.InvalidJson,
                '\\' => {
                    if (p.pos >= p.text.len) return error.InvalidJson;
                    const escape = p.text[p.pos];
                    p.pos += 1;
                    switch (escape) {
                        '"', '\\', '/' => try out.append(p.arena, escape),
                        'b' => try out.append(p.arena, 0x08),
                        'f' => try out.append(p.arena, 0x0c),
                        'n' => try out.append(p.arena, '\n'),
                        'r' => try out.append(p.arena, '\r'),
                        't' => try out.append(p.arena, '\t'),
                        'u' => {
                            var code: u21 = try p.hex4();
                            if (code >= 0xd800 and code <= 0xdbff and std.mem.startsWith(u8, p.text[p.pos..], "\\u")) {
                                p.pos += 2;
                                const low = try p.hex4();
                                if (low >= 0xdc00 and low <= 0xdfff) {
                                    code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
                                } else {
                                    p.pos -= 6; // decode the second escape on its own
                                }
                            }
                            try appendWtf8(p.arena, &out, code);
                        },
                        else => return error.InvalidJson,
                    }
                },
                else => try out.append(p.arena, c),
            }
        }
    }
};

fn appendWtf8(gpa: Allocator, out: *std.ArrayList(u8), code: u21) !void {
    var buf: [4]u8 = undefined;
    const len: usize = if (code < 0x80) 1 else if (code < 0x800) 2 else if (code < 0x10000) 3 else 4;
    switch (len) {
        1 => buf[0] = @intCast(code),
        2 => {
            buf[0] = @intCast(0xc0 | (code >> 6));
            buf[1] = @intCast(0x80 | (code & 0x3f));
        },
        3 => {
            buf[0] = @intCast(0xe0 | (code >> 12));
            buf[1] = @intCast(0x80 | ((code >> 6) & 0x3f));
            buf[2] = @intCast(0x80 | (code & 0x3f));
        },
        else => {
            buf[0] = @intCast(0xf0 | (code >> 18));
            buf[1] = @intCast(0x80 | ((code >> 12) & 0x3f));
            buf[2] = @intCast(0x80 | ((code >> 6) & 0x3f));
            buf[3] = @intCast(0x80 | (code & 0x3f));
        },
    }
    try out.appendSlice(gpa, buf[0..len]);
}

/// Decodes one code point of well-formed WTF-8 (as produced by this module);
/// malformed bytes decode as U+FFFD one byte at a time.
fn nextCodePoint(s: []const u8, i: *usize) u21 {
    const c = s[i.*];
    const len: usize = if (c < 0x80) 1 else if (c >= 0xc2 and c < 0xe0) 2 else if (c >= 0xe0 and c < 0xf0) 3 else if (c >= 0xf0 and c < 0xf5) 4 else 0;
    if (len == 0 or i.* + len > s.len) {
        i.* += 1;
        return 0xfffd;
    }
    var code: u21 = if (len == 1) c else c & (@as(u8, 0x7f) >> @intCast(len));
    for (s[i.* + 1 .. i.* + len]) |b| {
        if (b & 0xc0 != 0x80) {
            i.* += 1;
            return 0xfffd;
        }
        code = (code << 6) | (b & 0x3f);
    }
    i.* += len;
    return code;
}

fn truthy(v: Value) bool {
    return switch (v) {
        .null => false,
        .bool => |b| b,
        .int => |s| !std.mem.eql(u8, s, "0"),
        .float => |f| f != 0,
        .string => |s| s.len != 0,
        .array => |a| a.len != 0,
        .object => |o| o.count() != 0,
    };
}

/// Python dict-key identity for hashable JSON values (1 == 1.0 == True);
/// null for unhashable arrays and objects.
fn hashKey(arena: Allocator, v: Value) Allocator.Error!?[]const u8 {
    return switch (v) {
        .null => "z",
        .bool => |b| if (b) "n1" else "n0",
        .int => |s| try std.fmt.allocPrint(arena, "n{s}", .{s}),
        .float => |f| if (std.math.isNan(f))
            "nan"
        else if (std.math.isFinite(f) and @floor(f) == f and @abs(f) < 0x1p126)
            try std.fmt.allocPrint(arena, "n{d}", .{@as(i128, @intFromFloat(f))})
        else
            try std.fmt.allocPrint(arena, "f{f}", .{FloatRepr{ .value = f, .json = false }}),
        .string => |s| try std.fmt.allocPrint(arena, "s{s}", .{s}),
        .array, .object => null,
    };
}

// ---------------------------------------------------------------------------
// Event recovery (read_events).

const Recovered = struct {
    flows: []*Object,
    diagnostics: std.ArrayList(Value),
};

fn readEvents(arena: Allocator, text: []const u8) !Recovered {
    var by_id: std.array_hash_map.String(*Object) = .empty;
    var diagnostics: std.ArrayList(Value) = .empty;
    var lines = LineIterator{ .text = text };
    var number: usize = 0;
    while (lines.next()) |line| {
        number += 1;
        const event = parseJson(arena, line) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.InvalidJson => .null,
        };
        if (event == .object) {
            if (event.object.get("diagnostic")) |diagnostic| {
                try diagnostics.append(arena, diagnostic);
                continue;
            }
            if (event.object.get("id")) |id| if (try hashKey(arena, id)) |key| {
                try by_id.put(arena, key, event.object);
                continue;
            };
        }
        try diagnostics.append(arena, .{ .string = try std.fmt.allocPrint(arena, "Unreadable capture record at line {d} (possibly interrupted write)", .{number}) });
    }
    const flows = by_id.values();
    const keys = try arena.alloc(StartKey, flows.len);
    for (flows, keys) |flow, *key| key.* = .{ .flow = flow, .started = try StartKey.of(flow.get("started") orelse return error.MissingStartTime) };
    if (keys.len > 1) for (keys[1..]) |key| {
        if ((key.started == .text) != (keys[0].started == .text)) return error.IncomparableStartTimes;
    };
    std.mem.sort(StartKey, keys, {}, StartKey.lessThan); // stable, like sorted()
    for (flows, keys) |*flow, key| flow.* = key.flow;
    return .{ .flows = flows, .diagnostics = diagnostics };
}

const StartKey = struct {
    flow: *Object,
    started: union(enum) { int: i128, float: f64, text: []const u8 },

    fn of(v: Value) !@FieldType(StartKey, "started") {
        return switch (v) {
            .bool => |b| .{ .int = @intFromBool(b) },
            .int => |s| if (std.fmt.parseInt(i128, s, 10)) |i| .{ .int = i } else |_| .{ .float = std.fmt.parseFloat(f64, s) catch unreachable },
            .float => |f| .{ .float = f },
            .string => |s| .{ .text = s },
            else => error.IncomparableStartTimes,
        };
    }

    fn lessThan(_: void, a: StartKey, b: StartKey) bool {
        return switch (a.started) {
            .text => |x| std.mem.order(u8, x, b.started.text) == .lt,
            .int => |x| switch (b.started) {
                .int => |y| x < y,
                .float => |y| @as(f64, @floatFromInt(x)) < y,
                .text => unreachable,
            },
            .float => |x| switch (b.started) {
                .int => |y| x < @as(f64, @floatFromInt(y)),
                .float => |y| x < y,
                .text => unreachable,
            },
        };
    }
};

/// Python str.splitlines().
const LineIterator = struct {
    text: []const u8,
    pos: usize = 0,

    fn next(it: *LineIterator) ?[]const u8 {
        if (it.pos >= it.text.len) return null;
        const start = it.pos;
        var i = start;
        while (i < it.text.len) : (i += 1) {
            const rest = it.text[i..];
            const len: usize = switch (rest[0]) {
                '\n', 0x0b, 0x0c, 0x1c, 0x1d, 0x1e => 1,
                '\r' => if (rest.len > 1 and rest[1] == '\n') 2 else 1,
                0xc2 => if (rest.len > 1 and rest[1] == 0x85) 2 else 0,
                0xe2 => if (std.mem.startsWith(u8, rest, "\u{2028}") or std.mem.startsWith(u8, rest, "\u{2029}")) 3 else 0,
                else => 0,
            };
            if (len != 0) {
                it.pos = i + len;
                return it.text[start..i];
            }
        }
        it.pos = it.text.len;
        return it.text[start..];
    }
};

// ---------------------------------------------------------------------------
// Totals.

const HostCount = struct {
    host: Value,
    count: usize,

    fn moreFrequent(_: void, a: HostCount, b: HostCount) bool {
        return a.count > b.count;
    }
};

fn statusIsError(response: Value) bool {
    if (response != .object) return false;
    return switch (response.object.get("status") orelse return false) {
        .int => |s| if (std.fmt.parseInt(i128, s, 10)) |i| i >= 400 else |_| s[0] != '-',
        .float => |f| f >= 400,
        else => false,
    };
}

/// sum((f["response"] or {}).get("bytes") or 0 for f in flows)
const ByteTotal = struct {
    int: i128 = 0,
    float: ?f64 = null,

    fn add(t: *ByteTotal, v: Value) void {
        switch (v) {
            .bool => |b| t.addInt(@intFromBool(b)),
            .int => |s| if (std.fmt.parseInt(i128, s, 10)) |i| t.addInt(i) else |_| t.addFloat(std.fmt.parseFloat(f64, s) catch unreachable),
            .float => |f| t.addFloat(f),
            else => {},
        }
    }

    fn addInt(t: *ByteTotal, i: i128) void {
        if (t.float) |*f| {
            f.* += @floatFromInt(i);
        } else if (std.math.add(i128, t.int, i)) |sum| {
            t.int = sum;
        } else |_| {
            t.float = @as(f64, @floatFromInt(t.int)) + @as(f64, @floatFromInt(i));
        }
    }

    fn addFloat(t: *ByteTotal, f: f64) void {
        t.float = (t.float orelse @as(f64, @floatFromInt(t.int))) + f;
    }

    fn kilobytes(t: ByteTotal) f64 {
        return (t.float orelse @as(f64, @floatFromInt(t.int))) / 1024;
    }
};

/// Python '{:,.1f}'.format(value): exact round-half-even, thousands commas.
const Kilobytes = struct {
    value: f64,

    pub fn format(k: Kilobytes, w: *Io.Writer) Io.Writer.Error!void {
        const v = k.value;
        if (std.math.isNan(v)) return w.writeAll("nan");
        if (std.math.signbit(v)) try w.writeByte('-');
        if (std.math.isInf(v)) return w.writeAll("inf");
        const bits: u64 = @bitCast(v);
        const biased: i32 = @intCast((bits >> 52) & 0x7ff);
        const fraction = bits & ((@as(u64, 1) << 52) - 1);
        const mantissa: u64 = if (biased == 0) fraction else fraction | (@as(u64, 1) << 52);
        const exponent: i32 = (if (biased == 0) 1 else biased) - 1075;
        var digits_buf: [400]u8 = undefined;
        var integer_digits: []const u8 = undefined;
        var tenth: u8 = 0;
        if (exponent >= 0) {
            const whole = @as(u1100, mantissa) << @intCast(exponent);
            integer_digits = std.fmt.bufPrint(&digits_buf, "{d}", .{whole}) catch unreachable;
        } else {
            const shift: u32 = @intCast(-exponent);
            const scaled: u64 = mantissa * 10;
            var q: u64 = 0;
            if (shift < 64) {
                q = scaled >> @intCast(shift);
                const r = scaled & ((@as(u64, 1) << @intCast(shift)) - 1);
                const half = @as(u64, 1) << @intCast(shift - 1);
                if (r > half or (r == half and q & 1 == 1)) q += 1;
            }
            tenth = @intCast(q % 10);
            integer_digits = std.fmt.bufPrint(&digits_buf, "{d}", .{q / 10}) catch unreachable;
        }
        for (integer_digits, 0..) |digit, i| {
            if (i != 0 and (integer_digits.len - i) % 3 == 0) try w.writeByte(',');
            try w.writeByte(digit);
        }
        try w.print(".{d}", .{tenth});
    }
};

// ---------------------------------------------------------------------------
// Python string conversions.

/// float.__repr__ (json = false) or json.dumps float output (json = true).
const FloatRepr = struct {
    value: f64,
    json: bool,

    pub fn format(r: FloatRepr, w: *Io.Writer) Io.Writer.Error!void {
        const v = r.value;
        if (std.math.isNan(v)) return w.writeAll(if (r.json) "NaN" else "nan");
        if (std.math.isInf(v)) {
            if (v < 0) try w.writeByte('-');
            return w.writeAll(if (r.json) "Infinity" else "inf");
        }
        if (std.math.signbit(v)) try w.writeByte('-');
        if (v == 0) return w.writeAll("0.0");
        const decimal = std.fmt.float.binaryToDecimal(u64, @bitCast(@abs(v)), 52, 11, false, &std.fmt.float.Backend64_TablesFull);
        var buf: [24]u8 = undefined;
        const digits = std.fmt.bufPrint(&buf, "{d}", .{decimal.mantissa}) catch unreachable;
        const n: i32 = @intCast(digits.len);
        const point: i32 = n + decimal.exponent; // value = 0.DIGITS * 10^point
        if (point > -4 and point <= 16) {
            if (point <= 0) {
                try w.writeAll("0.");
                try w.splatByteAll('0', @intCast(-point));
                try w.writeAll(digits);
            } else if (point >= n) {
                try w.writeAll(digits);
                try w.splatByteAll('0', @intCast(point - n));
                try w.writeAll(".0");
            } else {
                try w.print("{s}.{s}", .{ digits[0..@intCast(point)], digits[@intCast(point)..] });
            }
        } else {
            try w.writeByte(digits[0]);
            if (digits.len > 1) try w.print(".{s}", .{digits[1..]});
            const e = point - 1;
            try w.print("e{c}{d:0>2}", .{ @as(u8, if (e < 0) '-' else '+'), @abs(e) });
        }
    }
};

/// json.dumps(value, sort_keys=True) (ensure_ascii) followed by Jinja's
/// htmlsafe replacements of < > & ' so the result is safe inside <script>.
const JsonFmt = struct {
    gpa: Allocator,
    value: Value,

    pub fn format(j: JsonFmt, w: *Io.Writer) Io.Writer.Error!void {
        return writeJson(j.gpa, w, j.value);
    }
};

fn writeJson(gpa: Allocator, w: *Io.Writer, v: Value) Io.Writer.Error!void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |s| try w.writeAll(s),
        .float => |f| try w.print("{f}", .{FloatRepr{ .value = f, .json = true }}),
        .string => |s| try writeJsonString(w, s),
        .array => |items| {
            try w.writeByte('[');
            for (items, 0..) |item, i| {
                if (i != 0) try w.writeAll(", ");
                try writeJson(gpa, w, item);
            }
            try w.writeByte(']');
        },
        .object => |object| {
            // Keys are WTF-8, so byte order equals Python's code point order.
            const sorted = gpa.dupe([]const u8, object.keys()) catch return error.WriteFailed;
            defer gpa.free(sorted);
            std.mem.sort([]const u8, sorted, {}, bytesLessThan);
            try w.writeByte('{');
            for (sorted, 0..) |key, i| {
                if (i != 0) try w.writeAll(", ");
                try writeJsonString(w, key);
                try w.writeAll(": ");
                try writeJson(gpa, w, object.get(key).?);
            }
            try w.writeByte('}');
        },
    }
}

fn bytesLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn writeJsonString(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) {
        const code = nextCodePoint(s, &i);
        switch (code) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            '<', '>', '&', '\'' => try w.print("\\u{x:0>4}", .{code}),
            0x20...0x21, 0x23...0x25, 0x28...0x3b, '=', 0x3f...0x5b, 0x5d...0x7e => try w.writeByte(@intCast(code)),
            0x10000...0x10ffff => {
                const offset = code - 0x10000;
                try w.print("\\u{x:0>4}\\u{x:0>4}", .{ 0xd800 + (offset >> 10), 0xdc00 + (offset & 0x3ff) });
            },
            else => try w.print("\\u{x:0>4}", .{code}),
        }
    }
    try w.writeByte('"');
}

const TextMode = enum { text, html };

/// Appends str(value) as Python renders it; in html mode the result is
/// markupsafe-escaped. Lone surrogates become U+FFFD.
fn appendPyStr(arena: Allocator, out: *std.ArrayList(u8), v: Value, mode: TextMode) !void {
    var raw: Io.Writer.Allocating = .init(arena);
    writePyStr(&raw.writer, v) catch return error.OutOfMemory;
    try appendText(arena, out, raw.written(), mode);
}

fn appendText(arena: Allocator, out: *std.ArrayList(u8), s: []const u8, mode: TextMode) !void {
    var i: usize = 0;
    while (i < s.len) {
        const start = i;
        const code = nextCodePoint(s, &i);
        if (code >= 0xd800 and code <= 0xdfff) {
            try out.appendSlice(arena, "\u{fffd}");
            continue;
        }
        if (mode == .html) switch (code) {
            '&' => {
                try out.appendSlice(arena, "&amp;");
                continue;
            },
            '<' => {
                try out.appendSlice(arena, "&lt;");
                continue;
            },
            '>' => {
                try out.appendSlice(arena, "&gt;");
                continue;
            },
            '\'' => {
                try out.appendSlice(arena, "&#39;");
                continue;
            },
            '"' => {
                try out.appendSlice(arena, "&#34;");
                continue;
            },
            else => {},
        };
        try out.appendSlice(arena, s[start..i]);
    }
}

fn writePyStr(w: *Io.Writer, v: Value) Io.Writer.Error!void {
    switch (v) {
        .string => |s| try w.writeAll(s),
        else => try writePyRepr(w, v),
    }
}

fn writePyRepr(w: *Io.Writer, v: Value) Io.Writer.Error!void {
    switch (v) {
        .null => try w.writeAll("None"),
        .bool => |b| try w.writeAll(if (b) "True" else "False"),
        .int => |s| try w.writeAll(s),
        .float => |f| try w.print("{f}", .{FloatRepr{ .value = f, .json = false }}),
        .string => |s| try writePyStringRepr(w, s),
        .array => |items| {
            try w.writeByte('[');
            for (items, 0..) |item, i| {
                if (i != 0) try w.writeAll(", ");
                try writePyRepr(w, item);
            }
            try w.writeByte(']');
        },
        .object => |object| {
            try w.writeByte('{');
            for (object.keys(), object.values(), 0..) |key, item, i| {
                if (i != 0) try w.writeAll(", ");
                try writePyStringRepr(w, key);
                try w.writeAll(": ");
                try writePyRepr(w, item);
            }
            try w.writeByte('}');
        },
    }
}

/// repr(str); non-ASCII printability is approximated (C1 controls, NBSP,
/// soft hyphen, line/paragraph separators and surrogates are escaped).
fn writePyStringRepr(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    const quote: u8 = if (std.mem.indexOfScalar(u8, s, '\'') != null and std.mem.indexOfScalar(u8, s, '"') == null) '"' else '\'';
    try w.writeByte(quote);
    var i: usize = 0;
    while (i < s.len) {
        const start = i;
        const code = nextCodePoint(s, &i);
        switch (code) {
            '\\' => try w.writeAll("\\\\"),
            '\t' => try w.writeAll("\\t"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f...0xa0, 0xad => try w.print("\\x{x:0>2}", .{code}),
            0x2028, 0x2029, 0xd800...0xdfff => try w.print("\\u{x:0>4}", .{code}),
            else => {
                if (code == quote) try w.writeByte('\\');
                try w.writeAll(s[start..i]);
            },
        }
    }
    try w.writeByte(quote);
}

// ---------------------------------------------------------------------------
// URL details: urlsplit(url).path or "/" and parse_qsl(query, keep_blank_values=True).

fn urlParts(arena: Allocator, url: Value) !Value {
    const text: []const u8 = switch (url) {
        .string => |s| s,
        // urlsplit() treats falsy non-strings as ""; truthy ones raise.
        else => if (truthy(url)) return .null else "",
    };
    const split = try splitUrl(arena, text) orelse return .null;
    var query: std.ArrayList(Value) = .empty;
    if (split.query.len != 0) {
        var fields = std.mem.splitScalar(u8, split.query, '&');
        while (fields.next()) |field| {
            if (field.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, field, '=');
            const name = if (eq) |e| field[0..e] else field;
            const value = if (eq) |e| field[e + 1 ..] else "";
            const pair = try arena.alloc(Value, 2);
            pair[0] = .{ .string = try unquotePlus(arena, name) };
            pair[1] = .{ .string = try unquotePlus(arena, value) };
            try query.append(arena, .{ .array = pair });
        }
    }
    const object = try arena.create(Object);
    object.* = .empty;
    try object.put(arena, "path", .{ .string = if (split.path.len == 0) "/" else split.path });
    try object.put(arena, "query", .{ .array = query.items });
    return .{ .object = object };
}

const SplitUrl = struct { path: []const u8, query: []const u8 };

/// urllib.parse._urlsplit (Python 3.14); null where Python raises ValueError.
fn splitUrl(arena: Allocator, raw: []const u8) !?SplitUrl {
    var start: usize = 0;
    while (start < raw.len and raw[start] <= 0x20) start += 1;
    var cleaned: std.ArrayList(u8) = .empty;
    for (raw[start..]) |c| if (c != '\t' and c != '\r' and c != '\n') try cleaned.append(arena, c);
    var url: []const u8 = cleaned.items;

    if (std.mem.indexOfScalar(u8, url, ':')) |i| {
        if (i > 0 and std.ascii.isAlphabetic(url[0])) {
            const is_scheme = for (url[0..i]) |c| {
                if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) break false;
            } else true;
            if (is_scheme) url = url[i + 1 ..];
        }
    }
    var netloc: ?[]const u8 = null;
    if (std.mem.startsWith(u8, url, "//")) {
        const delim = std.mem.indexOfAnyPos(u8, url, 2, "/?#") orelse url.len;
        const n = url[2..delim];
        url = url[delim..];
        const open = std.mem.indexOfScalar(u8, n, '[') != null;
        const close = std.mem.indexOfScalar(u8, n, ']') != null;
        if (open != close) return null;
        if (open and !bracketedNetlocIsValid(n)) return null;
        netloc = n;
    }
    if (std.mem.indexOfScalar(u8, url, '#')) |i| url = url[0..i];
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, url, '?')) |i| {
        query = url[i + 1 ..];
        url = url[0..i];
    }
    if (netloc) |n| if (!netlocSurvivesNfkc(n)) return null;
    return .{ .path = url, .query = query };
}

/// _checknetloc: these are exactly the code points whose NFKC form contains
/// one of "/?#@:" (Unicode 16.0, as shipped with Python 3.14).
fn netlocSurvivesNfkc(netloc: []const u8) bool {
    const unsafe = [_]u21{ 0x2047, 0x2048, 0x2049, 0x2100, 0x2101, 0x2105, 0x2106, 0x2a74, 0xfe13, 0xfe16, 0xfe55, 0xfe56, 0xfe5f, 0xfe6b, 0xff03, 0xff0f, 0xff1a, 0xff1f, 0xff20 };
    var i: usize = 0;
    while (i < netloc.len) {
        const code = nextCodePoint(netloc, &i);
        if (std.mem.indexOfScalar(u21, &unsafe, code) != null) return false;
    }
    return true;
}

/// _check_bracketed_netloc
fn bracketedNetlocIsValid(netloc: []const u8) bool {
    const host_port = if (std.mem.lastIndexOfScalar(u8, netloc, '@')) |at| netloc[at + 1 ..] else netloc;
    var hostname: []const u8 = undefined;
    if (std.mem.indexOfScalar(u8, host_port, '[')) |open| {
        if (open != 0) return false;
        const bracketed = host_port[1..];
        const close = std.mem.indexOfScalar(u8, bracketed, ']') orelse bracketed.len;
        hostname = bracketed[0..close];
        const port = if (close < bracketed.len) bracketed[close + 1 ..] else "";
        if (port.len != 0 and port[0] != ':') return false;
    } else {
        hostname = host_port[0 .. std.mem.indexOfScalar(u8, host_port, ':') orelse host_port.len];
    }
    // _check_bracketed_host
    if (hostname.len != 0 and (hostname[0] == 'v' or hostname[0] == 'V')) {
        var i: usize = 1;
        while (i < hostname.len and std.ascii.isHex(hostname[i])) i += 1;
        return i > 1 and i + 1 < hostname.len and hostname[i] == '.';
    }
    if (isIpv4(hostname)) return false;
    return isIpv6(hostname);
}

fn isIpv4(s: []const u8) bool {
    if (s.len == 0 or std.mem.indexOfScalar(u8, s, '/') != null) return false;
    var octets = std.mem.splitScalar(u8, s, '.');
    var count: usize = 0;
    while (octets.next()) |octet| {
        count += 1;
        if (octet.len == 0 or octet.len > 3) return false;
        for (octet) |c| if (!std.ascii.isDigit(c)) return false;
        if (octet.len > 1 and octet[0] == '0') return false;
        if ((std.fmt.parseInt(u16, octet, 10) catch return false) > 255) return false;
    }
    return count == 4;
}

fn isIpv6(address: []const u8) bool {
    if (std.mem.indexOfScalar(u8, address, '/') != null) return false;
    var s = address;
    if (std.mem.indexOfScalar(u8, s, '%')) |percent| {
        const scope = s[percent + 1 ..];
        if (scope.len == 0 or std.mem.indexOfScalar(u8, scope, '%') != null) return false;
        s = s[0..percent];
    }
    if (s.len == 0 or (std.unicode.utf8CountCodepoints(s) catch return false) > 45) return false;
    var parts_buf: [12][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, ':');
    while (it.next()) |part| {
        if (n == 10) return false; // more than 9 colons always fails
        parts_buf[n] = part;
        n += 1;
    }
    if (n < 3) return false;
    if (std.mem.indexOfScalar(u8, parts_buf[n - 1], '.') != null) {
        if (!isIpv4(parts_buf[n - 1])) return false;
        parts_buf[n - 1] = "0";
        parts_buf[n] = "0";
        n += 1;
    }
    if (n > 9) return false;
    const parts = parts_buf[0..n];
    var skip: ?usize = null;
    for (1..n - 1) |i| if (parts[i].len == 0) {
        if (skip != null) return false;
        skip = i;
    };
    var hi: usize = n;
    var lo: usize = 0;
    if (skip) |index| {
        hi = index;
        lo = n - index - 1;
        if (parts[0].len == 0) {
            hi -= 1;
            if (hi != 0) return false;
        }
        if (parts[n - 1].len == 0) {
            lo -= 1;
            if (lo != 0) return false;
        }
        if (hi + lo >= 8) return false;
    } else {
        if (n != 8 or parts[0].len == 0 or parts[n - 1].len == 0) return false;
    }
    for (parts[0..hi]) |part| if (!isHextet(part)) return false;
    for (parts[n - lo ..]) |part| if (!isHextet(part)) return false;
    return true;
}

fn isHextet(s: []const u8) bool {
    if (s.len == 0 or s.len > 4) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// unquote_plus(s, "utf-8", "replace"): only ASCII runs are percent-decoded.
fn unquotePlus(arena: Allocator, s: []const u8) ![]const u8 {
    const spaced = try arena.dupe(u8, s);
    std.mem.replaceScalar(u8, spaced, '+', ' ');
    if (std.mem.indexOfScalar(u8, spaced, '%') == null) return spaced;
    var out: std.ArrayList(u8) = .empty;
    var bytes: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < spaced.len) {
        const start = i;
        if (spaced[i] >= 0x80) {
            while (i < spaced.len and spaced[i] >= 0x80) i += 1;
            try out.appendSlice(arena, spaced[start..i]);
            continue;
        }
        while (i < spaced.len and spaced[i] < 0x80) i += 1;
        bytes.clearRetainingCapacity();
        var items = std.mem.splitScalar(u8, spaced[start..i], '%');
        try bytes.appendSlice(arena, items.first());
        while (items.next()) |item| {
            if (item.len >= 2 and std.ascii.isHex(item[0]) and std.ascii.isHex(item[1])) {
                try bytes.append(arena, std.fmt.parseInt(u8, item[0..2], 16) catch unreachable);
                try bytes.appendSlice(arena, item[2..]);
            } else {
                try bytes.append(arena, '%');
                try bytes.appendSlice(arena, item);
            }
        }
        try appendUtf8Replace(arena, &out, bytes.items);
    }
    return out.items;
}

/// bytes.decode("utf-8", "replace"): one U+FFFD per maximal invalid subpart.
fn appendUtf8Replace(arena: Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        const c = bytes[i];
        if (c < 0x80) {
            try out.append(arena, c);
            i += 1;
            continue;
        }
        const need: usize, const lo: u8, const hi: u8 = switch (c) {
            0xc2...0xdf => .{ 1, 0x80, 0xbf },
            0xe0 => .{ 2, 0xa0, 0xbf },
            0xe1...0xec, 0xee, 0xef => .{ 2, 0x80, 0xbf },
            0xed => .{ 2, 0x80, 0x9f },
            0xf0 => .{ 3, 0x90, 0xbf },
            0xf1...0xf3 => .{ 3, 0x80, 0xbf },
            0xf4 => .{ 3, 0x80, 0x8f },
            else => .{ 0, 0, 0 },
        };
        var len: usize = 1;
        while (len <= need and i + len < bytes.len) : (len += 1) {
            const b = bytes[i + len];
            const min: u8 = if (len == 1) lo else 0x80;
            const max: u8 = if (len == 1) hi else 0xbf;
            if (b < min or b > max) break;
        }
        if (need != 0 and len == need + 1) {
            try out.appendSlice(arena, bytes[i .. i + len]);
        } else {
            try out.appendSlice(arena, "\u{fffd}");
        }
        i += len;
    }
}

// ---------------------------------------------------------------------------
// HTML rendering.

const template_source = @embedFile("report/report.html");

/// Marker order in report/report.html; checked at compile time.
const marker_names = [_][]const u8{
    "begin",           "title_app",      "h1_app",         "state_attr",        "state_text",
    "package",         "started",        "flow_count",     "host_count",        "kilobytes",
    "errors",          "hosts_begin",    "host_name",      "host_max",          "host_value",
    "host_meter_text", "host_bold",      "host_end",       "hosts_empty_end",   "scope_begin",
    "scope_all_end",   "domains",        "scope_some_end", "diagnostics_empty", "diagnostics_begin",
    "diagnostic",      "diagnostic_end", "audit_json",
};

const Segments = struct {
    /// segments[i] is the static text that precedes marker_names[i].
    before: [marker_names.len][]const u8,
    tail: []const u8,
};

const segments: Segments = blk: {
    @setEvalBranchQuota(10_000_000);
    var result: Segments = undefined;
    var rest: []const u8 = template_source;
    for (marker_names, 0..) |name, i| {
        const open = std.mem.indexOf(u8, rest, "@@") orelse @compileError("report template is missing marker " ++ name);
        const close = std.mem.indexOfPos(u8, rest, open + 2, "@@") orelse @compileError("unterminated report template marker");
        if (!std.mem.eql(u8, rest[open + 2 .. close], name))
            @compileError("report template marker " ++ rest[open + 2 .. close] ++ " found where " ++ name ++ " was expected");
        result.before[i] = rest[0..open];
        rest = rest[close + 2 ..];
    }
    if (std.mem.indexOf(u8, rest, "@@") != null) @compileError("unexpected trailing report template marker");
    result.tail = rest;
    break :blk result;
};

fn before(comptime name: []const u8) []const u8 {
    inline for (marker_names, 0..) |candidate, i| {
        if (comptime std.mem.eql(u8, candidate, name)) return segments.before[i];
    }
    @compileError("unknown report template marker " ++ name);
}

const ReportData = struct {
    metadata: *Object,
    flows: []*Object,
    diagnostics: []const Value,
    host_counts: []const HostCount,
    max_host_count: usize,
    errors: usize,
    kilobytes: f64,
};

fn requiredField(metadata: *Object, name: []const u8) !Value {
    return metadata.get(name) orelse error.MissingMetadataField;
}

fn renderHtml(arena: Allocator, data: ReportData) ![]const u8 {
    const metadata = data.metadata;
    const app = try requiredField(metadata, "app");
    const state = try requiredField(metadata, "state");
    const started = try requiredField(metadata, "started");
    const domains = try requiredField(metadata, "domains");

    var out: std.ArrayList(u8) = .empty;
    const H = struct {
        fn static(o: *std.ArrayList(u8), a: Allocator, comptime name: []const u8) !void {
            try o.appendSlice(a, before(name));
        }
    };
    // Static template text and dynamic values are appended in order; nothing
    // appended to `out` is ever scanned for markers.
    try H.static(&out, arena, "title_app");
    try appendPyStr(arena, &out, app, .html);
    try H.static(&out, arena, "h1_app");
    try appendPyStr(arena, &out, app, .html);
    try H.static(&out, arena, "state_attr");
    try appendPyStr(arena, &out, state, .html);
    try H.static(&out, arena, "state_text");
    try appendPyStr(arena, &out, state, .html);
    try H.static(&out, arena, "package");
    try appendPyStr(arena, &out, metadata.get("package") orelse .{ .string = "" }, .html);
    try H.static(&out, arena, "started");
    try appendPyStr(arena, &out, started, .html);
    try H.static(&out, arena, "flow_count");
    try out.print(arena, "{d}", .{data.flows.len});
    try H.static(&out, arena, "host_count");
    try out.print(arena, "{d}", .{data.host_counts.len});
    try H.static(&out, arena, "kilobytes");
    try out.print(arena, "{f}", .{Kilobytes{ .value = data.kilobytes }});
    try H.static(&out, arena, "errors");
    try out.print(arena, "{d}", .{data.errors});

    try H.static(&out, arena, "hosts_begin");
    for (data.host_counts) |host| {
        try H.static(&out, arena, "host_name");
        try appendPyStr(arena, &out, host.host, .html);
        try H.static(&out, arena, "host_max");
        try out.print(arena, "{d}", .{data.max_host_count});
        try H.static(&out, arena, "host_value");
        try out.print(arena, "{d}", .{host.count});
        try H.static(&out, arena, "host_meter_text");
        try out.print(arena, "{d}", .{host.count});
        try H.static(&out, arena, "host_bold");
        try out.print(arena, "{d}", .{host.count});
        try H.static(&out, arena, "host_end");
    }
    if (data.host_counts.len == 0) try H.static(&out, arena, "hosts_empty_end");

    try H.static(&out, arena, "scope_begin");
    if (domains == .null) {
        try H.static(&out, arena, "scope_all_end");
    } else {
        try H.static(&out, arena, "domains");
        try appendDomains(arena, &out, domains);
        try H.static(&out, arena, "scope_some_end");
    }

    try H.static(&out, arena, "diagnostics_empty");
    try out.appendSlice(arena, if (data.diagnostics.len != 0) "false" else "true");
    try H.static(&out, arena, "diagnostics_begin");
    for (data.diagnostics) |diagnostic| {
        try H.static(&out, arena, "diagnostic");
        try appendPyStr(arena, &out, diagnostic, .html);
        try H.static(&out, arena, "diagnostic_end");
    }

    try H.static(&out, arena, "audit_json");
    const payload = try arena.create(Object);
    payload.* = .empty;
    const flow_values = try arena.alloc(Value, data.flows.len);
    for (flow_values, data.flows) |*value, flow| value.* = .{ .object = flow };
    try payload.put(arena, "flows", .{ .array = flow_values });
    try payload.put(arena, "metadata", .{ .object = metadata });
    try out.print(arena, "{f}", .{JsonFmt{ .gpa = arena, .value = .{ .object = payload } }});
    try out.appendSlice(arena, segments.tail);
    return out.items;
}

/// metadata.domains|join(' · ') with autoescape.
fn appendDomains(arena: Allocator, out: *std.ArrayList(u8), domains: Value) !void {
    const separator = " \u{b7} ";
    switch (domains) {
        .array => |items| for (items, 0..) |item, i| {
            if (i != 0) try out.appendSlice(arena, separator);
            try appendPyStr(arena, out, item, .html);
        },
        .object => |object| for (object.keys(), 0..) |key, i| {
            if (i != 0) try out.appendSlice(arena, separator);
            try appendText(arena, out, key, .html);
        },
        .string => |s| {
            var i: usize = 0;
            while (i < s.len) {
                if (i != 0) try out.appendSlice(arena, separator);
                const start = i;
                _ = nextCodePoint(s, &i);
                try appendText(arena, out, s[start..i], .html);
            }
        },
        else => return error.InvalidDomains,
    }
}

// ---------------------------------------------------------------------------
// Tests exercise generate() and inspect the artifacts it writes.

const testing = std.testing;

const TestSession = struct {
    tmp: testing.TmpDir,
    path: []const u8,

    fn init(session_json: []const u8, events: ?[]const u8) !TestSession {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "session.json", .data = session_json });
        if (events) |e| try tmp.dir.writeFile(testing.io, .{ .sub_path = "events.jsonl", .data = e });
        const path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(s: *TestSession) void {
        testing.allocator.free(s.path);
        s.tmp.cleanup();
    }

    fn read(s: *TestSession, name: []const u8) ![]u8 {
        return s.tmp.dir.readFileAlloc(testing.io, name, testing.allocator, .unlimited);
    }

    /// Runs generate() and returns report.html contents.
    fn generateReport(s: *TestSession) ![]u8 {
        const path = try generate(testing.allocator, testing.io, s.path);
        defer testing.allocator.free(path);
        const expected = try std.fs.path.join(testing.allocator, &.{ s.path, "report.html" });
        defer testing.allocator.free(expected);
        try testing.expectEqualStrings(expected, path);
        return s.read("report.html");
    }
};

/// Parses the embedded audit-data JSON with std.json for independent checks.
fn auditData(report: []const u8) !std.json.Parsed(std.json.Value) {
    const open = "<script type=\"application/json\" id=\"audit-data\">";
    const start = (std.mem.indexOf(u8, report, open) orelse return error.TestMissingAuditData) + open.len;
    const end = std.mem.indexOfPos(u8, report, start, "</script>") orelse return error.TestMissingAuditData;
    return std.json.parseFromSlice(std.json.Value, testing.allocator, report[start..end], .{});
}

test "report summarizes latest unique requests per host with corruption diagnostics" {
    const events =
        \\{"id": "first", "host": "assets.test", "started": 10, "response": null, "error": null}
        \\{"id": "first", "host": "assets.test", "started": 10, "response": {"status": 200, "bytes": 1280}, "error": null}
        \\{"id": "http-error", "host": "api.test", "started": 20, "response": {"status": 503, "bytes": 256}, "error": null}
        \\{"id": "transport-error", "host": "api.test", "started": 30, "response": null, "error": "connection reset"}
        \\{"id": "pending", "host": "api.test", "started": 40, "response": null, "error": null}
        \\{"id": "subdomain", "host": "sub.api.test", "started": 50, "response": null, "error": null}
        \\{"diagnostic": "TLS client failure for api.test"}
        \\{"id":
    ;
    var session = try TestSession.init(
        \\{"app": "Summary contract", "domains": ["assets.test", "api.test", "*.api.test"], "started": "2026-10-10T10:00:00Z", "state": "interrupted"}
    , events);
    defer session.deinit();
    const report = try session.generateReport();
    defer testing.allocator.free(report);

    const summary = try session.read("report.txt");
    defer testing.allocator.free(summary);
    try testing.expectEqualStrings(
        "Requests per domain:\napi.test: 3\nassets.test: 1\nsub.api.test: 1\nTotal requests: 5\n",
        summary,
    );
    // Captured events are left untouched.
    const captured = try session.read("events.jsonl");
    defer testing.allocator.free(captured);
    try testing.expectEqualStrings(events, captured);

    try testing.expect(std.mem.indexOf(u8, report, "<title>Summary contract \u{b7} Network audit</title>") != null);
    try testing.expect(std.mem.indexOf(u8, report, "<strong>5</strong><span>HTTP exchanges</span>") != null);
    try testing.expect(std.mem.indexOf(u8, report, "<strong>3</strong><span>Matched hosts</span>") != null);
    // (1280 + 256) / 1024 = 1.5 KB; 4 of 5 exchanges are errors or incomplete.
    try testing.expect(std.mem.indexOf(u8, report, "<strong>1.5 KB</strong") != null);
    try testing.expect(std.mem.indexOf(u8, report, "<strong>4</strong><span>HTTP errors / incomplete</span>") != null);
    try testing.expect(std.mem.indexOf(u8, report, "<span>api.test</span>\n                <meter min=\"0\" max=\"3\" value=\"3\"\n                  >3</meter\n                >\n                <b>3</b>") != null);
    try testing.expect(std.mem.indexOf(u8, report, "<p class=\"mono\">assets.test \u{b7} api.test \u{b7} *.api.test</p>") != null);
    try testing.expect(std.mem.indexOf(u8, report, "data-empty=\"false\"\n      >\n        \n        <p>TLS client failure for api.test</p>\n        \n        <p>Unreadable capture record at line 8 (possibly interrupted write)</p>\n        \n      </section>") != null);

    var data = try auditData(report);
    defer data.deinit();
    const flows = data.value.object.get("flows").?.array.items;
    const expected_ids = [_][]const u8{ "first", "http-error", "transport-error", "pending", "subdomain" };
    try testing.expectEqual(expected_ids.len, flows.len);
    for (expected_ids, flows) |id, flow| try testing.expectEqualStrings(id, flow.object.get("id").?.string);
    // The latest record for an ID wins.
    try testing.expectEqual(@as(i64, 200), flows[0].object.get("response").?.object.get("status").?.integer);
    try testing.expectEqualStrings("Summary contract", data.value.object.get("metadata").?.object.get("app").?.string);
}

test "event recovery keeps latest state in stable start-time order" {
    var session = try TestSession.init(
        \\{"app": "Order", "domains": null, "started": "s", "state": "complete"}
    ,
        "{\"id\": \"late\", \"host\": \"b.test\", \"started\": 20, \"response\": null, \"error\": null}\n" ++
            "{\"id\": \"early\", \"host\": \"a.test\", \"started\": 10, \"response\": null, \"error\": null}\n" ++
            "{\"id\": \"tie\", \"host\": \"a.test\", \"started\": 20.0, \"response\": null, \"error\": null}\n" ++
            "{\"id\":\r\n" ++
            "\n" ++
            "{\"diagnostic\": \"TLS server failure\"}\n" ++
            "{\"id\": \"early\", \"host\": \"a.test\", \"started\": 10, \"response\": {\"status\": 503}, \"error\": null}\n",
    );
    defer session.deinit();
    const report = try session.generateReport();
    defer testing.allocator.free(report);

    var data = try auditData(report);
    defer data.deinit();
    const flows = data.value.object.get("flows").?.array.items;
    try testing.expectEqual(@as(usize, 3), flows.len);
    try testing.expectEqualStrings("early", flows[0].object.get("id").?.string);
    try testing.expectEqual(@as(i64, 503), flows[0].object.get("response").?.object.get("status").?.integer);
    try testing.expectEqualStrings("late", flows[1].object.get("id").?.string); // equal start: first seen wins
    try testing.expectEqualStrings("tie", flows[2].object.get("id").?.string);
    try testing.expect(std.mem.indexOf(u8, report, "<p>Unreadable capture record at line 4 (possibly interrupted write)</p>\n        \n        <p>Unreadable capture record at line 5 (possibly interrupted write)</p>\n        \n        <p>TLS server failure</p>") != null);
    try testing.expect(std.mem.indexOf(u8, report, "<p class=\"mono\">All HTTP(S) requests</p>") != null);

    const summary = try session.read("report.txt");
    defer testing.allocator.free(summary);
    try testing.expectEqualStrings("Requests per domain:\na.test: 2\nb.test: 1\nTotal requests: 3\n", summary);
}

test "report parses paths and ordered query pairs like urllib" {
    const urls = [_][]const u8{
        "https://api.test/a/../items%2Fspecial;v=1?q=red+shoes&tag=first&tag=second&empty=&flag&=unnamed&&encoded=%252F%2B%26%3D&na%20me=%C3%BC&html=%3C%2Fscript%3E%3Cimg+src%3Dx%3E#ignored=fragment",
        "https://api.test",
        "https://api.test/health?",
        "https://api.test/?bad=%ZZ&utf8=%FF&trunc=%E2%82&pair=%F0%9F%98%80",
        "https://[invalid/path?x=1",
        "https://[::1]:8443/v6?a=1",
        "https://[127.0.0.1]/v4-in-brackets",
        " \thttps://api.test/p\na\tth?x=1",
    };
    var events: std.ArrayList(u8) = .empty;
    defer events.deinit(testing.allocator);
    for (urls, 0..) |url, i| {
        var url_json: Io.Writer.Allocating = .init(testing.allocator);
        defer url_json.deinit();
        try std.json.Stringify.value(url, .{}, &url_json.writer);
        try events.print(testing.allocator, "{{\"id\": \"{d}\", \"host\": \"api.test\", \"url\": {s}, \"started\": {d}, \"response\": null, \"error\": null}}\n", .{ i, url_json.written(), i });
    }
    var session = try TestSession.init(
        \\{"app": "URL details", "domains": ["api.test"], "started": "2026-10-10T10:00:00Z", "state": "complete"}
    , events.items);
    defer session.deinit();
    const report = try session.generateReport();
    defer testing.allocator.free(report);
    try testing.expect(std.mem.indexOf(u8, report, "</script><img") == null);

    var data = try auditData(report);
    defer data.deinit();
    const flows = data.value.object.get("flows").?.array.items;
    try testing.expectEqual(urls.len, flows.len);
    for (urls, flows) |url, flow| try testing.expectEqualStrings(url, flow.object.get("url").?.string);

    const Expected = struct { path: []const u8, query: []const [2][]const u8 };
    const expected = [_]?Expected{
        .{ .path = "/a/../items%2Fspecial;v=1", .query = &.{
            .{ "q", "red shoes" },    .{ "tag", "first" },    .{ "tag", "second" },
            .{ "empty", "" },         .{ "flag", "" },        .{ "", "unnamed" },
            .{ "encoded", "%2F+&=" }, .{ "na me", "\u{fc}" }, .{ "html", "</script><img src=x>" },
        } },
        .{ .path = "/", .query = &.{} },
        .{ .path = "/health", .query = &.{} },
        .{ .path = "/", .query = &.{ .{ "bad", "%ZZ" }, .{ "utf8", "\u{fffd}" }, .{ "trunc", "\u{fffd}" }, .{ "pair", "\u{1f600}" } } },
        null,
        .{ .path = "/v6", .query = &.{.{ "a", "1" }} },
        null,
        .{ .path = "/path", .query = &.{.{ "x", "1" }} },
    };
    for (expected, flows) |maybe, flow| {
        const parts = flow.object.get("url_parts").?;
        const want = maybe orelse {
            try testing.expect(parts == .null);
            continue;
        };
        try testing.expectEqualStrings(want.path, parts.object.get("path").?.string);
        const query = parts.object.get("query").?.array.items;
        try testing.expectEqual(want.query.len, query.len);
        for (want.query, query) |pair, got| {
            try testing.expectEqual(@as(usize, 2), got.array.items.len);
            try testing.expectEqualStrings(pair[0], got.array.items[0].string);
            try testing.expectEqualStrings(pair[1], got.array.items[1].string);
        }
    }
    // Python json.dumps(ensure_ascii=True) + htmlsafe escaping in the raw report.
    try testing.expect(std.mem.indexOf(u8, report, "[\"html\", \"\\u003c/script\\u003e\\u003cimg src=x\\u003e\"]") != null);
    try testing.expect(std.mem.indexOf(u8, report, "[\"na me\", \"\\u00fc\"]") != null);
    try testing.expect(std.mem.indexOf(u8, report, "[\"pair\", \"\\ud83d\\ude00\"]") != null);
    try testing.expect(std.mem.indexOf(u8, report, "\"url_parts\": null") != null);
}

test "empty and interrupted reports escape network data and never expand markers" {
    var session = try TestSession.init(
        \\{"app": "<img src=x onerror=alert(1)>@@DATA@@ @@h1_app@@ {{ app }}", "domains": ["example.test"], "started": "2026-10-10T10:00:00Z", "state": "fail\"ed'", "failure": "</script><script>alert(1)</script>", "note": "\udc80 & '"}
    , null);
    defer session.deinit();
    const report = try session.generateReport();
    defer testing.allocator.free(report);
    try testing.expect(std.mem.indexOf(u8, report, "<h1>&lt;img src=x onerror=alert(1)&gt;@@DATA@@ @@h1_app@@ {{ app }}</h1>") != null);
    try testing.expect(std.mem.indexOf(u8, report, "data-state=\"fail&#34;ed&#39;\"") != null);
    try testing.expect(std.mem.indexOf(u8, report, "<script>alert(1)</script>") == null);
    try testing.expect(std.mem.indexOf(u8, report, "<p>&lt;/script&gt;&lt;script&gt;alert(1)&lt;/script&gt;</p>") != null);
    try testing.expect(std.mem.indexOf(u8, report, "{\"flows\": [], \"metadata\": {\"app\": \"\\u003cimg src=x onerror=alert(1)\\u003e@@DATA@@ @@h1_app@@ {{ app }}\", \"domains\": [\"example.test\"], \"failure\": \"\\u003c/script\\u003e\\u003cscript\\u003ealert(1)\\u003c/script\\u003e\", \"note\": \"\\udc80 \\u0026 \\u0027\", \"started\"") != null);
    try testing.expect(std.mem.indexOf(u8, report, "No matching HTTP exchanges captured.") != null);
    try testing.expect(std.mem.indexOf(u8, report, "<li class=\"empty-hosts\">No matched hosts</li>") != null);
    try testing.expect(std.mem.indexOf(u8, report, "<strong>0.0 KB</strong") != null);
    try testing.expect(std.mem.endsWith(u8, report, "</script>\n  </body>\n</html>\n"));

    const summary = try session.read("report.txt");
    defer testing.allocator.free(summary);
    try testing.expectEqualStrings("Requests per domain:\nNo matching HTTP requests captured.\nTotal requests: 0\n", summary);

    try session.tmp.dir.writeFile(testing.io, .{ .sub_path = "events.jsonl", .data = "{\"id\":" });
    const interrupted = try session.generateReport();
    defer testing.allocator.free(interrupted);
    try testing.expect(std.mem.indexOf(u8, interrupted, "<p>Unreadable capture record at line 1 (possibly interrupted write)</p>") != null);
}

test "host counts and totals follow Python value semantics" {
    // IDs 1, 1.0 and true are one dict key; hosts 1.0 and 1 count together
    // under the first seen spelling while the string "1" stays separate.
    var session = try TestSession.init(
        \\{"app": "Hosts", "domains": "ab", "started": 1.5e-7, "state": "complete", "package": 12345678901234567890123}
    ,
        \\{"id": 1, "host": "x&y", "started": 3, "response": {"status": 404, "bytes": 1048576}, "error": null}
        \\{"id": 1.0, "host": "x\u0026y", "started": 3, "response": {"status": 404, "bytes": 512}, "error": null}
        \\{"id": "1", "host": 1, "started": 2, "response": {"status": 302, "bytes": 0}, "error": ""}
        \\{"id": true, "host": "x&y", "started": 1, "response": {"status": 200, "bytes": 1023999232}, "error": null}
        \\{"id": "b", "host": 1.0, "started": 0, "response": {}, "error": null}
        \\{"id": "c", "host": "1", "started": 4, "response": null, "error": null}
        \\
    );
    defer session.deinit();
    const report = try session.generateReport();
    defer testing.allocator.free(report);

    const summary = try session.read("report.txt");
    defer testing.allocator.free(summary);
    try testing.expectEqualStrings("Requests per domain:\n1.0: 2\nx&y: 1\n1: 1\nTotal requests: 4\n", summary);
    // 1023999232 / 1024 = 999999.25, rounded half-even like Python.
    try testing.expect(std.mem.indexOf(u8, report, "<strong>999,999.2 KB</strong") != null);
    try testing.expect(std.mem.indexOf(u8, report, "<strong>2</strong><span>HTTP errors / incomplete</span>") != null);
    try testing.expect(std.mem.indexOf(u8, report, "<span>x&amp;y</span>\n                <meter min=\"0\" max=\"2\" value=\"1\"") != null);
    try testing.expect(std.mem.indexOf(u8, report, "<span>1.0</span>\n                <meter min=\"0\" max=\"2\" value=\"2\"") != null);
    try testing.expect(std.mem.indexOf(u8, report, "<p class=\"mono\">a \u{b7} b</p>") != null);
    try testing.expect(std.mem.indexOf(u8, report, "<span class=\"mono muted\">12345678901234567890123</span\n          ><span class=\"mono muted\">1.5e-07</span>") != null);
    try testing.expect(std.mem.indexOf(u8, report, "\"started\": 1.5e-07") != null);

    var data = try auditData(report);
    defer data.deinit();
    const flows = data.value.object.get("flows").?.array.items;
    try testing.expectEqual(@as(usize, 4), flows.len);
    try testing.expect(flows[1].object.get("id").?.bool);
}
