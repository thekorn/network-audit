//! Native process, filesystem, clock, and signal runtime shared by the audit
//! modules. Errors that need a human-readable explanation return one of
//! `Error` and store the message in `Runtime.detail()`.
//!
//! Ownership: every slice returned by a `Runtime` method that allocates is
//! owned by the caller and must be released with `rt.allocator.free`.
//! `env` is the exception: it borrows from the environment map.
//!
//! Signals: call `installSignalHandlers` once at startup. SIGINT/SIGTERM only
//! set an async-signal-safe flag. Polling loops (`sleep`, `run`, `command`,
//! `waitFor`) then return `error.Interrupted` so the caller can stop owned
//! processes and save a partial report. Inside a `shield()`/`unshield()` pair
//! (used by every teardown in this port), interrupts are not reported, which
//! means repeated Ctrl+C cannot abort cleanup. The flag is sticky.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Io = std.Io;
const Environ = std.process.Environ;

pub const Term = std.process.Child.Term;

/// `Failed`: an error with a message in `Runtime.detail()`.
/// `CommandFailed`: a captured command exited unsuccessfully (message set).
/// `CommandTimeout`: a captured command exceeded its timeout and its process
/// group was killed (message set).
/// `Interrupted`: SIGINT/SIGTERM was received outside a shield.
pub const Error = error{ Failed, CommandFailed, CommandTimeout, Interrupted };

/// Upper bound for captured stdout/stderr of one command (each stream).
pub const default_output_limit: usize = 32 * 1024 * 1024;

// ---------------------------------------------------------------- signals

var interrupt_flag = std.atomic.Value(bool).init(false);
var shield_depth = std.atomic.Value(u32).init(0);

fn onSignal(sig: posix.SIG) callconv(.c) void {
    _ = sig;
    interrupt_flag.store(true, .seq_cst);
}

var previous_int: posix.Sigaction = undefined;
var previous_term: posix.Sigaction = undefined;

/// Route SIGINT and SIGTERM to the interrupt flag. Uses SA_RESTART, so
/// unrelated blocking calls continue; owned polling loops observe the flag
/// within about 100 ms. Because the signals are caught (not ignored),
/// spawned children start with default dispositions even when this process
/// inherited SIG_IGN, so device recorders and daemons can still be
/// stopped gracefully.
pub fn installSignalHandlers() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(.INT, &act, &previous_int);
    posix.sigaction(.TERM, &act, &previous_term);
}

/// Restore the dispositions saved by `installSignalHandlers`.
pub fn uninstallSignalHandlers() void {
    posix.sigaction(.INT, &previous_int, null);
    posix.sigaction(.TERM, &previous_term, null);
}

/// True once SIGINT/SIGTERM was received (or `requestInterrupt` was called).
pub fn interrupted() bool {
    return interrupt_flag.load(.seq_cst);
}

/// Set the interrupt flag programmatically (tests, or main's own policy).
pub fn requestInterrupt() void {
    interrupt_flag.store(true, .seq_cst);
}

/// Clear the interrupt flag. Intended for tests.
pub fn clearInterrupt() void {
    interrupt_flag.store(false, .seq_cst);
}

/// Suppress `error.Interrupted` until the matching `unshield`. Nestable.
pub fn shield() void {
    _ = shield_depth.fetchAdd(1, .seq_cst);
}

pub fn unshield() void {
    _ = shield_depth.fetchSub(1, .seq_cst);
}

/// Return `error.Interrupted` if a signal arrived and no shield is active.
pub fn checkInterrupt() error{Interrupted}!void {
    if (interrupted() and shield_depth.load(.seq_cst) == 0) return error.Interrupted;
}

// ---------------------------------------------------------------- pids

fn pollPid(pid: posix.pid_t) ?Term {
    var status: c_int = 0;
    while (true) {
        const rc = std.c.waitpid(pid, &status, @intCast(std.c.W.NOHANG));
        if (rc == 0) return null;
        if (rc == pid) return Io.Threaded.statusToTerm(@bitCast(status));
        switch (std.c.errno(rc)) {
            .INTR => continue,
            // Already reaped elsewhere; never wait on an unknown pid again.
            else => return .{ .unknown = 0 },
        }
    }
}

fn reapPid(pid: posix.pid_t) Term {
    var status: c_int = 0;
    while (true) {
        const rc = std.c.waitpid(pid, &status, 0);
        if (rc == pid) return Io.Threaded.statusToTerm(@bitCast(status));
        switch (std.c.errno(rc)) {
            .INTR => continue,
            else => return .{ .unknown = 0 },
        }
    }
}

