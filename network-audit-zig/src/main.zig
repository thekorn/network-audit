//! Experimental native audit orchestration. The Python CLI stays independent.
const std = @import("std");
const runtime = @import("runtime.zig");
const Runtime = runtime.Runtime;
const config = @import("config.zig");
const android = @import("android.zig");
const recording = @import("recording.zig");
const scenario = @import("scenario.zig");
const report = @import("report.zig");
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) void {
    _ = std.c.umask(0o077);
    runtime.installSignalHandlers();
    defer runtime.uninstallSignalHandlers();
    var rt: Runtime = .{ .allocator = init.gpa, .io = init.io, .environ = init.environ_map };
    const code = dispatch(&rt, init) catch |err| blk: {
        if (err == error.Interrupted) break :blk @as(u8, 130);
        std.debug.print("network-audit-zig: {s}\n", .{errorDetail(&rt, err)});
        break :blk @as(u8, 1);
    };
    std.process.exit(code);
}

fn errorDetail(rt: *Runtime, err: anyerror) []const u8 {
    return switch (err) {
        error.Failed, error.CommandFailed, error.CommandTimeout => rt.detail(),
        else => @errorName(err),
    };
}

fn print(rt: *Runtime, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(rt.io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

fn dispatch(rt: *Runtime, init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    // Configuration is immutable after preflight and lives for the whole run;
    // process polling uses the GPA so repeated ADB output is actually freed.
    var config_rt: Runtime = .{ .allocator = a, .io = rt.io, .environ = rt.environ };
    const options = config.parse(&config_rt, args[1..]) catch |err| {
        rt.setDetail("{s}", .{config_rt.detail()});
        return err;
    };
    if (options.show_help) {
        try print(rt, "{s}", .{config.help});
        return 0;
    }
    if (options.report) |path| {
        const session = try config.absolute(&config_rt, path);
        try printReports(rt, session, false);
        return 0;
    }
    const assets = rt.environ.get("NETWORK_AUDIT_ASSETS") orelse "network-audit";
    const codec = rt.environ.get("NETWORK_AUDIT_ZIG_CONFIG") orelse "network-audit-zig/scenario_config.py";
    const runner = rt.environ.get("NETWORK_AUDIT_SCENARIO_RUNNER") orelse try std.fs.path.join(a, &.{ assets, "mobilewright", "runner.mjs" });
    const resolved = config.resolve(&config_rt, options, assets, codec, runner) catch |err| {
        rt.setDetail("{s}", .{config_rt.detail()});
        return err;
    };
    return audit(rt, a, resolved, assets, runner);
}

fn timestamp(a: Allocator, io: std.Io, compact: bool) ![]const u8 {
    const now = std.Io.Timestamp.now(io, .real);
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divTrunc(@max(now.nanoseconds, 0), std.time.ns_per_s)) };
    const year = epoch.getEpochDay().calculateYearDay();
    const date = year.calculateMonthDay();
    const time = epoch.getDaySeconds();
    return if (compact)
        std.fmt.allocPrint(a, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z-", .{ year.year, date.month.numeric(), @as(u8, date.day_index) + 1, time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute() })
    else
        std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ year.year, date.month.numeric(), @as(u8, date.day_index) + 1, time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute() });
}

const Metadata = struct {
    app: []const u8,
    package: []const u8,
    // null is meaningful here: no domain filter. Do not omit it on serialization.
    domains: ?[]const []const u8,
    started: []const u8,
    state: []const u8 = "starting",
    body_limit: u64,
    close_grace: f64,
    scenario: ?[]const u8 = null,
    executor: ?[]const u8 = null,
    scenario_timeout: ?f64 = null,
    device: ?[]const u8 = null,
    ended: ?[]const u8 = null,
    failure: ?[]const u8 = null,
    recording: ?[]const u8 = null,
    recording_failure: ?[]const u8 = null,

    fn save(self: Metadata, rt: *Runtime, session: []const u8) !void {
        const path = try rt.path(&.{ session, "session.json" });
        defer rt.allocator.free(path);
        const json = try std.json.Stringify.valueAlloc(rt.allocator, self, .{ .whitespace = .indent_2 });
        defer rt.allocator.free(json);
        try rt.write(path, json);
    }
};

fn buildApk(rt: *Runtime, a: Allocator, options: config.Options) ![]const u8 {
    const app = options.app.?;
    if (!options.is_project) return app;
    if (!rt.isFile(try std.fs.path.join(a, &.{ app, "pubspec.lock" }))) return rt.fail("Flutter projects must have a committed pubspec.lock", .{});
    var command: std.ArrayList([]const u8) = .empty;
    if (options.use_fvm) try command.append(a, "fvm");
    try command.appendSlice(a, &.{ "flutter", "pub", "get", "--enforce-lockfile" });
    try rt.command(command.items, app);
    command.shrinkRetainingCapacity(if (options.use_fvm) 2 else 1);
    try command.appendSlice(a, &.{ "build", "apk", "--debug", "--no-pub" });
    if (options.flavor) |flavor| try command.appendSlice(a, &.{ "--flavor", flavor });
    for (options.define_files) |file| try command.append(a, try std.fmt.allocPrint(a, "--dart-define-from-file={s}", .{file}));
    try rt.command(command.items, app);
    const name = if (options.flavor) |flavor| try std.fmt.allocPrint(a, "app-{s}-debug.apk", .{try std.ascii.allocLowerString(a, flavor)}) else "app-debug.apk";
    return std.fs.path.join(a, &.{ app, "build/app/outputs/flutter-apk", name });
}

