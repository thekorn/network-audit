//! CLI/configuration policy; TOML and JSON Schema are decoded by a small codec.
const std = @import("std");
const builtin = @import("builtin");
const Runtime = @import("runtime.zig").Runtime;
const android = @import("android.zig");

pub const help =
    \\Usage: network-audit-zig APP [options]
    \\       network-audit-zig report SESSION
    \\
    \\Experimental Zig 0.17 Android HTTP(S) audit. Python remains the default CLI.
    \\APP is a Flutter project with pubspec.lock, or an Android APK.
    \\
    \\  --domain HOST                 Repeatable exact hostname or '*.example.com'
    \\  --scenario FILE.toml          Trusted Mobilewright scenario (omitted domains = all)
    \\  --scenario-timeout SECONDS    Maximum scenario duration (default: 300)
    \\  --output DIRECTORY            Private sessions (default: .network-audit/runs)
    \\  --headless                    Hide emulator (automatic without DISPLAY on Linux)
    \\  --dimensions big              1280x2856 at 480 dpi; overrides scenario dimensions
    \\  --record                      Save a silent recording.mp4 beside the report
    \\  --use-fvm                     Build with 'fvm flutter' (ignored for APKs)
    \\  --flavor IDENTIFIER           Flutter flavor; overrides scenario flavor
    \\  --dart-define-from-file PATH   Flutter config files; repeatable/comma-separated
    \\  --close-grace SECONDS         Finish after app leaves foreground (default: 5)
    \\  --body-limit BYTES            Preview limit (default: 1048576)
    \\  --help, -h                    Show this help
    \\
    \\Requires Apple Silicon macOS or x86_64 Linux with /dev/kvm; never emulate in an orb.
    \\Reports contain unredacted cookies, tokens and bodies. Keep them private.
    \\
;

// Configuration and path values live in the caller's command-lifetime arena.
pub const Options = struct {
    app: ?[]const u8 = null,
    report: ?[]const u8 = null,
    show_help: bool = false,
    output: []const u8 = ".network-audit/runs",
    domains: ?[]const []const u8 = null,
    scenario: ?[]const u8 = null,
    executor: ?[]const u8 = null,
    dimensions: ?android.Dimensions = null,
    flavor: ?[]const u8 = null,
    define_files: []const []const u8 = &.{},
    use_fvm: bool = false,
    headless: bool = false,
    record: bool = false,
    scenario_timeout: f64 = 300,
    close_grace: f64 = 5,
    body_limit: u64 = 1048576,
    is_project: bool = false,
};

pub fn parse(rt: *Runtime, args: []const []const u8) !Options {
    const display: []const u8 = rt.environ.get("DISPLAY") orelse "";
    var result: Options = .{ .headless = builtin.os.tag == .linux and display.len == 0 };
    var domains: std.ArrayList([]const u8) = .empty;
    var defines: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    const report = args.len > 0 and std.mem.eql(u8, args[0], "report");
    if (report) i = 1;
    var positional_only = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!positional_only and std.mem.eql(u8, arg, "--")) {
            positional_only = true;
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
            result.show_help = true;
            return result;
        }
        if (!positional_only and std.mem.startsWith(u8, arg, "-")) {
            if (report) return rt.fail("Unexpected report option: {s}", .{arg});
            const equal = std.mem.findScalar(u8, arg, '=');
            const key = arg[0 .. equal orelse arg.len];
            const flags = .{ "--headless", "--record", "--use-fvm" };
            var flag = false;
            inline for (flags, .{ "headless", "record", "use_fvm" }) |name, field| {
                if (std.mem.eql(u8, key, name)) {
                    if (equal != null) return rt.fail("{s} does not take a value", .{key});
                    @field(result, field) = true;
                    flag = true;
                }
            }
            if (flag) continue;
            const value = if (equal) |at| arg[at + 1 ..] else blk: {
                i += 1;
                if (i == args.len) return rt.fail("Missing value for {s}", .{key});
                break :blk args[i];
            };
            if (std.mem.eql(u8, key, "--domain")) {
                try domains.append(rt.allocator, value);
            } else if (std.mem.eql(u8, key, "--dart-define-from-file")) {
                var files = std.mem.splitScalar(u8, value, ',');
                while (files.next()) |file| try defines.append(rt.allocator, file);
            } else if (std.mem.eql(u8, key, "--output")) {
                result.output = value;
            } else if (std.mem.eql(u8, key, "--scenario")) {
                result.scenario = value;
            } else if (std.mem.eql(u8, key, "--flavor")) {
                result.flavor = value;
            } else if (std.mem.eql(u8, key, "--dimensions")) {
                result.dimensions = android.dimensionShortcut(value) orelse return rt.fail("Unknown dimensions shortcut: {s}; choose big", .{value});
            } else if (std.mem.eql(u8, key, "--body-limit")) {
                result.body_limit = std.fmt.parseInt(u64, value, 10) catch return rt.fail("--body-limit must be positive", .{});
                if (result.body_limit == 0) return rt.fail("--body-limit must be positive", .{});
            } else if (std.mem.eql(u8, key, "--close-grace")) {
                result.close_grace = try positive(rt, key, value);
            } else if (std.mem.eql(u8, key, "--scenario-timeout")) {
                result.scenario_timeout = try positive(rt, key, value);
            } else return rt.fail("Unknown option: {s}", .{key});
        } else if (result.app == null) {
            result.app = arg;
        } else return rt.fail("Unexpected argument: {s}", .{arg});
    }
    if (result.app == null) return rt.fail("Missing {s}; use --help for usage", .{if (report) "session directory" else "Flutter project or APK"});
    if (report) {
        result.report = result.app;
        return result;
    }
    if (domains.items.len > 0) result.domains = domains.items;
    result.define_files = defines.items;
    return result;
}

