//! Run a trusted Mobilewright scenario executor against the owned emulator.
//! Native port of `run_scenario`/`stop_group` in network-audit/scenario.py.
//! Scenario configuration parsing lives elsewhere.

const std = @import("std");
const runtime = @import("runtime.zig");
const Runtime = runtime.Runtime;
const Child = runtime.Child;

/// Called about every 200 ms while the scenario runs (e.g. proxy, emulator,
/// and recording liveness). Return an error (with `rt.fail`) to abort.
pub const HealthCheck = struct {
    context: ?*anyopaque = null,
    function: ?*const fn (context: ?*anyopaque) anyerror!void = null,

    fn call(self: HealthCheck) !void {
        if (self.function) |function| try function(self.context);
    }
};

pub const Options = struct {
    /// mobilewright/runner.mjs (or NETWORK_AUDIT_SCENARIO_RUNNER).
    runner: []const u8,
    /// Validated executor module.
    executor: []const u8,
    serial: []const u8,
    device_id: []const u8,
    package: []const u8,
    /// Session directory; scenario.log is written here.
    session: []const u8,
    /// Seconds for the whole scenario, including daemon startup.
    timeout: f64,
    health: HealthCheck = .{},
    node: []const u8 = "node",
    /// Parent of the private MOBILECLI_HOME; keep it short because the daemon
    /// socket path must fit a Unix socket address (also on macOS).
    home_parent: []const u8 = "/tmp",
};

const Monitor = struct {
    rt: *Runtime,
    options: *const Options,
    daemon: *Child,
    deadline: f64,
    socket: []const u8,

    fn check(self: *Monitor) !void {
        try self.options.health.call();
        try runtime.checkInterrupt();
        if (!self.daemon.running()) return self.rt.fail("Mobilecli daemon stopped; see scenario.log", .{});
        if (self.rt.now() >= self.deadline)
            return self.rt.fail("Scenario timed out after {d}s; see scenario.log", .{self.options.timeout});
    }

    pub fn ready(self: *Monitor) !bool {
        try self.check();
        return self.rt.exists(self.socket);
    }
};

/// Run the executor with a private foreground mobilecli daemon (instead of
/// mobilecli's detached auto-started one). Both run in their own process
/// groups and are always stopped, including descendants, before this
/// returns; interrupts are ignored during that teardown. Errors:
/// `error.Failed` (timeout, non-zero exit, daemon loss; see `rt.detail()`),
/// `error.Interrupted`, or whatever the health check returned.
pub fn run(rt: *Runtime, options: Options) !void {
    const deadline = rt.now() + options.timeout;
    const binary = try rt.run(&.{ options.node, options.runner, "--check" }, null, 30);
    defer rt.allocator.free(binary);

    const home = try rt.tempDir(options.home_parent, "na-mw-");
    defer rt.allocator.free(home);
    defer rt.removeTree(home);
    const socket = try rt.path(&.{ home, "daemon.sock" });
    defer rt.allocator.free(socket);
    const log_path = try rt.path(&.{ options.session, "scenario.log" });
    defer rt.allocator.free(log_path);
    const log = try rt.createLog(log_path);
    defer log.close(rt.io);
    var environ = try rt.environ.clone(rt.allocator);
    defer environ.deinit();
    try environ.put("MOBILECLI_HOME", home);

    var daemon = try Child.spawn(rt, .{
        .argv = &.{ binary, "daemon", "start", "--idle-timeout", "0" },
        .environ = &environ,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
    });
    var scenario: ?Child = null;
    var monitor: Monitor = .{ .rt = rt, .options = &options, .daemon = &daemon, .deadline = deadline, .socket = socket };

    const outcome = body(rt, &options, &monitor, &scenario, &environ, log);
    // Cleanup may itself fail to spawn the replacement-daemon stopper. Preserve
    // the original scenario diagnostic, not only its Zig error tag.
    var detail: [8192]u8 = undefined;
    const detail_len = rt.detail().len;
    @memcpy(detail[0..detail_len], rt.detail());
    const cleaned = teardown(rt, binary, socket, &environ, log, &daemon, &scenario, if (outcome) |_| true else |_| false);
    outcome catch |err| {
        rt.setDetail("{s}", .{detail[0..detail_len]});
        return err;
    };
    try cleaned;
}

