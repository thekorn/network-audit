//! A silent MP4 recording on the audit's owned API 36 emulator.
//! Native port of network-audit/recording.py.

const std = @import("std");
const runtime = @import("runtime.zig");
const android = @import("android.zig");
const Runtime = runtime.Runtime;

// The emulator is disposable and belongs exclusively to this audit.
const remote = "/data/local/tmp/network-audit-recording.mp4";
const pid_file = "/data/local/tmp/network-audit-recording.pid";

pub const ScreenRecording = struct {
    emulator: *android.Emulator,
    /// session/recording.mp4, written only after a finalized, non-empty pull.
    path: []u8,
    log_path: []u8,
    partial_path: []u8,
    /// Host-side `adb shell screenrecord` process group once started.
    process: ?runtime.Child = null,

    pub fn init(emulator: *android.Emulator, session: []const u8) !ScreenRecording {
        const rt = emulator.rt;
        const path = try rt.path(&.{ session, "recording.mp4" });
        errdefer rt.allocator.free(path);
        const log_path = try rt.path(&.{ session, "recording.log" });
        errdefer rt.allocator.free(log_path);
        const partial_path = try rt.path(&.{ session, "recording.mp4.partial" });
        return .{ .emulator = emulator, .path = path, .log_path = log_path, .partial_path = partial_path };
    }

    pub fn deinit(self: *ScreenRecording) void {
        const a = self.emulator.rt.allocator;
        a.free(self.path);
        a.free(self.log_path);
        a.free(self.partial_path);
        self.* = undefined;
    }

    /// Start screenrecord without its 180 s limit and wait until the muxer
    /// has written data. On failure, still call `stop` for cleanup.
    pub fn start(self: *ScreenRecording) !void {
        const rt = self.emulator.rt;
        const log = try rt.createLog(self.log_path);
        defer log.close(rt.io);
        self.process = try runtime.Child.spawn(rt, .{
            .argv = &.{
                "adb",                                                                       "-s", self.emulator.serial, "shell",
                // exec preserves the device-side PID; signalling the host
                // adb process alone does not reliably finalize an MP4.
                "echo $$ > " ++ pid_file ++ "; exec screenrecord --time-limit 0 " ++ remote,
            },
            .stdout = .{ .file = log },
            .stderr = .{ .file = log },
        });
        try rt.waitFor("screen recording; see recording.log", 30, 1, Ready{ .recording = self });
    }

    const Ready = struct {
        recording: *ScreenRecording,
        pub fn ready(self: Ready) !bool {
            const r = self.recording;
            try r.check();
            // screenrecord probes the path with an empty file before starting
            // its encoder. Wait for the muxer to actually write, not just exist.
            const size = try r.emulator.adb(&.{ "shell", "stat -c %s " ++ remote ++ " 2>/dev/null || echo 0" }, 5);
            defer r.emulator.rt.allocator.free(size);
            try r.check();
            const bytes = std.fmt.parseInt(u64, size, 10) catch
                return r.emulator.rt.fail("Unexpected screen recording size: {s}", .{size});
            return bytes > 0;
        }
    };

    /// Fail if the recorder exited on its own.
    pub fn check(self: *ScreenRecording) !void {
        if (self.process) |*process| {
            if (!process.running())
                return self.emulator.rt.fail("Screen recording stopped unexpectedly; see recording.log", .{});
        }
    }

    /// Finalize (device-side SIGINT), wait, and pull before the emulator is
    /// closed, since teardown destroys the only copy. Returns `path`, or
    /// null if never started. A failed or empty transfer never produces
    /// recording.mp4. Always leaves no recorder process behind. Ignores
    /// interrupts so that a second Ctrl+C cannot lose the video.
    pub fn stop(self: *ScreenRecording) !?[]const u8 {
        const process = if (self.process) |*p| p else return null;
        const emulator = self.emulator;
        const rt = emulator.rt;
        runtime.shield();
        defer runtime.unshield();
        // Bound cleanup even when ADB disconnects or the encoder hangs.
        // Emulator cleanup handles any remaining device-side process.
        defer _ = process.stop(.{ .signal = .TERM, .grace = 5 });

        const unexpected = !process.running();
        if (!unexpected) {
            const out = try emulator.adb(&.{ "shell", "kill -INT $(cat " ++ pid_file ++ ")" }, 10);
            rt.allocator.free(out);
        }
        const term = process.wait(30) orelse
            return rt.fail("Screen recording did not finalize within 30s; see recording.log", .{});
        // A failed transfer must not masquerade as a completed MP4.
        const pulled = try emulator.adb(&.{ "pull", remote, self.partial_path }, 120);
        rt.allocator.free(pulled);
        const size = rt.fileSize(self.partial_path) orelse 0;
        if (size == 0) return rt.fail("Screen recording is empty; see recording.log", .{});
        try rt.rename(self.partial_path, self.path);
        if (unexpected or !term.success())
            return rt.fail("Screen recording stopped unexpectedly; video may be partial; see recording.log", .{});
        return self.path;
    }
};

// ------------------------------------------------------------- tests

const testing = std.testing;