fn positive(rt: *Runtime, key: []const u8, value: []const u8) !f64 {
    const number = std.fmt.parseFloat(f64, value) catch return rt.fail("{s} must be positive and finite", .{key});
    if (!std.math.isFinite(number) or number <= 0) return rt.fail("{s} must be positive and finite", .{key});
    return number;
}

pub fn absolute(rt: *Runtime, path: []const u8) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(rt.io, rt.allocator);
    defer rt.allocator.free(cwd);
    return std.fs.path.resolve(rt.allocator, &.{ cwd, path });
}

pub fn normalizeDomains(rt: *Runtime, values: []const []const u8) ![]const []const u8 {
    if (values.len == 0) return rt.fail("No domains configured. Use --domain or --scenario <name>.toml.", .{});
    var result: std.ArrayList([]const u8) = .empty;
    for (values) |value| {
        const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, value, &std.ascii.whitespace), ".");
        const domain = try std.ascii.allocLowerString(rt.allocator, trimmed);
        const host = if (std.mem.startsWith(u8, domain, "*.")) domain[2..] else domain;
        if (host.len == 0) return rt.fail("Invalid domain: {s}", .{value});
        var labels = std.mem.splitScalar(u8, host, '.');
        while (labels.next()) |label| {
            if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-')
                return rt.fail("Invalid domain: {s}; use a hostname or *.hostname", .{value});
            for (label) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return rt.fail("Invalid domain: {s}", .{value});
        }
        const duplicate = for (result.items) |existing| {
            if (std.mem.eql(u8, existing, domain)) break true;
        } else false;
        if (!duplicate) try result.append(rt.allocator, domain);
    }
    return result.items;
}

pub fn proxyPattern(a: std.mem.Allocator, domains: ?[]const []const u8) ![]const u8 {
    if (domains == null) return "(?i)^.*\\.?(?::\\d+)?$";
    var result: std.ArrayList(u8) = .empty;
    try result.appendSlice(a, "(?i)^(?:");
    for (domains.?, 0..) |domain, i| {
        if (i > 0) try result.append(a, '|');
        const wildcard = std.mem.startsWith(u8, domain, "*.");
        if (wildcard) try result.appendSlice(a, "(?:[^.:]+\\.)+");
        for (if (wildcard) domain[2..] else domain) |c| {
            if (c == '.' or c == '-') try result.append(a, '\\');
            try result.append(a, c);
        }
    }
    try result.appendSlice(a, ")\\.?(?::\\d+)?$");
    return result.items;
}