fn sendSignal(pid: posix.pid_t, group: bool, sig: posix.SIG) void {
    // ESRCH/EPERM are expected when the target is already gone.
    _ = std.c.kill(if (group) -pid else pid, sig);
}

// ---------------------------------------------------------------- runtime

pub const Capture = struct {
    term: Term,
    stdout: []u8,
    stderr: []u8,

    pub fn success(self: Capture) bool {
        return self.term.success();
    }

    pub fn deinit(self: *Capture, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub const CaptureOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    /// Seconds for the whole command, including output collection.
    timeout: f64 = 60,
    /// Written to stdin, which is then closed. Otherwise stdin is /dev/null.
    input: ?[]const u8 = null,
    /// Child environment; defaults to `Runtime.environ`. Also used for PATH.
    environ: ?*const Environ.Map = null,
    output_limit: usize = default_output_limit,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: Io,
    environ: *Environ.Map,
    detail_buffer: [8192]u8 = undefined,
    detail_len: usize = 0,

    // ------------------------------------------------------------ messages

    /// The message for the most recent `Error` returned by this runtime.
    pub fn detail(self: *const Runtime) []const u8 {
        return self.detail_buffer[0..self.detail_len];
    }

    /// Record a message (truncated at 8 KiB) and return `error.Failed`.
    pub fn fail(self: *Runtime, comptime fmt: []const u8, args: anytype) error{Failed} {
        self.setDetail(fmt, args);
        return error.Failed;
    }

    pub fn setDetail(self: *Runtime, comptime fmt: []const u8, args: anytype) void {
        var writer: Io.Writer = .fixed(&self.detail_buffer);
        writer.print(fmt, args) catch {};
        self.detail_len = writer.end;
    }

    // ------------------------------------------------------------ clock

    /// Monotonic seconds.
    pub fn now(self: *Runtime) f64 {
        const ts = Io.Timestamp.now(self.io, .awake);
        return @as(f64, @floatFromInt(ts.nanoseconds)) / std.time.ns_per_s;
    }

    /// Sleep in short slices; returns `error.Interrupted` (outside a shield).
    pub fn sleep(self: *Runtime, seconds: f64) error{Interrupted}!void {
        const deadline = self.now() + seconds;
        while (true) {
            try checkInterrupt();
            const remaining = deadline - self.now();
            if (remaining <= 0) return;
            self.pause(@min(remaining, 0.1));
        }
    }

    /// Uninterruptible short sleep, for teardown.
    fn pause(self: *Runtime, seconds: f64) void {
        if (seconds <= 0) return;
        const ns: i96 = @intFromFloat(seconds * std.time.ns_per_s);
        self.io.sleep(.fromNanoseconds(ns), .awake) catch {};
    }

    // ------------------------------------------------------------ files

    /// Read a whole file (up to 256 MiB). Caller frees.
    pub fn read(self: *Runtime, path_: []const u8) ![]u8 {
        return Io.Dir.cwd().readFileAlloc(self.io, path_, self.allocator, .limited(256 * 1024 * 1024)) catch |err|
            self.fail("Could not read {s}: {t}", .{ path_, err });
    }

    /// Create or truncate a file with `data`.
    pub fn write(self: *Runtime, path_: []const u8, data: []const u8) !void {
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path_, .data = data }) catch |err|
            return self.fail("Could not write {s}: {t}", .{ path_, err });
    }

    /// Create or truncate a file for a child's output. Caller closes it with
    /// `file.close(rt.io)`; spawned children keep their own descriptor.
    pub fn createLog(self: *Runtime, path_: []const u8) !Io.File {
        return Io.Dir.cwd().createFile(self.io, path_, .{}) catch |err|
            self.fail("Could not create {s}: {t}", .{ path_, err });
    }

    /// Join path components. Caller frees.
    pub fn path(self: *Runtime, parts: []const []const u8) ![]u8 {
        return std.fs.path.join(self.allocator, parts);
    }

    /// Borrowed value of an environment variable, or `error.Failed`.
    pub fn env(self: *Runtime, name: []const u8) ![]const u8 {
        return self.environ.get(name) orelse self.fail("Missing environment variable {s}", .{name});
    }

    pub fn exists(self: *Runtime, path_: []const u8) bool {
        Io.Dir.cwd().access(self.io, path_, .{}) catch return false;
        return true;
    }

    pub fn isFile(self: *Runtime, path_: []const u8) bool {
        const stat = Io.Dir.cwd().statFile(self.io, path_, .{}) catch return false;
        return stat.kind == .file;
    }

    /// Size of a regular file, or null when missing/not a file.
    pub fn fileSize(self: *Runtime, path_: []const u8) ?u64 {
        const stat = Io.Dir.cwd().statFile(self.io, path_, .{}) catch return null;
        return if (stat.kind == .file) stat.size else null;
    }

    pub fn rename(self: *Runtime, old: []const u8, new: []const u8) !void {
        Io.Dir.rename(.cwd(), old, .cwd(), new, self.io) catch |err|
            return self.fail("Could not move {s} to {s}: {t}", .{ old, new, err });
    }

    pub fn makeDir(self: *Runtime, path_: []const u8) !void {
        Io.Dir.cwd().createDir(self.io, path_, .default_dir) catch |err|
            return self.fail("Could not create {s}: {t}", .{ path_, err });
    }

    /// Best-effort recursive removal.
    pub fn removeTree(self: *Runtime, path_: []const u8) void {
        Io.Dir.cwd().deleteTree(self.io, path_) catch {};
    }

    /// Create a private (0700) directory `parent/prefix<random>`, like
    /// mkdtemp. Caller frees the returned path and removes the directory.
    pub fn tempDir(self: *Runtime, parent: []const u8, prefix: []const u8) ![]u8 {
        const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789_";
        var attempt: usize = 0;
        while (attempt < 100) : (attempt += 1) {
            var random: [8]u8 = undefined;
            self.io.random(&random);
            var suffix: [8]u8 = undefined;
            for (&suffix, random) |*c, r| c.* = alphabet[r % alphabet.len];
            const name = try std.mem.concat(self.allocator, u8, &.{ prefix, &suffix });
            defer self.allocator.free(name);
            const full = try std.fs.path.join(self.allocator, &.{ parent, name });
            Io.Dir.cwd().createDir(self.io, full, .fromMode(0o700)) catch |err| {
                self.allocator.free(full);
                if (err == error.PathAlreadyExists) continue;
                return self.fail("Could not create a temporary directory in {s}: {t}", .{ parent, err });
            };
            return full;
        }
        return self.fail("Could not create a unique temporary directory in {s}", .{parent});
    }

    /// Directory for temporary files: $TMPDIR, else /tmp. Borrowed.
    pub fn tempRoot(self: *Runtime) []const u8 {
        if (self.environ.get("TMPDIR")) |value| {
            if (value.len > 0) return value;
        }
        return "/tmp";
    }

    /// Bytes available to unprivileged users on the filesystem of `path_`.
    pub fn diskFree(self: *Runtime, path_: []const u8) !u64 {
        const z = try self.allocator.dupeSentinel(u8, path_, 0);
        defer self.allocator.free(z);
        return freeBytes(z) orelse self.fail("Could not inspect free space at {s}", .{path_});
    }

    // ------------------------------------------------------------ processes

    fn resolveExe(self: *Runtime, argv0: []const u8, environ: *const Environ.Map) !?[]u8 {
        if (std.mem.findScalar(u8, argv0, '/') != null) return null;
        const search = environ.get("PATH") orelse self.environ.get("PATH") orelse "";
        var it = std.mem.tokenizeScalar(u8, search, ':');
        while (it.next()) |dir| {
            const candidate = try std.fs.path.join(self.allocator, &.{ dir, argv0 });
            if (self.isFile(candidate)) {
                if (Io.Dir.cwd().access(self.io, candidate, .{ .execute = true })) |_| {
                    return candidate;
                } else |_| {}
            }
            self.allocator.free(candidate);
        }
        return self.fail("Missing {s} on PATH", .{argv0});
    }

    fn spawnRaw(self: *Runtime, options: std.process.SpawnOptions) !std.process.Child {
        const environ = options.environ_map orelse self.environ;
        const resolved = try self.resolveExe(options.argv[0], environ);
        defer if (resolved) |r| self.allocator.free(r);
        var copy = options;
        copy.environ_map = environ;
        if (resolved) |r| copy.exe = .{ .explicit = .{ .dir = .cwd(), .path = r } };
        return std.process.spawn(self.io, copy) catch |err|
            self.fail("Could not start {s}: {t}", .{ options.argv[0], err });
    }

    /// Run a command in its own process group with stdout/stderr captured.
    /// Bounded by `timeout` (process group SIGKILLed, `error.CommandTimeout`)
    /// and interruptible. Returns the exit status without checking it.
    pub fn capture(self: *Runtime, options: CaptureOptions) !Capture {
        try checkInterrupt();
        const deadline = self.now() + options.timeout;
        var child = try self.spawnRaw(.{
            .argv = options.argv,
            .cwd = if (options.cwd) |c| .{ .path = c } else .inherit,
            .environ_map = options.environ,
            .stdin = if (options.input != null) .pipe else .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = 0,
        });
        const pid = child.id.?;
        var reaped = false;
        defer if (!reaped) {
            sendSignal(pid, true, .KILL);
            _ = reapPid(pid);
        };
        // We reap with waitpid ourselves, so release the std handles here.
        defer {
            inline for (.{ "stdin", "stdout", "stderr" }) |field| {
                if (@field(child, field)) |file| file.close(self.io);
                @field(child, field) = null;
            }
            child.id = null;
        }
        if (options.input) |input| {
            child.stdin.?.writeStreamingAll(self.io, input) catch {};
            child.stdin.?.close(self.io);
            child.stdin = null;
        }

        var streams: Io.File.MultiReader.Buffer(2) = undefined;
        var multi: Io.File.MultiReader = undefined;
        multi.init(self.allocator, self.io, streams.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer multi.deinit();

        while (true) {
            try checkInterrupt();
            const remaining = deadline - self.now();
            if (remaining <= 0) return self.timedOut(options);
            const slice: i96 = @intFromFloat(@min(remaining, 0.1) * std.time.ns_per_s);
            multi.fill(256, .{ .duration = .{ .raw = .fromNanoseconds(@max(slice, 1)), .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => continue,
                error.EndOfStream => break,
                else => |e| return e,
            };
            if (multi.reader(0).buffered().len > options.output_limit or
                multi.reader(1).buffered().len > options.output_limit)
            {
                self.setDetail("Command output exceeded {d} bytes: ", .{options.output_limit});
                self.appendArgv(options.argv);
                return error.Failed;
            }
        }
        try multi.checkAnyError();

        // Output closed; the process normally exits right away.
        var wait: f64 = 0.001;
        const term = while (true) {
            if (pollPid(pid)) |term| break term;
            try checkInterrupt();
            if (self.now() >= deadline) return self.timedOut(options);
            self.pause(wait);
            wait = @min(wait * 2, 0.05);
        };
        reaped = true;
        const stdout = try multi.toOwnedSlice(0);
        errdefer self.allocator.free(stdout);
        const stderr = try multi.toOwnedSlice(1);
        return .{ .term = term, .stdout = stdout, .stderr = stderr };
    }

    fn timedOut(self: *Runtime, options: CaptureOptions) error{CommandTimeout} {
        self.setDetail("Command timed out after {d}s: ", .{options.timeout});
        self.appendArgv(options.argv);
        return error.CommandTimeout;
    }

    fn appendArgv(self: *Runtime, argv: []const []const u8) void {
        var writer: Io.Writer = .fixed(&self.detail_buffer);
        writer.end = self.detail_len;
        for (argv, 0..) |arg, i| {
            writer.print("{s}{s}", .{ if (i == 0) "" else " ", arg }) catch break;
        }
        self.detail_len = writer.end;
    }

    fn appendText(self: *Runtime, comptime fmt: []const u8, args: anytype) void {
        var writer: Io.Writer = .fixed(&self.detail_buffer);
        writer.end = self.detail_len;
        writer.print(fmt, args) catch {};
        self.detail_len = writer.end;
    }

    /// Record "`argv` exited with status N" plus trimmed stderr and stdout.
    pub fn commandFailed(self: *Runtime, argv: []const []const u8, result: Capture) error{CommandFailed} {
        self.detail_len = 0;
        self.appendArgv(argv);
        switch (result.term) {
            .exited => |code| self.appendText(" exited with status {d}", .{code}),
            .signal => |sig| self.appendText(" terminated by signal {t}", .{sig}),
            else => self.appendText(" terminated unexpectedly", .{}),
        }
        const err_text = std.mem.trim(u8, result.stderr, &std.ascii.whitespace);
        const out_text = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
        if (err_text.len > 0) self.appendText("\n{s}", .{err_text});
        if (out_text.len > 0) self.appendText("\n{s}", .{out_text});
        return error.CommandFailed;
    }

    /// `capture` with the exit status checked. Returns trimmed stdout, which
    /// the caller frees. Failures surface stderr in `detail()`.
    pub fn runWith(self: *Runtime, options: CaptureOptions) ![]u8 {
        var result = try self.capture(options);
        defer result.deinit(self.allocator);
        if (!result.success()) return self.commandFailed(options.argv, result);
        return self.allocator.dupe(u8, std.mem.trim(u8, result.stdout, &std.ascii.whitespace));
    }

    /// Run with a timeout in seconds; returns trimmed stdout (caller frees).
    pub fn run(self: *Runtime, argv: []const []const u8, cwd: ?[]const u8, timeout: f64) ![]u8 {
        return self.runWith(.{ .argv = argv, .cwd = cwd, .timeout = timeout });
    }

    /// Run a long foreground command (e.g. a Flutter build) with inherited
    /// stdio in an owned group. Forward interrupts to that group, including
    /// when SIGTERM targets only the audit CLI rather than the whole terminal.
    /// Escalate INT -> TERM -> KILL with five seconds for each graceful signal.
    pub fn command(self: *Runtime, argv: []const []const u8, cwd: ?[]const u8) !void {
        try checkInterrupt();
        var child = try self.spawnRaw(.{
            .argv = argv,
            .cwd = if (cwd) |c| .{ .path = c } else .inherit,
            .pgid = 0,
        });
        const pid = child.id.?;
        child.id = null;
        var owned: Child = .{ .rt = self, .pid = pid, .group = true };
        defer _ = owned.stop(.{ .grace = 0 });
        while (true) {
            if (interrupted() and shield_depth.load(.seq_cst) == 0) {
                _ = owned.stop(.{ .signal = .INT, .grace = 5, .term_grace = 5 });
                return error.Interrupted;
            }
            if (owned.poll()) |term| {
                if (term.success()) return;
                return self.commandFailed(argv, .{ .term = term, .stdout = &.{}, .stderr = &.{} });
            }
            self.pause(0.05);
        }
    }

    /// Poll `ctx.ready()` (returns `!bool`) every `interval` seconds until it
    /// is true; errors from `ready` propagate. On expiry: error.Failed with
    /// "Timed out waiting for <description>".
    pub fn waitFor(self: *Runtime, description: []const u8, timeout: f64, interval: f64, ctx: anytype) !void {
        const deadline = self.now() + timeout;
        while (self.now() < deadline) {
            if (try ctx.ready()) return;
            try self.sleep(interval);
        }
        return self.fail("Timed out waiting for {s}", .{description});
    }
};

// ---------------------------------------------------------------- child

/// An owned long-running process (emulator, mitmdump, recorder, daemon).
/// Reaped with non-blocking waitpid; never use std's Child.wait on it.
pub const Child = struct {
    rt: *Runtime,
    pid: posix.pid_t,
    /// Whether `pid` leads its own process group (signals go to the group).
    group: bool,
    /// Exit status once reaped.
    term: ?Term = null,
    /// Set by `stop`; later calls do not signal a possibly reused group.
    stopped: bool = false,

    pub const Stdio = union(enum) {
        inherit,
        ignore,
        /// Caller-owned file; may be closed right after `spawn`.
        file: Io.File,
    };

    pub const Options = struct {
        argv: []const []const u8,
        cwd: ?[]const u8 = null,
        /// Defaults to `Runtime.environ`. Its PATH resolves argv[0].
        environ: ?*const Environ.Map = null,
        stdin: Stdio = .ignore,
        stdout: Stdio = .inherit,
        stderr: Stdio = .inherit,
        /// Start a new process group (like start_new_session): terminal
        /// signals do not reach it and `stop` also kills descendants.
        own_group: bool = true,
    };

    pub const StopOptions = struct {
        /// First signal, e.g. .INT for mitmdump, .TERM otherwise.
        signal: posix.SIG = .TERM,
        /// Seconds to wait after `signal`.
        grace: f64 = 5,
        /// When `signal` is not TERM: seconds to wait after a follow-up TERM.
        term_grace: f64 = 0,
    };

    fn stdio(value: Stdio) std.process.SpawnOptions.StdIo {
        return switch (value) {
            .inherit => .inherit,
            .ignore => .ignore,
            .file => |f| .{ .file = f },
        };
    }

    pub fn spawn(rt: *Runtime, options: Options) !Child {
        try checkInterrupt();
        var child = try rt.spawnRaw(.{
            .argv = options.argv,
            .cwd = if (options.cwd) |c| .{ .path = c } else .inherit,
            .environ_map = options.environ,
            .stdin = stdio(options.stdin),
            .stdout = stdio(options.stdout),
            .stderr = stdio(options.stderr),
            .pgid = if (options.own_group) 0 else null,
        });
        const pid = child.id.?;
        child.id = null; // No pipes were created; nothing else to release.
        return .{ .rt = rt, .pid = pid, .group = options.own_group };
    }

    /// Non-blocking: the exit status if the process has exited (reaping it).
    pub fn poll(self: *Child) ?Term {
        if (self.term == null) self.term = pollPid(self.pid);
        return self.term;
    }

    pub fn running(self: *Child) bool {
        return self.poll() == null;
    }

    /// Signal the process (its group when `group`). No-op once reaped.
    pub fn signal(self: *Child, sig: posix.SIG) void {
        if (self.term == null) sendSignal(self.pid, self.group, sig);
    }

    /// Wait up to `timeout` seconds without reporting interrupts.
    pub fn wait(self: *Child, timeout: f64) ?Term {
        const deadline = self.rt.now() + timeout;
        while (true) {
            if (self.poll()) |term| return term;
            if (self.rt.now() >= deadline) return null;
            self.rt.pause(0.02);
        }
    }

    /// Bounded teardown: `signal`, wait `grace`, optional TERM/`term_grace`,
    /// then SIGKILL (the whole group when `group`, even if the leader has
    /// already exited, to remove orphaned descendants) and reap. Idempotent.
    pub fn stop(self: *Child, options: StopOptions) Term {
        if (self.stopped) return self.term.?;
        defer self.stopped = true;
        if (self.poll() == null) {
            self.signal(options.signal);
            _ = self.wait(options.grace);
            if (self.term == null and options.signal != .TERM and options.term_grace > 0) {
                self.signal(.TERM);
                _ = self.wait(options.term_grace);
            }
        }
        if (self.group) sendSignal(self.pid, true, .KILL);
        if (self.term == null) {
            sendSignal(self.pid, false, .KILL);
            self.term = reapPid(self.pid);
        }
        return self.term.?;
    }
};

// ---------------------------------------------------------------- network

/// A free loopback TCP port, released before returning (like the Python
/// bind-to-0 helper; inherently racy, so bind it promptly).
pub fn freePort(rt: *Runtime) !u16 {
    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    const socket = address.bind(rt.io, .{ .mode = .stream, .protocol = .tcp }) catch |err|
        return rt.fail("Could not reserve a loopback port: {t}", .{err});
    defer socket.close(rt.io);
    return socket.address.getPort();
}

/// Whether 127.0.0.1:`port` can currently be bound (TCP).
pub fn portAvailable(rt: *Runtime, port: u16) bool {
    const address = Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
    const socket = address.bind(rt.io, .{ .mode = .stream, .protocol = .tcp }) catch return false;
    socket.close(rt.io);
    return true;
}

// ---------------------------------------------------------------- disk

const LinuxStatvfs = extern struct {
    bsize: c_ulong,
    frsize: c_ulong,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    favail: u64,
    fsid: c_ulong,
    flag: c_ulong,
    namemax: c_ulong,
    spare: [6]c_int,
};

// 64-bit-inode `struct statfs` (the only layout on Apple Silicon).
const DarwinStatfs = extern struct {
    bsize: u32,
    iosize: i32,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    fsid: [2]i32,
    owner: u32,
    type: u32,
    flags: u32,
    fssubtype: u32,
    fstypename: [16]u8,
    mntonname: [1024]u8,
    mntfromname: [1024]u8,
    flags_ext: u32,
    reserved: [7]u32,
};

const disk = switch (builtin.os.tag) {
    .linux => struct {
        extern "c" fn statvfs(path: [*:0]const u8, buf: *LinuxStatvfs) c_int;
        fn free(path: [*:0]const u8) ?u64 {
            var buf: LinuxStatvfs = undefined;
            if (statvfs(path, &buf) != 0) return null;
            return buf.bavail * @as(u64, buf.frsize);
        }
    },
    .macos => struct {
        extern "c" fn statfs(path: [*:0]const u8, buf: *DarwinStatfs) c_int;
        fn free(path: [*:0]const u8) ?u64 {
            var buf: DarwinStatfs = undefined;
            if (statfs(path, &buf) != 0) return null;
            return buf.bavail * @as(u64, buf.bsize);
        }
    },
    else => struct {
        fn free(path: [*:0]const u8) ?u64 {
            _ = path;
            return null;
        }
    },
};

fn freeBytes(path: [*:0]const u8) ?u64 {
    return disk.free(path);
}

// ---------------------------------------------------------------- tests

pub const testing = struct {
    /// A runtime over std.testing.io with a private copy of the test
    /// environment. Call `deinit` to release it.
    pub const Fixture = struct {
        map: Environ.Map,
        rt: Runtime,

        pub fn init(self: *Fixture) !void {
            self.map = try std.testing.environ.createMap(std.testing.allocator);
            self.rt = .{ .allocator = std.testing.allocator, .io = std.testing.io, .environ = &self.map };
        }

        pub fn deinit(self: *Fixture) void {
            self.map.deinit();
        }

        /// Prepend `dir` to PATH.
        pub fn prependPath(self: *Fixture, dir: []const u8) !void {
            const old = self.map.get("PATH") orelse "";
            const value = try std.mem.concat(std.testing.allocator, u8, &.{ dir, ":", old });
            defer std.testing.allocator.free(value);
            try self.map.put("PATH", value);
        }
    };

    /// Write an executable script.
    pub fn script(rt: *Runtime, path_: []const u8, body: []const u8) !void {
        try Io.Dir.cwd().writeFile(rt.io, .{
            .sub_path = path_,
            .data = body,
            .flags = .{ .permissions = .fromMode(0o700) },
        });
    }

    /// Whether `pid` still exists as a non-zombie process.
    pub fn alive(pid: posix.pid_t) bool {
        if (std.c.kill(pid, @fromBackingInt(0)) != 0) return false;
        if (builtin.os.tag != .linux) return true;
        var buf: [64]u8 = undefined;
        const proc = std.fmt.bufPrint(&buf, "/proc/{d}/stat", .{pid}) catch return true;
        const file = Io.Dir.cwd().openFile(std.testing.io, proc, .{}) catch return false;
        defer file.close(std.testing.io);
        var data: [512]u8 = undefined;
        const n = file.readPositionalAll(std.testing.io, &data, 0) catch return true;
        const close_paren = std.mem.findScalarLast(u8, data[0..n], ')') orelse return true;
        return !(close_paren + 2 < n and data[close_paren + 2] == 'Z');
    }
};

test "run captures trimmed stdout and surfaces stderr on failure" {
    var f: testing.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const rt = &f.rt;
    const out = try rt.run(&.{ "sh", "-c", "printf '  hello\\n\\n'" }, null, 10);
    defer rt.allocator.free(out);
    try std.testing.expectEqualStrings("hello", out);

    try std.testing.expectError(error.CommandFailed, rt.run(&.{ "sh", "-c", "echo out; echo bad >&2; exit 3" }, null, 10));
    try std.testing.expect(std.mem.indexOf(u8, rt.detail(), "status 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, rt.detail(), "bad") != null);

    const echoed = try rt.runWith(.{ .argv = &.{"cat"}, .input = "no\n", .timeout = 10 });
    defer rt.allocator.free(echoed);
    try std.testing.expectEqualStrings("no", echoed);

    try std.testing.expectError(error.Failed, rt.run(&.{"network-audit-definitely-missing"}, null, 10));
    try std.testing.expect(std.mem.indexOf(u8, rt.detail(), "Missing") != null);
}

test "run timeout kills the whole process group, even TERM-ignoring descendants" {
    var f: testing.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const rt = &f.rt;
    const dir = try rt.tempDir(rt.tempRoot(), "na-rt-");
    defer rt.allocator.free(dir);
    defer rt.removeTree(dir);
    const pid_file = try rt.path(&.{ dir, "pid" });
    defer rt.allocator.free(pid_file);
    const started = rt.now();
    const script = try std.fmt.allocPrint(rt.allocator, "trap '' TERM; sh -c 'trap \"\" TERM; while :; do sleep 0.1; done' & echo $! > '{s}'; wait", .{pid_file});
    defer rt.allocator.free(script);
    try std.testing.expectError(error.CommandTimeout, rt.run(&.{ "sh", "-c", script }, null, 1));
    try std.testing.expect(rt.now() - started < 5);
    const text = try rt.read(pid_file);
    defer rt.allocator.free(text);
    const pid = try std.fmt.parseInt(posix.pid_t, std.mem.trim(u8, text, " \n"), 10);
    var waited: usize = 0;
    while (testing.alive(pid) and waited < 50) : (waited += 1) rt.pause(0.02);
    try std.testing.expect(!testing.alive(pid));
}

test "child poll, interrupt flag, and bounded stop" {
    var f: testing.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const rt = &f.rt;

    const dir = try rt.tempDir(rt.tempRoot(), "na-rt-");
    defer rt.allocator.free(dir);
    defer rt.removeTree(dir);
    const log_path = try rt.path(&.{ dir, "ready" });
    defer rt.allocator.free(log_path);
    const log = try rt.createLog(log_path);
    defer log.close(rt.io);

    var quick = try Child.spawn(rt, .{ .argv = &.{ "sh", "-c", "exit 7" } });
    const term = quick.wait(5) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 7), term.exited);
    _ = quick.stop(.{});

    // Report readiness only after the traps are installed.
    var stubborn = try Child.spawn(rt, .{
        .argv = &.{ "sh", "-c", "trap '' TERM INT; echo ready; while :; do sleep 0.1; done" },
        .stdout = .{ .file = log },
    });
    var ready: usize = 0;
    while ((rt.fileSize(log_path) orelse 0) == 0 and ready < 250) : (ready += 1) rt.pause(0.02);
    try std.testing.expect(stubborn.running());
    const started = rt.now();
    const stopped = stubborn.stop(.{ .signal = .INT, .grace = 0.3, .term_grace = 0.3 });
    try std.testing.expect(rt.now() - started < 3);
    try std.testing.expectEqual(posix.SIG.KILL, stopped.signal);
    try std.testing.expect(!testing.alive(stubborn.pid));

    // The interrupt flag stops polling loops but not shielded teardown.
    requestInterrupt();
    defer clearInterrupt();
    try std.testing.expectError(error.Interrupted, rt.sleep(5));
    try std.testing.expectError(error.Interrupted, rt.run(&.{ "sleep", "5" }, null, 10));
    shield();
    const out = try rt.run(&.{ "echo", "cleanup" }, null, 10);
    unshield();
    defer rt.allocator.free(out);
    try std.testing.expectEqualStrings("cleanup", out);
}

test "command reports status and stops an interrupted build and its descendants" {
    var f: testing.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const rt = &f.rt;
    try rt.command(&.{ "sh", "-c", "exit 0" }, null);
    try std.testing.expectError(error.CommandFailed, rt.command(&.{ "sh", "-c", "exit 2" }, "/"));

    // SIGTERM targets only us; a TERM/INT-ignoring descendant must not survive.
    installSignalHandlers();
    defer uninstallSignalHandlers();
    defer clearInterrupt();
    const dir = try rt.tempDir(rt.tempRoot(), "na-build-test-");
    defer rt.allocator.free(dir);
    defer rt.removeTree(dir);
    const pid_file = try rt.path(&.{ dir, "child.pid" });
    defer rt.allocator.free(pid_file);
    const started = rt.now();
    try std.testing.expectError(error.Interrupted, rt.command(&.{
        "sh", "-c", "sh -c 'trap \"\" INT TERM; while :; do sleep 1; done' & echo $! > child.pid; kill -TERM $PPID; wait",
    }, dir));
    try std.testing.expect(rt.now() - started < 12);
    const text = try rt.read(pid_file);
    defer rt.allocator.free(text);
    const pid = try std.fmt.parseInt(posix.pid_t, std.mem.trim(u8, text, " \n"), 10);
    var waited: usize = 0;
    while (testing.alive(pid) and waited < 100) : (waited += 1) rt.pause(0.02);
    try std.testing.expect(!testing.alive(pid));
}

test "real SIGTERM sets the flag" {
    installSignalHandlers();
    defer clearInterrupt();
    defer uninstallSignalHandlers();
    try std.testing.expect(!interrupted());
    try posix.kill(std.c.getpid(), .TERM);
    var f: testing.Fixture = undefined;
    try f.init();
    defer f.deinit();
    var waited: usize = 0;
    while (!interrupted() and waited < 100) : (waited += 1) f.rt.pause(0.01);
    try std.testing.expect(interrupted());
    try std.testing.expectError(error.Interrupted, checkInterrupt());
}

test "temp dirs are private; ports and disk queries work" {
    var f: testing.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const rt = &f.rt;
    const dir = try rt.tempDir(rt.tempRoot(), "na-rt-");
    defer rt.allocator.free(dir);
    defer rt.removeTree(dir);
    const stat = try Io.Dir.cwd().statFile(rt.io, dir, .{});
    try std.testing.expectEqual(@as(posix.mode_t, 0o700), stat.permissions.toMode() & 0o777);
    try std.testing.expect(std.mem.startsWith(u8, std.fs.path.basename(dir), "na-rt-"));
    const port = try freePort(rt);
    try std.testing.expect(port > 0);
    try std.testing.expect(portAvailable(rt, port));
    try std.testing.expect(try rt.diskFree(dir) > 0);
    try std.testing.expect(rt.now() > 0);
}