fn body(
    rt: *Runtime,
    options: *const Options,
    monitor: *Monitor,
    scenario: *?Child,
    environ: *const std.process.Environ.Map,
    log: std.Io.File,
) !void {
    try rt.waitFor("Mobilecli daemon", @min(options.timeout, 10), 0.1, monitor);
    scenario.* = try Child.spawn(rt, .{
        .argv = &.{ options.node, options.runner, options.executor, options.serial, options.device_id, options.package, options.session },
        .environ = environ,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
    });
    while (true) {
        try monitor.check();
        if (scenario.*.?.poll()) |term| switch (term) {
            .exited => |code| {
                if (code == 0) return;
                return rt.fail("Scenario exited with status {d}; see scenario.log", .{code});
            },
            .signal => |sig| return rt.fail("Scenario exited with status -{d}; see scenario.log", .{@backingInt(sig)}),
            else => return rt.fail("Scenario exited unexpectedly; see scenario.log", .{}),
        };
        try rt.sleep(0.2);
    }
}

/// Stop the scenario group, then the daemon group (foreground mobilecli
/// runs its SIGTERM shutdown hooks, including the on-device helper). If a
/// replacement daemon took over our private socket, stop it through that
/// socket only. Sets a message only when `report` (no earlier failure).
fn teardown(
    rt: *Runtime,
    binary: []const u8,
    socket: []const u8,
    environ: *const std.process.Environ.Map,
    log: std.Io.File,
    daemon: *Child,
    scenario: *?Child,
    report: bool,
) !void {
    runtime.shield();
    defer runtime.unshield();
    if (scenario.*) |*process| _ = process.stop(.{ .grace = 5 });
    _ = daemon.stop(.{ .grace = 15 });
    if (!rt.exists(socket)) return;
    var stopper = Child.spawn(rt, .{
        .argv = &.{ binary, "daemon", "stop" },
        .environ = environ,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
    }) catch |err| return if (report) err else {};
    const term = stopper.wait(15);
    _ = stopper.stop(.{ .grace = 0 });
    if (term == null or !term.?.success()) {
        if (report) return rt.fail("Could not stop the replacement Mobilecli daemon; see scenario.log", .{});
    }
}

// ------------------------------------------------------------- tests

const testing = std.testing;

// `node` is replaced by `sh` and the runner by a shell script; mobilecli is
// a fake foreground daemon. Real processes, groups, and signals.
const fake_runner =
    \\if [ "$1" = --check ]; then echo "$FAKE_MOBILECLI"; exit 0; fi
    \\executor=$1 serial=$2 device=$3 package=$4 session=$5
    \\echo "runner $serial $device $package"
    \\. "$executor"
    \\
;

const fake_mobilecli =
    \\#!/bin/sh
    \\home=$MOBILECLI_HOME
    \\case "$1 $2" in
    \\"daemon start")
    \\  [ "$3 $4" = "--idle-timeout 0" ] || exit 7
    \\  echo $$ > "$home/daemon.pid"
    \\  trap 'echo daemon terminated; [ -n "$FAKE_KEEP_SOCKET" ] || rm -f "$home/daemon.sock"; exit 0' TERM
    \\  [ -n "$FAKE_DAEMON_EXIT" ] && { : > "$home/daemon.sock"; sleep "$FAKE_DAEMON_EXIT"; exit 1; }
    \\  : > "$home/daemon.sock"
    \\  while :; do sleep 0.05; done;;
    \\"daemon stop") echo "daemon stop via private socket"; rm -f "$home/daemon.sock";;
    \\*) exit 9;;
    \\esac
    \\