/// Validate before any build, proxy, session or emulator is created.
pub fn resolve(rt: *Runtime, options: Options, assets: []const u8, codec: []const u8, runner: []const u8) !Options {
    var result = options;
    result.app = try absolute(rt, options.app.?);
    const stat = std.Io.Dir.cwd().statFile(rt.io, result.app.?, .{}) catch return rt.fail("App not found: {s}", .{result.app.?});
    result.is_project = stat.kind == .directory;
    var env_file: ?[]const u8 = null;
    if (options.scenario) |file| {
        result.scenario = try absolute(rt, file);
        if (!rt.isFile(result.scenario.?) or !std.mem.endsWith(u8, file, ".toml")) return rt.fail("Scenario must be an existing .toml file: {s}", .{file});
        const json = try rt.run(&.{ rt.environ.get("NETWORK_AUDIT_PYTHON") orelse "python3", codec, result.scenario.?, try rt.path(&.{ assets, "scenario.schema.json" }) }, null, 30);
        const parsed = try std.json.parseFromSlice(std.json.Value, rt.allocator, json, .{ .allocate = .alloc_always });
        const root = parsed.value.object;
        const base = std.fs.path.dirname(result.scenario.?).?;
        result.executor = try std.fs.path.resolve(rt.allocator, &.{ base, root.get("executor").?.string });
        if (root.get("domains")) |values| {
            var domains: std.ArrayList([]const u8) = .empty;
            for (values.array.items) |value| try domains.append(rt.allocator, value.string);
            result.domains = try normalizeDomains(rt, domains.items);
        }
        if (root.get("env-file")) |value| env_file = try std.fs.path.resolve(rt.allocator, &.{ base, value.string });
        if (options.flavor == null) if (root.get("flavor")) |value| {
            result.flavor = value.string;
        };
        if (options.dimensions == null) if (root.get("dimensions")) |value| {
            result.dimensions = if (value == .string) android.dimensionShortcut(value.string).? else .{
                .width = try dimension(rt, value.object.get("width").?),
                .height = try dimension(rt, value.object.get("height").?),
                .density = try dimension(rt, value.object.get("density").?),
            };
        };
        const executor = result.executor.?;
        if (!rt.isFile(executor) or !(std.mem.endsWith(u8, executor, ".js") or std.mem.endsWith(u8, executor, ".mjs")))
            return rt.fail("Executor must be an existing .js or .mjs file: {s}", .{executor});
        _ = try rt.run(&.{ "node", runner, "--check" }, null, 30);
        var syntax = try rt.capture(.{ .argv = &.{ "node", "--check", executor }, .timeout = 30 });
        defer syntax.deinit(rt.allocator);
        if (!syntax.success()) return rt.fail("Invalid executor syntax: {s}\n{s}", .{ executor, syntax.stderr });
    }
    if (options.domains) |domains| {
        result.domains = try normalizeDomains(rt, domains);
    } else if (result.scenario == null) {
        result.domains = try normalizeDomains(rt, &.{});
    }
    if (result.flavor) |flavor| {
        if (std.mem.trim(u8, flavor, &std.ascii.whitespace).len == 0) return rt.fail("--flavor must be a non-blank identifier", .{});
        if (!result.is_project) return rt.fail("Flavor configuration requires a Flutter project, not an APK", .{});
    }
    var defines: std.ArrayList([]const u8) = .empty;
    for (options.define_files) |file| try defines.append(rt.allocator, try absolute(rt, file));
    if (defines.items.len == 0) if (env_file) |file| {
        try defines.append(rt.allocator, file);
    };
    if (defines.items.len > 0 and !result.is_project) return rt.fail("Dart define configuration requires a Flutter project, not an APK", .{});
    for (defines.items) |file| if (!rt.isFile(file)) return rt.fail("Dart define file not found or not a file: {s}", .{file});
    result.define_files = defines.items;
    return result;
}

fn dimension(rt: *Runtime, value: std.json.Value) !u32 {
    const number: f64 = switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        else => return rt.fail("Display dimensions exceed the supported 32-bit range", .{}),
    };
    if (number > std.math.maxInt(u32)) return rt.fail("Display dimensions exceed the supported 32-bit range", .{});
    return @intFromFloat(number);
}

test "CLI preserves repeated values, equals arguments and rejects invalid limits" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    var rt: Runtime = .{ .allocator = arena.allocator(), .io = std.testing.io, .environ = &env };
    const options = try parse(&rt, &.{ "app dir", "--domain=EXAMPLE.test", "--domain", "*.example.test", "--dart-define-from-file=a.json,b.env", "--record", "--close-grace=0.2" });
    try std.testing.expectEqualStrings("app dir", options.app.?);
    try std.testing.expectEqual(@as(usize, 2), options.domains.?.len);
    try std.testing.expectEqualStrings("b.env", options.define_files[1]);
    try std.testing.expect(options.record);
    try std.testing.expectEqual(@as(f64, 0.2), options.close_grace);
    for ([_][]const u8{ "0", "-1", "nan", "inf" }) |invalid| try std.testing.expectError(error.Failed, parse(&rt, &.{ "app", "--scenario-timeout", invalid }));
    try std.testing.expectError(error.Failed, parse(&rt, &.{ "app", "--dimensions", "small" }));
    try std.testing.expectError(error.Failed, parse(&rt, &.{ "report", "session", "extra" }));
    const normalized = try normalizeDomains(&rt, &.{ " Example.TEST. ", "*.example.test", "example.test" });
    try std.testing.expectEqual(@as(usize, 2), normalized.len);
    try std.testing.expectEqualStrings("(?i)^(?:example\\.test|(?:[^.:]+\\.)+example\\.test)\\.?(?::\\d+)?$", try proxyPattern(rt.allocator, normalized));
    for ([_][]const u8{ "https://example.test", "bad..test", "-bad.test", "a:443" }) |invalid| try std.testing.expectError(error.Failed, normalizeDomains(&rt, &.{invalid}));
}