fn audit(rt: *Runtime, a: Allocator, options: config.Options, assets: []const u8, runner: []const u8) !u8 {
    const image = try android.checkEmulator(rt);
    defer rt.allocator.free(image);
    const apk = try buildApk(rt, a, options);
    const identity = try android.apkIdentity(rt, apk);
    defer identity.deinit(rt.allocator);
    try rt.makeDir(options.output);
    const relative_session = try rt.tempDir(options.output, try timestamp(a, rt.io, true));
    defer rt.allocator.free(relative_session);
    const session = try config.absolute(rt, relative_session);
    defer rt.allocator.free(session);
    var metadata: Metadata = .{
        .app = std.fs.path.basename(options.app.?),
        .package = identity.package,
        .domains = options.domains,
        .started = try timestamp(a, rt.io, false),
        .body_limit = options.body_limit,
        .close_grace = options.close_grace,
        .scenario = options.scenario,
        .executor = options.executor,
        .scenario_timeout = if (options.scenario != null) options.scenario_timeout else null,
    };
    try metadata.save(rt, session);
    try print(rt, "Session: {s}\nCapturing: {s}\nSensitive data: headers and bodies are not redacted. Keep reports private.\n", .{
        session, if (options.domains) |domains| try std.mem.join(a, ", ", domains) else "all HTTP(S) requests",
    });
    if (options.headless) try print(rt, "Running headless (no emulator window). Use ADB to interact, or press Ctrl+C to finish.\n", .{});

    var capture: Capture = .{ .rt = rt, .arena = a, .session = session, .metadata = &metadata };
    capture.run(options, assets, runner, image, apk, identity) catch |err| {
        if (err == error.Interrupted) {
            metadata.state = "interrupted by user";
        } else {
            metadata.state = "failed";
            metadata.failure = a.dupe(u8, errorDetail(rt, err)) catch @errorName(err);
        }
    };
    // Keep the original failure before cleanup can overwrite Runtime.detail.
    runtime.shield();
    defer runtime.unshield();
    capture.close();
    metadata.ended = try timestamp(a, rt.io, false);
    try metadata.save(rt, session);
    try printReports(rt, session, true);
    if (metadata.recording != null) try print(rt, "Video: {s}/recording.mp4\n", .{session});
    if (metadata.failure) |failure| return rt.fail("{s}", .{failure});
    return if (options.scenario != null and std.mem.eql(u8, metadata.state, "interrupted by user")) 130 else 0;
}