;

const hanging_executor =
    \\sh -c 'trap "" TERM; while :; do sleep 0.05; done' &
    \\echo $! > "$session/child.pid"
    \\echo "$MOBILECLI_HOME" > "$session/home"
    \\cp "$MOBILECLI_HOME/daemon.pid" "$session/daemon.pid"
    \\echo "scenario is hanging"
    \\while :; do sleep 0.05; done
    \\
;

const Harness = struct {
    f: runtime.testing.Fixture,
    base: []u8,
    runner: []u8,
    executor: []u8,
    ambient: []u8,

    fn init(self: *Harness, executor: []const u8) !void {
        try self.f.init();
        const rt = &self.f.rt;
        self.base = try rt.tempDir(rt.tempRoot(), "na-scenario-test-");
        self.runner = try rt.path(&.{ self.base, "runner.sh" });
        try rt.write(self.runner, fake_runner);
        self.executor = try rt.path(&.{ self.base, "executor.sh" });
        try rt.write(self.executor, executor);
        self.ambient = try rt.path(&.{ self.base, "unrelated-mobilecli" });
        try rt.makeDir(self.ambient);
        const mobilecli = try rt.path(&.{ self.base, "mobilecli" });
        defer rt.allocator.free(mobilecli);
        try runtime.testing.script(rt, mobilecli, fake_mobilecli);
        try self.f.map.put("FAKE_MOBILECLI", mobilecli);
        try self.f.map.put("MOBILECLI_HOME", self.ambient);
    }

    fn deinit(self: *Harness) void {
        const rt = &self.f.rt;
        rt.removeTree(self.base);
        for ([_][]u8{ self.base, self.runner, self.executor, self.ambient }) |p| rt.allocator.free(p);
        self.f.deinit();
    }

    fn options(self: *Harness, timeout: f64) Options {
        return .{
            .runner = self.runner,
            .executor = self.executor,
            .serial = "not-a-device",
            .device_id = "test-avd",
            .package = "test.app",
            .session = self.base,
            .timeout = timeout,
            .node = "sh",
        };
    }

    fn file(self: *Harness, name: []const u8) ![]u8 {
        const rt = &self.f.rt;
        const p = try rt.path(&.{ self.base, name });
        defer rt.allocator.free(p);
        return rt.read(p);
    }

    fn pid(self: *Harness, name: []const u8) !std.posix.pid_t {
        const text = try self.file(name);
        defer self.f.rt.allocator.free(text);
        return std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, text, " \n"), 10);
    }

    fn ambientEmpty(self: *Harness) !bool {
        var dir = try std.Io.Dir.cwd().openDir(self.f.rt.io, self.ambient, .{ .iterate = true });
        defer dir.close(self.f.rt.io);
        var it = dir.iterate();
        return (try it.next(self.f.rt.io)) == null;
    }
};

test "timeout stops the scenario's TERM-ignoring child and the private daemon" {
    var h: Harness = undefined;
    try h.init(hanging_executor);
    defer h.deinit();
    const rt = &h.f.rt;
    const started = rt.now();
    try testing.expectError(error.Failed, run(rt, h.options(2)));
    try testing.expect(std.mem.find(u8, rt.detail(), "Scenario timed out after 2s; see scenario.log") != null);
    try testing.expect(rt.now() - started < 10);

    const home = try h.file("home");
    defer rt.allocator.free(home);
    const home_path = std.mem.trim(u8, home, " \n");
    try testing.expect(!std.mem.eql(u8, home_path, h.ambient));
    try testing.expect(std.mem.startsWith(u8, home_path, "/tmp/na-mw-"));
    try testing.expect(!rt.exists(home_path));
    try testing.expect(try h.ambientEmpty());
    try testing.expect(!runtime.testing.alive(try h.pid("child.pid")));
    try testing.expect(!runtime.testing.alive(try h.pid("daemon.pid")));
    const log = try h.file("scenario.log");
    defer rt.allocator.free(log);
    try testing.expect(std.mem.find(u8, log, "scenario is hanging") != null);
    try testing.expect(std.mem.find(u8, log, "runner not-a-device test-avd test.app") != null);
    try testing.expect(std.mem.find(u8, log, "daemon terminated") != null);
}