// ADB/Android are the boundary: real child processes and signals, with a
// device directory standing in for /data/local/tmp.
const fake_adb =
    \\#!/bin/sh
    \\root=$(cd "$(dirname "$0")/.." && pwd)
    \\[ "$1 $2" = "-s 127.0.0.1:5581" ] || { echo "Must target the owned transport" >&2; exit 3; }
    \\if [ "$3" = shell ]; then
    \\  script=$(printf '%s' "$4" | sed "s#/data/local/tmp/#$root/device/#g")
    \\  exec sh -c "$script"
    \\fi
    \\[ "$3" = pull ] || exit 4
    \\source="$root/device/$(basename "$4")"
    \\[ "$(cat "$source")" = finalized ] || { echo "Transfer preceded graceful finalization" >&2; exit 5; }
    \\if [ "$RECORDING_FIXTURE_MODE" = empty ]; then : > "$5"; else cp "$source" "$5"; fi
    \\[ "$RECORDING_FIXTURE_MODE" = "pull failure" ] && exit 1
    \\exit 0
    \\
;

const fake_screenrecord =
    \\#!/bin/sh
    \\[ "$1 $2" = "--time-limit 0" ] || { echo "Audit must not stop at 180 seconds" >&2; exit 6; }
    \\out=$3
    \\trap 'printf finalized > "$out"; exit 0' INT
    \\printf open > "$out"
    \\while :; do sleep 0.05; done
    \\
;

test "recording finalizes before transfer and rejects incomplete transfers" {
    // As in main: children must not inherit an ignored SIGINT.
    runtime.installSignalHandlers();
    defer runtime.uninstallSignalHandlers();
    for ([_][]const u8{ "complete", "pull failure", "empty" }) |mode| {
        var f: runtime.testing.Fixture = undefined;
        try f.init();
        defer f.deinit();
        const rt = &f.rt;
        const base = try rt.tempDir(rt.tempRoot(), "na-recording-test-");
        defer rt.allocator.free(base);
        defer rt.removeTree(base);
        const bin = try rt.path(&.{ base, "bin" });
        defer rt.allocator.free(bin);
        const device = try rt.path(&.{ base, "device" });
        defer rt.allocator.free(device);
        const session = try rt.path(&.{ base, "session with spaces" });
        defer rt.allocator.free(session);
        const temporary = try rt.path(&.{ base, "avd-root" });
        defer rt.allocator.free(temporary);
        for ([_][]const u8{ bin, device, session, temporary }) |dir| try rt.makeDir(dir);
        inline for (.{ .{ "adb", fake_adb }, .{ "screenrecord", fake_screenrecord } }) |tool| {
            const p = try rt.path(&.{ bin, tool[0] });
            defer rt.allocator.free(p);
            try runtime.testing.script(rt, p, tool[1]);
        }
        try f.prependPath(bin);
        try f.map.put("RECORDING_FIXTURE_MODE", mode);

        var emulator = try android.Emulator.init(rt, temporary, session, 8080, true, "test-image", null);
        defer emulator.deinit();
        try emulator.setSerial("127.0.0.1:5581");
        var recording = try ScreenRecording.init(&emulator, session);
        defer recording.deinit();
        try recording.start();
        try recording.check();
        const video = try rt.path(&.{ session, "recording.mp4" });
        defer rt.allocator.free(video);
        if (std.mem.eql(u8, mode, "complete")) {
            const path = (try recording.stop()).?;
            try testing.expectEqualStrings(video, path);
            const data = try rt.read(path);
            defer rt.allocator.free(data);
            try testing.expectEqualStrings("finalized", data);
        } else {
            const result = recording.stop();
            if (result) |_| return error.TestUnexpectedResult else |err| {
                try testing.expect(err == error.Failed or err == error.CommandFailed);
            }
            try testing.expect(!rt.exists(video));
        }
        const pid_path = try rt.path(&.{ device, "network-audit-recording.pid" });
        defer rt.allocator.free(pid_path);
        const pid_text = try rt.read(pid_path);
        defer rt.allocator.free(pid_text);
        const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, pid_text, " \n"), 10);
        try testing.expect(!runtime.testing.alive(pid));
        try testing.expect(!recording.process.?.running());
    }
}

test "stop before start is a no-op and an exited recorder is reported" {
    var f: runtime.testing.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const rt = &f.rt;
    const base = try rt.tempDir(rt.tempRoot(), "na-recording-test-");
    defer rt.allocator.free(base);
    defer rt.removeTree(base);
    var emulator = try android.Emulator.init(rt, base, base, 8080, true, "test-image", null);
    defer emulator.deinit();
    var recording = try ScreenRecording.init(&emulator, base);
    defer recording.deinit();
    try testing.expect((try recording.stop()) == null);
    recording.process = try runtime.Child.spawn(rt, .{ .argv = &.{ "sh", "-c", "exit 0" } });
    _ = recording.process.?.wait(5);
    try testing.expectError(error.Failed, recording.check());
    try testing.expect(std.mem.find(u8, rt.detail(), "stopped unexpectedly") != null);
    _ = recording.process.?.stop(.{});
}