const Capture = struct {
    rt: *Runtime,
    arena: Allocator,
    session: []const u8,
    metadata: *Metadata,
    temporary: ?[]const u8 = null,
    proxy: ?runtime.Child = null,
    emulator: ?android.Emulator = null,
    video: ?recording.ScreenRecording = null,
    certificate: []const u8 = "",
    ready_file: []const u8 = "",

    fn run(self: *Capture, options: config.Options, assets: []const u8, runner: []const u8, image: []const u8, apk: []const u8, identity: android.Identity) !void {
        const rt = self.rt;
        const a = self.arena;
        self.temporary = try rt.tempDir(rt.tempRoot(), "network-audit-zig-");
        const port = try runtime.freePort(rt);
        const ca = try std.fs.path.join(a, &.{ self.temporary.?, "ca" });
        self.certificate = try std.fs.path.join(a, &.{ ca, "mitmproxy-ca-cert.pem" });
        self.ready_file = try std.fs.path.join(a, &.{ self.session, "proxy.ready" });
        const log = try rt.createLog(try std.fs.path.join(a, &.{ self.session, "proxy.log" }));
        defer log.close(rt.io);
        var env = try rt.environ.clone(rt.allocator);
        defer env.deinit();
        try env.put("NETWORK_AUDIT_SESSION", self.session);
        try env.put("NETWORK_AUDIT_DOMAINS", try std.json.Stringify.valueAlloc(a, options.domains, .{}));
        try env.put("NETWORK_AUDIT_BODY_LIMIT", try std.fmt.allocPrint(a, "{d}", .{options.body_limit}));
        self.proxy = try runtime.Child.spawn(rt, .{
            .argv = &.{
                "mitmdump",               "--listen-host",                                 "127.0.0.1",                                                                                  "--listen-port", try std.fmt.allocPrint(a, "{d}", .{port}),
                "--set",                  try std.fmt.allocPrint(a, "confdir={s}", .{ca}), "--set",                                                                                      "flow_detail=0", "--set",
                "termlog_verbosity=warn", "--set",                                         try std.fmt.allocPrint(a, "allow_hosts={s}", .{try config.proxyPattern(a, options.domains)}), "-s",            try std.fs.path.join(a, &.{ assets, "capture.py" }),
            },
            .environ = &env,
            .stderr = .{ .file = log },
        });
        try rt.waitFor("mitmproxy", 30, 0.1, self);
        self.emulator = try android.Emulator.init(rt, self.temporary.?, self.session, port, options.headless, image, options.dimensions);
        const emulator = &self.emulator.?;
        try print(rt, "Booting a disposable Android API 36 emulator…\n", .{});
        try emulator.start();
        try emulator.installCa(self.certificate);
        self.metadata.device = try a.dupe(u8, emulator.serial);
        try self.metadata.save(rt, self.session);
        if (options.record) {
            self.video = try recording.ScreenRecording.init(emulator, self.session);
            try self.video.?.start();
            try print(rt, "Recording the emulator screen (no audio).\n", .{});
        }
        try emulator.launch(apk, identity.package, identity.activity);
        try rt.waitFor("app in foreground", 30, 1, Foreground{ .capture = self, .package = identity.package });
        self.metadata.state = "capturing";
        try self.metadata.save(rt, self.session);
        if (options.executor) |executor| {
            try print(rt, "Running scenario on {s}: {s}\nScenario log: {s}/scenario.log\n", .{ emulator.serial, options.scenario.?, self.session });
            try scenario.run(rt, .{
                .runner = runner,
                .executor = executor,
                .serial = emulator.serial,
                .device_id = emulator.deviceId(),
                .package = identity.package,
                .session = self.session,
                .timeout = options.scenario_timeout,
                .health = .{ .context = self, .function = healthCallback },
            });
            self.metadata.state = "scenario completed";
        } else {
            try print(rt, "App running on {s}. Close/leave the app for {d}s, or press Ctrl+C to finish.\n", .{ emulator.serial, options.close_grace });
            var absent: ?f64 = null;
            while (true) {
                try runtime.checkInterrupt();
                if (!self.proxy.?.running()) return rt.fail("mitmdump stopped unexpectedly; see proxy.log", .{});
                if (!emulator.running()) {
                    self.metadata.state = "emulator closed";
                    return;
                }
                if (self.video) |*video| try video.check();
                if (try emulator.foreground(identity.package)) {
                    absent = null;
                } else if (absent) |since| {
                    if (rt.now() - since >= options.close_grace) {
                        self.metadata.state = "app closed";
                        return;
                    }
                } else absent = rt.now();
                try rt.sleep(1);
            }
        }
    }

    pub fn ready(self: *Capture) !bool {
        if (!self.proxy.?.running()) return self.rt.fail("mitmdump exited; see proxy.log", .{});
        return self.rt.exists(self.certificate) and self.rt.exists(self.ready_file);
    }

    fn healthCallback(context: ?*anyopaque) !void {
        const self: *Capture = @ptrCast(@alignCast(context.?));
        if (!self.proxy.?.running()) return self.rt.fail("mitmdump stopped unexpectedly; see proxy.log", .{});
        if (!self.emulator.?.running()) return self.rt.fail("Emulator stopped during scenario; see emulator.log", .{});
        if (self.video) |*video| try video.check();
    }

    const Foreground = struct {
        capture: *Capture,
        package: []const u8,
        pub fn ready(self: Foreground) !bool {
            try healthCallback(self.capture);
            return self.capture.emulator.?.foreground(self.package);
        }
    };

    fn close(self: *Capture) void {
        if (self.video) |*video| {
            if (video.stop()) |path| {
                if (path != null) self.metadata.recording = "recording.mp4";
            } else |err| {
                const failure = std.fmt.allocPrint(self.arena, "Could not save recording: {s}", .{errorDetail(self.rt, err)}) catch "Could not save recording";
                self.metadata.recording_failure = failure;
                if (self.metadata.failure == null) {
                    self.metadata.failure = failure;
                    self.metadata.state = "failed";
                }
                std.debug.print("{s}\n", .{failure});
            }
            video.deinit();
        }
        if (self.emulator) |*emulator| {
            emulator.close();
            emulator.deinit();
        }
        if (self.proxy) |*proxy| _ = proxy.stop(.{ .signal = .INT, .grace = 15, .term_grace = 5 });
        if (self.temporary) |temporary| {
            self.rt.removeTree(temporary);
            self.rt.allocator.free(temporary);
        }
    }
};

fn printReports(rt: *Runtime, session: []const u8, from_audit: bool) !void {
    const path = try report.generate(rt.allocator, rt.io, session);
    defer rt.allocator.free(path);
    const summary_path = try rt.path(&.{ session, "report.txt" });
    defer rt.allocator.free(summary_path);
    const summary = try rt.read(summary_path);
    defer rt.allocator.free(summary);
    try print(rt, "{s}{s}\nText report: {s}\n", .{ if (from_audit) "\nReport: " else "", path, summary_path });
    if (from_audit) try print(rt, "Raw flows: {s}/flows.mitm\n", .{session});
    try print(rt, "\n{s}", .{summary});
}

test {
    _ = config;
    _ = android;
    _ = recording;
    _ = scenario;
    _ = report;
}