test "completion, failure status, daemon loss, health, and replacement daemon" {
    {
        var h: Harness = undefined;
        try h.init("echo done\n");
        defer h.deinit();
        try run(&h.f.rt, h.options(20));
        const log = try h.file("scenario.log");
        defer h.f.rt.allocator.free(log);
        const done = std.mem.find(u8, log, "done\n") orelse return error.TestUnexpectedResult;
        try testing.expect(std.mem.find(u8, log[done..], "daemon terminated") != null);
        try testing.expect(std.mem.find(u8, log, "daemon stop") == null);
    }
    {
        var h: Harness = undefined;
        try h.init("rm -- \"$FAKE_MOBILECLI\"\nexit 3\n");
        defer h.deinit();
        try h.f.map.put("FAKE_KEEP_SOCKET", "1");
        try testing.expectError(error.Failed, run(&h.f.rt, h.options(20)));
        try testing.expectEqualStrings("Scenario exited with status 3; see scenario.log", h.f.rt.detail());
    }
    {
        var h: Harness = undefined;
        try h.init("while :; do sleep 0.05; done\n");
        defer h.deinit();
        try h.f.map.put("FAKE_DAEMON_EXIT", "0.5");
        try testing.expectError(error.Failed, run(&h.f.rt, h.options(20)));
        try testing.expectEqualStrings("Mobilecli daemon stopped; see scenario.log", h.f.rt.detail());
    }
    {
        var h: Harness = undefined;
        try h.init("while :; do sleep 0.05; done\n");
        defer h.deinit();
        const Health = struct {
            rt: *Runtime,
            calls: usize = 0,
            fn check(context: ?*anyopaque) anyerror!void {
                const self: *@This() = @ptrCast(@alignCast(context.?));
                self.calls += 1;
                if (self.calls > 3) return self.rt.fail("Emulator stopped during scenario; see emulator.log", .{});
            }
        };
        var health: Health = .{ .rt = &h.f.rt };
        var options = h.options(20);
        options.health = .{ .context = &health, .function = Health.check };
        try testing.expectError(error.Failed, run(&h.f.rt, options));
        try testing.expectEqualStrings("Emulator stopped during scenario; see emulator.log", h.f.rt.detail());
    }
    {
        var h: Harness = undefined;
        try h.init("echo done\n");
        defer h.deinit();
        try h.f.map.put("FAKE_KEEP_SOCKET", "1");
        try run(&h.f.rt, h.options(20));
        const log = try h.file("scenario.log");
        defer h.f.rt.allocator.free(log);
        try testing.expect(std.mem.find(u8, log, "daemon stop via private socket") != null);
    }
}

test "interrupt stops both groups and reports Interrupted" {
    var h: Harness = undefined;
    try h.init(hanging_executor);
    defer h.deinit();
    const rt = &h.f.rt;
    const Health = struct {
        rt: *Runtime,
        base: []const u8,
        fn check(context: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const marker = try self.rt.path(&.{ self.base, "daemon.pid" });
            defer self.rt.allocator.free(marker);
            if (self.rt.exists(marker)) runtime.requestInterrupt();
        }
    };
    var health: Health = .{ .rt = rt, .base = h.base };
    var options = h.options(20);
    options.health = .{ .context = &health, .function = Health.check };
    defer runtime.clearInterrupt();
    try testing.expectError(error.Interrupted, run(rt, options));
    try testing.expect(!runtime.testing.alive(try h.pid("child.pid")));
    try testing.expect(!runtime.testing.alive(try h.pid("daemon.pid")));
}
