//! An owned, ephemeral API 36 AVD. No existing devices or AVDs are modified.
//! Native port of network-audit/android.py.

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime.zig");
const Runtime = runtime.Runtime;
const Io = std.Io;

pub const Dimensions = struct { width: u32, height: u32, density: u32 };

/// Named display presets accepted by --dimensions and scenario files.
pub fn dimensionShortcut(name: []const u8) ?Dimensions {
    if (std.mem.eql(u8, name, "big")) return .{ .width = 1280, .height = 2856, .density = 480 };
    return null;
}

/// The pinned emulator raises smaller userdata requests to 6 GiB.
pub const data_partition_gib = 6;
/// Room for writable emulator images in addition to userdata. Builds and
/// caches need their own headroom; this is a preflight, not a reservation.
pub const min_temp_free_bytes: u64 = (data_partition_gib + 2) * (1 << 30);

const gib: f64 = 1 << 30;

pub fn checkStorage(rt: *Runtime, directory: []const u8, minimum: u64) !void {
    const free = try rt.diskFree(directory);
    if (free < minimum) {
        return rt.fail(
            "Insufficient emulator storage at {s}: {d:.2} GiB free; need at least {d:.0} GiB " ++
                "({d} GiB userdata plus emulator headroom). Set TMPDIR to a writable directory " ++
                "on a larger filesystem or free space there. --output only moves reports. " ++
                "Flutter/Gradle builds and caches need additional space.",
            .{ directory, @as(f64, @floatFromInt(free)) / gib, @as(f64, @floatFromInt(minimum)) / gib, data_partition_gib },
        );
    }
}

// ------------------------------------------------------------- preflight

pub const Host = struct {
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,

    pub const native: Host = .{ .os = builtin.os.tag, .arch = builtin.cpu.arch };
};

/// Validate the host platform; returns the acceleration name.
pub fn hostAcceleration(rt: *Runtime, host: Host, kvm_usable: bool) ![]const u8 {
    if (host.os == .macos and host.arch == .aarch64) return "macOS Hypervisor.Framework";
    if (host.os == .linux and host.arch == .x86_64) {
        if (!kvm_usable) return rt.fail(
            "Linux requires readable/writable /dev/kvm. " ++
                "In Amp use thekorn-amp-runner; never run an emulator in an orb.",
            .{},
        );
        return "Linux KVM";
    }
    return rt.fail(
        "Unsupported host: {s}/{t}. Use an Apple Silicon Mac or an x86_64 Linux KVM host. " ++
            "The pinned Nix toolchain does not support Intel Macs; on Apple Silicon use " ++
            "native ARM64 Nix, not Rosetta.",
        .{ if (host.os == .macos) "darwin" else @tagName(host.os), host.arch },
    );
}

fn kvmUsable(rt: *Runtime) bool {
    if (builtin.os.tag != .linux) return false;
    Io.Dir.cwd().access(rt.io, "/dev/kvm", .{ .read = true, .write = true }) catch return false;
    return true;
}

/// Fail before building an APK; return the system image declared by devenv
/// (caller frees). Never starts an emulator: Linux without /dev/kvm (such as
/// an Amp orb) is rejected before anything runs.
pub fn checkEmulator(rt: *Runtime) ![]const u8 {
    const acceleration = try hostAcceleration(rt, .native, kvmUsable(rt));
    const image = rt.environ.get("NETWORK_AUDIT_SYSTEM_IMAGE") orelse "";
    const sdk = rt.environ.get("ANDROID_HOME") orelse "";
    if (image.len == 0 or sdk.len == 0) return rt.fail("Enter devenv with androidEmulator.enable = true.", .{});

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(rt.allocator);
    try parts.append(rt.allocator, sdk);
    var it = std.mem.splitScalar(u8, image, ';');
    while (it.next()) |part| try parts.append(rt.allocator, part);
    try parts.append(rt.allocator, "package.xml");
    const package = try rt.path(parts.items);
    defer rt.allocator.free(package);
    if (!rt.isFile(package)) return rt.fail(
        "Missing {s}. Set androidEmulator.enable = true and re-enter devenv; " ++
            "do not install SDK components into /nix/store manually.",
        .{image},
    );

    var result = try rt.capture(.{ .argv = &.{ "emulator", "-accel-check" }, .timeout = 30 });
    defer result.deinit(rt.allocator);
    if (!result.success()) {
        const out = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
        const err = std.mem.trim(u8, result.stderr, &std.ascii.whitespace);
        return rt.fail("{s} is unavailable: {s}{s}{s}", .{
            acceleration, out, if (out.len > 0 and err.len > 0) "\n" else "", err,
        });
    }
    try checkStorage(rt, rt.tempRoot(), min_temp_free_bytes);
    return rt.allocator.dupe(u8, image);
}

// ------------------------------------------------------------- APK

pub const Identity = struct {
    package: []const u8,
    activity: []const u8,

    pub fn deinit(self: Identity, allocator: std.mem.Allocator) void {
        allocator.free(self.package);
        allocator.free(self.activity);
    }
};

fn badgingValue(info: []const u8, prefix: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, info, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const rest = line[prefix.len..];
        const end = std.mem.findScalar(u8, rest, '\'') orelse continue;
        if (end > 0) return rest[0..end];
    }
    return null;
}

fn safeName(name: []const u8) bool {
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '$')) return false;
    }
    return name.len > 0;
}

/// Parse `aapt dump badging` output; slices borrow from `info`.
pub fn parseBadging(info: []const u8) error{ MissingLaunchable, UnsupportedName }!Identity {
    const package = badgingValue(info, "package: name='") orelse return error.MissingLaunchable;
    const activity = badgingValue(info, "launchable-activity: name='") orelse return error.MissingLaunchable;
    if (!safeName(package) or !safeName(activity)) return error.UnsupportedName;
    return .{ .package = package, .activity = activity };
}

/// Package and launchable activity of `apk` (caller calls `deinit`).
pub fn apkIdentity(rt: *Runtime, apk: []const u8) !Identity {
    const sdk = try rt.env("ANDROID_HOME");
    const aapt = try rt.path(&.{ sdk, "build-tools", "36.0.0", "aapt" });
    defer rt.allocator.free(aapt);
    const info = try rt.run(&.{ aapt, "dump", "badging", apk }, null, 60);
    defer rt.allocator.free(info);
    const identity = parseBadging(info) catch |err| return switch (err) {
        error.MissingLaunchable => rt.fail("APK must have a package and a launchable activity", .{}),
        error.UnsupportedName => rt.fail("Unsupported Android package/activity name", .{}),
    };
    const package = try rt.allocator.dupe(u8, identity.package);
    errdefer rt.allocator.free(package);
    return .{ .package = package, .activity = try rt.allocator.dupe(u8, identity.activity) };
}

// ------------------------------------------------------------- pure helpers

/// Rewrite an AVD config.ini: drop existing override keys, then append a
/// 6G userdata partition and the optional LCD dimensions. Caller frees.
pub fn rewriteConfig(allocator: std.mem.Allocator, text: []const u8, dimensions: ?Dimensions) ![]u8 {
    var values: [4][2][]const u8 = undefined;
    var buffers: [3][16]u8 = undefined;
    values[0] = .{ "disk.dataPartition.size", std.fmt.comptimePrint("{d}G", .{data_partition_gib}) };
    var count: usize = 1;
    if (dimensions) |d| {
        const keys = [3][]const u8{ "hw.lcd.width", "hw.lcd.height", "hw.lcd.density" };
        const numbers = [3]u32{ d.width, d.height, d.density };
        for (keys, numbers, 0..) |key, number, i| {
            values[count] = .{ key, std.fmt.bufPrint(&buffers[i], "{d}", .{number}) catch unreachable };
            count += 1;
        }
    }
    const overrides = values[0..count];

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (lines.index == null and raw.len == 0) break; // trailing newline
        const line = std.mem.trimEnd(u8, raw, "\r");
        const key_end = std.mem.findScalar(u8, line, '=') orelse line.len;
        const key = std.mem.trim(u8, line[0..key_end], &std.ascii.whitespace);
        const replaced = for (overrides) |o| {
            if (std.mem.eql(u8, o[0], key)) break true;
        } else false;
        if (replaced) continue;
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    for (overrides) |o| try out.print(allocator, "{s}={s}\n", .{ o[0], o[1] });
    return out.toOwnedSlice(allocator);
}

/// Whether a resumed-activity line names exactly `package` (regex
/// `\bPACKAGE/` restricted to mResumedActivity/topResumedActivity lines).
pub fn resumedPackage(activities: []const u8, package: []const u8) bool {
    var lines = std.mem.splitScalar(u8, activities, '\n');
    while (lines.next()) |line| {
        if (std.mem.find(u8, line, "mResumedActivity:") == null and
            std.mem.find(u8, line, "topResumedActivity=") == null) continue;
        var start: usize = 0;
        while (std.mem.findPos(u8, line, start, package)) |at| : (start = at + 1) {
            const end = at + package.len;
            const boundary = at == 0 or !isWord(line[at - 1]);
            if (boundary and end < line.len and line[end] == '/') return true;
        }
    }
    return false;
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// `am start -W` succeeded: a line that is exactly "Status: ok" or
/// "Status: timeout" (Android's first-draw wait can expire on a cold device).
pub fn launchSucceeded(result: []const u8) bool {
    var lines = std.mem.splitScalar(u8, result, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.eql(u8, line, "Status: ok") or std.mem.eql(u8, line, "Status: timeout")) return true;
    }
    return false;
}

fn validDigest(digest: []const u8) bool {
    if (digest.len != 8) return false;
    for (digest) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

/// First even console port P in 5554..5678 where P and P+1 are free.
pub fn emulatorPort(rt: *Runtime) !u16 {
    var port: u16 = 5554;
    while (port < 5680) : (port += 2) {
        const first_address = Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
        const first = first_address.bind(rt.io, .{ .mode = .stream, .protocol = .tcp }) catch continue;
        defer first.close(rt.io);
        const second_address = Io.net.IpAddress.parseIp4("127.0.0.1", port + 1) catch unreachable;
        const second = second_address.bind(rt.io, .{ .mode = .stream, .protocol = .tcp }) catch continue;
        second.close(rt.io);
        return port;
    }
    return rt.fail("No free emulator port", .{});
}

// ------------------------------------------------------------- emulator

const ca_script =
    \\
    \\set -eu
    \\system=/system/etc/security/cacerts
    \\apex=/apex/com.android.conscrypt/cacerts
    \\backup=/data/local/tmp/network-audit-ca
    \\mkdir -m 700 "$backup"
    \\cp "$apex"/* "$backup"/
    \\mount -t tmpfs tmpfs "$system"
    \\cp "$backup"/* "$system"/
    \\cp {[target]s} "$system"/
    \\chown root:root "$system" "$system"/*
    \\chmod 755 "$system"
    \\chmod 644 "$system"/*
    \\chcon u:object_r:system_file:s0 "$system" "$system"/*
    \\zygotes="$(pidof zygote64) $(pidof zygote || true) $(pidof webview_zygote || true)"
    \\for pid in $zygotes; do
    \\    nsenter --mount=/proc/$pid/ns/mnt -- mount --bind "$system" "$apex"
    \\done
    \\# Include already-started WebView and system processes. Some may exit during
    \\# enumeration; only Zygote injection above is required to succeed.
    \\for pid in $(ps -A -o PID,PPID | awk -v parents="$zygotes" 'NR>1 {{split(parents,p); for (i in p) if ($2==p[i]) print $1}}'); do
    \\    nsenter --mount=/proc/$pid/ns/mnt -- mount --bind "$system" "$apex" 2>/dev/null || true
    \\done
    \\test -r "$system/{[digest]s}.0"
    \\
;

pub const Emulator = struct {
    rt: *Runtime,
    /// Owned private temporary directory (AVD home lives inside).
    root: []u8,
    /// AVD name: the basename of `root`, unique per concurrent run.
    /// mobilecli identifies emulators by AVD name, not their ADB serial.
    name: []const u8,
    log_path: []u8,
    proxy_port: u16,
    headless: bool,
    image: []u8,
    dimensions: ?Dimensions,
    /// Console port; the console serial is "emulator-<port>".
    port: u16,
    /// Current ADB serial: "emulator-<port>", or "127.0.0.1:<port>" after
    /// the loopback transport is established. Owned; use `setSerial`.
    serial: []u8,
    /// The emulator process group once `start` spawned it.
    process: ?runtime.Child = null,
    /// Route ADB through a loopback console redirection (default on macOS,
    /// where the vsock transport drops large transfers).
    loopback: bool = builtin.os.tag == .macos,
    /// Storage preflight threshold for `start`.
    min_free_bytes: u64 = min_temp_free_bytes,
    environ: ?std.process.Environ.Map = null,

    /// `temporary` must be an existing private directory owned by this run;
    /// `emulator.log` is written to `session`.
    pub fn init(
        rt: *Runtime,
        temporary: []const u8,
        session: []const u8,
        proxy_port: u16,
        headless: bool,
        image: []const u8,
        dimensions: ?Dimensions,
    ) !Emulator {
        const root = try rt.allocator.dupe(u8, std.mem.trimEnd(u8, temporary, "/"));
        errdefer rt.allocator.free(root);
        const log_path = try rt.path(&.{ session, "emulator.log" });
        errdefer rt.allocator.free(log_path);
        const image_copy = try rt.allocator.dupe(u8, image);
        errdefer rt.allocator.free(image_copy);
        const port = try emulatorPort(rt);
        const serial = try std.fmt.allocPrint(rt.allocator, "emulator-{d}", .{port});
        return .{
            .rt = rt,
            .root = root,
            .name = std.fs.path.basename(root),
            .log_path = log_path,
            .proxy_port = proxy_port,
            .headless = headless,
            .image = image_copy,
            .dimensions = dimensions,
            .port = port,
            .serial = serial,
        };
    }

    /// Release memory. Call `close` first if `start` was called.
    pub fn deinit(self: *Emulator) void {
        const a = self.rt.allocator;
        a.free(self.root);
        a.free(self.log_path);
        a.free(self.image);
        a.free(self.serial);
        if (self.environ) |*map| map.deinit();
        self.* = undefined;
    }

    pub fn setSerial(self: *Emulator, serial: []const u8) !void {
        const copy = try self.rt.allocator.dupe(u8, serial);
        self.rt.allocator.free(self.serial);
        self.serial = copy;
    }

    /// mobilecli uses AVD names for emulator transports, but the serial for TCP.
    pub fn deviceId(self: *const Emulator) []const u8 {
        return if (std.mem.startsWith(u8, self.serial, "emulator-")) self.name else self.serial;
    }

    /// Whether the owned emulator process is still running.
    pub fn running(self: *Emulator) bool {
        return if (self.process) |*p| p.running() else false;
    }

    /// `adb -s <serial> args...`; trimmed stdout (caller frees).
    pub fn adb(self: *Emulator, args: []const []const u8, timeout: f64) ![]u8 {
        var argv: [16][]const u8 = undefined;
        argv[0] = "adb";
        argv[1] = "-s";
        argv[2] = self.serial;
        @memcpy(argv[3..][0..args.len], args);
        return self.rt.run(argv[0 .. 3 + args.len], null, timeout);
    }

    pub fn shell(self: *Emulator, script: []const u8) ![]u8 {
        return self.adb(&.{ "shell", script }, 60);
    }

    fn discard(self: *Emulator, result: anyerror![]u8) !void {
        self.rt.allocator.free(try result);
    }

    fn equals(self: *Emulator, result: anyerror![]u8, expected: []const u8) !bool {
        const out = try result;
        defer self.rt.allocator.free(out);
        return std.mem.eql(u8, out, expected);
    }

    /// Create the private AVD, boot it behind the proxy, obtain root ADB,
    /// establish the transport, and block QUIC.
    pub fn start(self: *Emulator) !void {
        const rt = self.rt;
        // The Flutter build may have consumed space since the early preflight.
        try checkStorage(rt, self.root, self.min_free_bytes);
        const avd_home = try rt.path(&.{ self.root, "avd" });
        defer rt.allocator.free(avd_home);
        try rt.makeDir(avd_home);
        if (self.environ == null) {
            self.environ = try rt.environ.clone(rt.allocator);
            try self.environ.?.put("ANDROID_AVD_HOME", avd_home);
        }
        const environ = &self.environ.?;
        try self.discard(rt.runWith(.{
            .argv = &.{ "avdmanager", "create", "avd", "--name", self.name, "--package", self.image },
            .environ = environ,
            .input = "no\n",
            .timeout = 120,
        }));

        const avd_dir = try std.fmt.allocPrint(rt.allocator, "{s}.avd", .{self.name});
        defer rt.allocator.free(avd_dir);
        const config = try rt.path(&.{ avd_home, avd_dir, "config.ini" });
        defer rt.allocator.free(config);
        const original = try rt.read(config);
        defer rt.allocator.free(original);
        const updated = try rewriteConfig(rt.allocator, original, self.dimensions);
        defer rt.allocator.free(updated);
        try rt.write(config, updated);

        var port_text: [8]u8 = undefined;
        var proxy_text: [32]u8 = undefined;
        var skin_text: [32]u8 = undefined;
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(rt.allocator);
        try argv.appendSlice(rt.allocator, &.{
            "emulator",    "-avd",                                                                                      self.name,
            "-port",       std.fmt.bufPrint(&port_text, "{d}", .{self.port}) catch unreachable,                         "-accel",
            "on",          "-no-snapshot",                                                                              "-no-boot-anim",
            "-no-audio",   "-gpu",                                                                                      "swiftshader",
            "-http-proxy", std.fmt.bufPrint(&proxy_text, "http://127.0.0.1:{d}", .{self.proxy_port}) catch unreachable,
        });
        if (self.dimensions) |d| {
            // A named skin can override LCD dimensions; use a matching numeric skin.
            try argv.appendSlice(rt.allocator, &.{
                "-skin", std.fmt.bufPrint(&skin_text, "{d}x{d}", .{ d.width, d.height }) catch unreachable,
            });
        }
        if (self.headless) try argv.append(rt.allocator, "-no-window");

        const log = try rt.createLog(self.log_path);
        defer log.close(rt.io);
        self.process = try runtime.Child.spawn(rt, .{
            .argv = argv.items,
            .environ = environ,
            .stdout = .{ .file = log },
            .stderr = .{ .file = log },
        });

        try rt.waitFor("emulator boot", 240, 1, Booted{ .e = self });
        try rt.waitFor("root ADB connection", 45, 1, Rooted{ .e = self });
        if (self.loopback) {
            // The pinned ARM64 emulator's vsock ADB transport can drop large
            // transfers (including UI dumps) without restarting adbd. Route
            // through its loopback-only console redirection instead. The API 36
            // image already listens on guest TCP 5555.
            const port = try runtime.freePort(rt);
            var redirect: [32]u8 = undefined;
            const spec = std.fmt.bufPrint(&redirect, "tcp:{d}:5555", .{port}) catch unreachable;
            const result = try self.adb(&.{ "emu", "redir", "add", spec }, 60);
            defer rt.allocator.free(result);
            // `adb emu` may exit successfully even when the console reports KO.
            if (!std.mem.eql(u8, result, "OK")) return rt.fail("Could not forward emulator ADB: {s}", .{result});
            var serial: [32]u8 = undefined;
            try self.setSerial(std.fmt.bufPrint(&serial, "127.0.0.1:{d}", .{port}) catch unreachable);
            try rt.waitFor("loopback ADB connection", 45, 1, Connected{ .e = self });
        }
        // QUIC bypasses the emulator's TCP proxy. Force HTTPS clients to use TCP.
        try self.discard(self.shell("iptables -I OUTPUT -p udp --dport 443 -j REJECT"));
        try self.discard(self.shell("ip6tables -I OUTPUT -p udp --dport 443 -j REJECT"));
        try self.discard(self.shell("input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard"));
    }

    fn commandError(err: anyerror) bool {
        return err == error.CommandFailed or err == error.CommandTimeout;
    }

    const Booted = struct {
        e: *Emulator,
        pub fn ready(self: Booted) !bool {
            if (!self.e.running()) return self.e.rt.fail("Emulator exited during boot; see emulator.log", .{});
            return self.e.equals(self.e.shell("getprop sys.boot_completed"), "1") catch |err|
                if (commandError(err)) false else err;
        }
    };

    const Rooted = struct {
        e: *Emulator,
        // adbd can close its transport while restarting as root. Check the
        // resulting identity before retrying instead of trusting the ACK.
        pub fn ready(self: Rooted) !bool {
            const e = self.e;
            if (e.equals(e.adb(&.{ "shell", "id -u" }, 5), "0") catch |err|
                if (commandError(err)) return false else return err) return true;
            const result = e.adb(&.{"root"}, 10) catch |err|
                if (commandError(err)) return false else return err;
            defer e.rt.allocator.free(result);
            if (std.mem.find(u8, result, "cannot run as root") != null)
                return e.rt.fail("The audit needs a rootable google_apis image, not Google Play", .{});
            return false;
        }
    };

    const Connected = struct {
        e: *Emulator,
        pub fn ready(self: Connected) !bool {
            return self.check() catch |err| if (commandError(err)) false else err;
        }
        fn check(self: Connected) !bool {
            const e = self.e;
            try e.discard(e.rt.run(&.{ "adb", "connect", e.serial }, null, 10));
            if (!try e.equals(e.adb(&.{ "shell", "id -u" }, 5), "0")) return false;
            const name = try e.adb(&.{ "shell", "getprop ro.boot.qemu.avd_name" }, 5);
            defer e.rt.allocator.free(name);
            if (!std.mem.eql(u8, name, e.name))
                return e.rt.fail("Loopback ADB did not reach the owned emulator", .{});
            return true;
        }
    };

    /// Trust `certificate` (PEM) system-wide, including Conscrypt (API 34+)
    /// in Zygote mount namespaces, via a tmpfs that preserves the base image.
    pub fn installCa(self: *Emulator, certificate: []const u8) !void {
        const rt = self.rt;
        const digest = try rt.run(&.{ "openssl", "x509", "-in", certificate, "-subject_hash_old", "-noout" }, null, 60);
        defer rt.allocator.free(digest);
        if (!validDigest(digest)) return rt.fail("Unexpected certificate subject hash", .{});
        const target = try std.fmt.allocPrint(rt.allocator, "/data/local/tmp/{s}.0", .{digest});
        defer rt.allocator.free(target);
        try self.discard(self.adb(&.{ "push", certificate, target }, 60));
        const script = try std.fmt.allocPrint(rt.allocator, ca_script, .{ .target = target, .digest = digest });
        defer rt.allocator.free(script);
        try self.discard(self.shell(script));
    }

    /// Install and start the app once. A first-draw timeout is accepted; the
    /// caller verifies foreground instead of relaunching (which would
    /// duplicate the initial requests).
    pub fn launch(self: *Emulator, apk: []const u8, package: []const u8, activity: []const u8) !void {
        const rt = self.rt;
        try self.discard(self.adb(&.{ "install", "-r", apk }, 180));
        const component = try std.fmt.allocPrint(rt.allocator, "{s}/{s}", .{ package, activity });
        defer rt.allocator.free(component);
        const result = try self.adb(&.{ "shell", "am", "start", "-W", "-n", component }, 60);
        defer rt.allocator.free(result);
        if (!launchSucceeded(result)) return rt.fail("App did not launch: {s}", .{result});
    }

    /// Whether `package` owns the resumed activity. Output is freed per call.
    pub fn foreground(self: *Emulator, package: []const u8) !bool {
        const activities = try self.shell("dumpsys activity activities");
        defer self.rt.allocator.free(activities);
        return resumedPackage(activities, package);
    }

    /// Bounded, idempotent teardown that ignores interrupts: console
    /// `emu kill` (20 s), then SIGTERM (10 s), then SIGKILL of the process
    /// group; finally drop only our loopback ADB connection (never restart
    /// the shared ADB server).
    pub fn close(self: *Emulator) void {
        const rt = self.rt;
        runtime.shield();
        defer runtime.unshield();
        if (self.process) |*process| {
            if (process.running()) {
                var console: [32]u8 = undefined;
                // `emu` addresses the console, not the loopback TCP device.
                const serial = std.fmt.bufPrint(&console, "emulator-{d}", .{self.port}) catch unreachable;
                if (rt.run(&.{ "adb", "-s", serial, "emu", "kill" }, null, 10)) |out| {
                    rt.allocator.free(out);
                    _ = process.wait(20);
                } else |_| {}
            }
            _ = process.stop(.{ .signal = .TERM, .grace = 10 });
        }
        if (std.mem.startsWith(u8, self.serial, "127.0.0.1:")) {
            if (rt.run(&.{ "adb", "disconnect", self.serial }, null, 10)) |out| {
                rt.allocator.free(out);
            } else |_| {}
            // Prevent a second disconnect on repeated close().
            const console = std.fmt.allocPrint(rt.allocator, "emulator-{d}", .{self.port}) catch return;
            rt.allocator.free(self.serial);
            self.serial = console;
        }
    }
};

// ------------------------------------------------------------- tests

const testing = std.testing;

test "dimension shortcut and AVD config overrides" {
    try testing.expectEqual(Dimensions{ .width = 1280, .height = 2856, .density = 480 }, dimensionShortcut("big").?);
    try testing.expect(dimensionShortcut("small") == null);
    const fixture = "hw.ramSize=2048\ndisk.dataPartition.size=12G\n" ++
        "hw.lcd.width=320\nhw.lcd.height=640\nhw.lcd.density=160\nskin.name=HVGA\n";
    const plain = try rewriteConfig(testing.allocator, fixture, null);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("hw.ramSize=2048\nhw.lcd.width=320\nhw.lcd.height=640\n" ++
        "hw.lcd.density=160\nskin.name=HVGA\ndisk.dataPartition.size=6G\n", plain);
    const sized = try rewriteConfig(testing.allocator, fixture, .{ .width = 1920, .height = 1080, .density = 320 });
    defer testing.allocator.free(sized);
    try testing.expectEqualStrings("hw.ramSize=2048\nskin.name=HVGA\ndisk.dataPartition.size=6G\n" ++
        "hw.lcd.width=1920\nhw.lcd.height=1080\nhw.lcd.density=320\n", sized);
    const spaced = try rewriteConfig(testing.allocator, " hw.lcd.width = 1\r\nother=x", .{ .width = 2, .height = 3, .density = 4 });
    defer testing.allocator.free(spaced);
    try testing.expectEqualStrings("other=x\ndisk.dataPartition.size=6G\nhw.lcd.width=2\nhw.lcd.height=3\nhw.lcd.density=4\n", spaced);
}

test "apk identity requires safe package and launcher names" {
    const cases = [_]struct { package: ?[]const u8, activity: ?[]const u8, err: ?anyerror }{
        .{ .package = "org.example_app", .activity = "org.example_app.Main$Nested", .err = null },
        .{ .package = "org.example", .activity = ".Main", .err = null },
        .{ .package = null, .activity = ".Main", .err = error.MissingLaunchable },
        .{ .package = "org.example", .activity = null, .err = error.MissingLaunchable },
        .{ .package = "org.example;bad", .activity = ".Main", .err = error.UnsupportedName },
        .{ .package = "org.example", .activity = "Main/Other", .err = error.UnsupportedName },
    };
    for (cases) |case| {
        var info: std.ArrayList(u8) = .empty;
        defer info.deinit(testing.allocator);
        try info.appendSlice(testing.allocator, "sdkVersion:'36'\n");
        if (case.package) |p| try info.print(testing.allocator, "package: name='{s}' versionCode='1'\n", .{p});
        if (case.activity) |a| try info.print(testing.allocator, "launchable-activity: name='{s}' label='Example'\n", .{a});
        if (case.err) |err| {
            try testing.expectError(err, parseBadging(info.items));
        } else {
            const identity = try parseBadging(info.items);
            try testing.expectEqualStrings(case.package.?, identity.package);
            try testing.expectEqualStrings(case.activity.?, identity.activity);
        }
    }
}

test "foreground checks only resumed activity and exact package" {
    const cases = [_]struct { []const u8, bool }{
        .{ "mResumedActivity: ActivityRecord{abc u0 org.example/.Main t42}", true },
        .{ "topResumedActivity=ActivityRecord{abc u0 org.example/.Main t42}", true },
        .{ "mResumedActivity: ActivityRecord{abc u0 org.example.other/.Main t42}", false },
        .{ "mResumedActivity: ActivityRecord{abc u0 orgXexample/.Main t42}", false },
        .{ "mResumedActivity: ActivityRecord{abc u0 xorg.example/.Main t42}", false },
        .{ "mLastPausedActivity: org.example/.Main\nmResumedActivity: other/.Main", false },
        .{ "", false },
    };
    for (cases) |case| try testing.expectEqual(case[1], resumedPackage(case[0], "org.example"));
}

test "launch accepts first-draw timeout but rejects start errors" {
    for ([_][]const u8{ "ok", "timeout" }) |status| {
        var buf: [128]u8 = undefined;
        const out = try std.fmt.bufPrint(&buf, "Status: {s}\nLaunchState: UNKNOWN (-1)\nActivity: test.app/.MainActivity\nWaitTime: 10987\nComplete", .{status});
        try testing.expect(launchSucceeded(out));
    }
    for ([_][]const u8{ "Error: Activity class does not exist", "Status: failed", "", "Status: ok then" }) |out|
        try testing.expect(!launchSucceeded(out));
    try testing.expect(validDigest("9a5ba575"));
    try testing.expect(!validDigest("9A5BA575"));
    try testing.expect(!validDigest("9a5ba57"));
}

test "host preflight rejects unsupported hosts and Linux without KVM" {
    var f: runtime.testing.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const rt = &f.rt;
    try testing.expectEqualStrings("macOS Hypervisor.Framework", try hostAcceleration(rt, .{ .os = .macos, .arch = .aarch64 }, false));
    try testing.expectEqualStrings("Linux KVM", try hostAcceleration(rt, .{ .os = .linux, .arch = .x86_64 }, true));
    const rejected = [_]struct { Host, []const u8 }{
        .{ .{ .os = .macos, .arch = .x86_64 }, "Intel Macs" },
        .{ .{ .os = .linux, .arch = .aarch64 }, "Unsupported host: linux/aarch64" },
        .{ .{ .os = .windows, .arch = .x86_64 }, "Unsupported host" },
        .{ .{ .os = .linux, .arch = .x86_64 }, "/dev/kvm" },
    };
    for (rejected) |case| {
        try testing.expectError(error.Failed, hostAcceleration(rt, case[0], false));
        try testing.expect(std.mem.find(u8, rt.detail(), case[1]) != null);
    }
    // This host (an orb has no /dev/kvm) must never get as far as the emulator.
    if (!kvmUsable(rt) and builtin.os.tag == .linux) {
        try testing.expectError(error.Failed, checkEmulator(rt));
        try testing.expect(std.mem.find(u8, rt.detail(), "never run an emulator in an orb") != null);
    }
}

test "storage preflight explains TMPDIR and --output" {
    var f: runtime.testing.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const rt = &f.rt;
    try checkStorage(rt, "/", 1);
    try testing.expectError(error.Failed, checkStorage(rt, "/", std.math.maxInt(u64)));
    const message = rt.detail();
    try testing.expect(std.mem.startsWith(u8, message, "Insufficient emulator storage at /: "));
    try testing.expect(std.mem.find(u8, message, "need at least ") != null);
    try testing.expect(std.mem.find(u8, message, "TMPDIR") != null);
    try testing.expect(std.mem.find(u8, message, "--output") != null);
    try testing.expectEqual(@as(u64, 8 << 30), min_temp_free_bytes);
}

const fake_avdmanager =
    \\#!/bin/sh
    \\read answer
    \\[ "$answer" = no ] || exit 9
    \\[ "$1 $2 $3 $5 $6" = "create avd --name --package test-image" ] || exit 8
    \\mkdir -p "$ANDROID_AVD_HOME/$4.avd"
    \\printf 'hw.ramSize=2048\ndisk.dataPartition.size=12G\nhw.lcd.width=320\nhw.lcd.height=640\nhw.lcd.density=160\nskin.name=HVGA\n' > "$ANDROID_AVD_HOME/$4.avd/config.ini"
    \\
;

const fake_emulator =
    \\#!/bin/sh
    \\state=$(dirname "$0")/../state
    \\printf '%s\n' "$@" > "$state/emulator.args"
    \\cp "$ANDROID_AVD_HOME"/*.avd/config.ini "$state/config.seen"
    \\echo $$ > "$state/emulator.pid"
    \\trap '' TERM
    \\trap 'exit 0' USR1
    \\while :; do sleep 0.05; done
    \\
;

const fake_adb =
    \\#!/bin/sh
    \\state=$(dirname "$0")/../state
    \\echo "$*" >> "$state/adb.log"
    \\if [ "$1" = connect ]; then echo "$2" >> "$state/connections"; echo connected; exit 0; fi
    \\if [ "$1" = disconnect ]; then grep -vx "$2" "$state/connections" > "$state/c.tmp"; mv "$state/c.tmp" "$state/connections"; echo disconnected; exit 0; fi
    \\[ "$1" = -s ] || exit 2
    \\serial=$2; shift 2
    \\case "$*" in
    \\  "emu kill") [ "$serial" = "$FAKE_CONSOLE" ] && kill -USR1 "$(cat "$state/emulator.pid")"; echo OK;;
    \\  "shell getprop sys.boot_completed") echo 1;;
    \\  "shell id -u") echo 0;;
    \\  "shell getprop ro.boot.qemu.avd_name") echo "$FAKE_AVD_NAME";;
    \\  "emu redir add "*) echo "$FAKE_REDIR";;
    \\  "shell echo transport") echo "$serial";;
    \\  *) echo OK;;
    \\esac
    \\
;

test "fake toolchain: AVD config, emulator args, transports, and cleanup" {
    const Case = struct { loopback: bool, redir: []const u8, avd_name: ?[]const u8, failure: ?[]const u8, dims: ?Dimensions };
    const cases = [_]Case{
        .{ .loopback = false, .redir = "OK", .avd_name = null, .failure = null, .dims = null },
        .{ .loopback = true, .redir = "OK", .avd_name = null, .failure = null, .dims = .{ .width = 1280, .height = 2856, .density = 480 } },
        .{ .loopback = true, .redir = "KO: port is busy", .avd_name = null, .failure = "Could not forward emulator ADB", .dims = null },
        .{ .loopback = true, .redir = "OK", .avd_name = "unrelated-avd", .failure = "did not reach the owned emulator", .dims = null },
    };
    for (cases) |case| {
        var f: runtime.testing.Fixture = undefined;
        try f.init();
        defer f.deinit();
        const rt = &f.rt;
        const base = try rt.tempDir(rt.tempRoot(), "na-android-test-");
        defer rt.allocator.free(base);
        defer rt.removeTree(base);
        const bin = try rt.path(&.{ base, "bin" });
        defer rt.allocator.free(bin);
        const state = try rt.path(&.{ base, "state" });
        defer rt.allocator.free(state);
        const temporary = try rt.path(&.{ base, "network-audit-x1" });
        defer rt.allocator.free(temporary);
        for ([_][]const u8{ bin, state, temporary }) |dir| try rt.makeDir(dir);
        inline for (.{ .{ "adb", fake_adb }, .{ "emulator", fake_emulator }, .{ "avdmanager", fake_avdmanager } }) |tool| {
            const p = try rt.path(&.{ bin, tool[0] });
            defer rt.allocator.free(p);
            try runtime.testing.script(rt, p, tool[1]);
        }
        const connections = try rt.path(&.{ state, "connections" });
        defer rt.allocator.free(connections);
        try rt.write(connections, "unrelated-device\n");
        try f.prependPath(bin);

        var emulator = try Emulator.init(rt, temporary, state, 8080, true, "test-image", case.dims);
        defer emulator.deinit();
        emulator.loopback = case.loopback;
        emulator.min_free_bytes = 1;
        const console = try rt.allocator.dupe(u8, emulator.serial);
        defer rt.allocator.free(console);
        try f.map.put("FAKE_CONSOLE", console);
        try f.map.put("FAKE_AVD_NAME", case.avd_name orelse emulator.name);
        try f.map.put("FAKE_REDIR", case.redir);
        try testing.expectEqualStrings("network-audit-x1", emulator.name);

        const started = emulator.start();
        defer emulator.close();
        if (case.failure) |message| {
            try testing.expectError(error.Failed, started);
            try testing.expect(std.mem.find(u8, rt.detail(), message) != null);
            if (std.mem.startsWith(u8, case.redir, "KO")) {
                try testing.expectEqualStrings(console, emulator.serial);
                try testing.expectEqualStrings(emulator.name, emulator.deviceId());
            }
        } else {
            try started;
            const transport = try emulator.shell("echo transport");
            defer rt.allocator.free(transport);
            try testing.expectEqualStrings(emulator.serial, transport);
            if (case.loopback) {
                try testing.expect(std.mem.startsWith(u8, emulator.serial, "127.0.0.1:"));
                try testing.expectEqualStrings(emulator.serial, emulator.deviceId());
            } else {
                try testing.expectEqualStrings(console, emulator.serial);
                try testing.expectEqualStrings("network-audit-x1", emulator.deviceId());
            }
        }

        const config = try rt.path(&.{ state, "config.seen" });
        defer rt.allocator.free(config);
        const seen = try rt.read(config);
        defer rt.allocator.free(seen);
        try testing.expect(std.mem.find(u8, seen, "disk.dataPartition.size=6G\n") != null);
        try testing.expect(std.mem.find(u8, seen, "12G") == null);
        const args_path = try rt.path(&.{ state, "emulator.args" });
        defer rt.allocator.free(args_path);
        const args = try rt.read(args_path);
        defer rt.allocator.free(args);
        try testing.expect(std.mem.find(u8, args, "-http-proxy\nhttp://127.0.0.1:8080\n") != null);
        try testing.expect(std.mem.find(u8, args, "-no-window\n") != null);
        if (case.dims != null) {
            try testing.expect(std.mem.find(u8, seen, "hw.lcd.width=1280\nhw.lcd.height=2856\nhw.lcd.density=480\n") != null);
            try testing.expect(std.mem.find(u8, args, "-skin\n1280x2856\n") != null);
        } else {
            try testing.expect(std.mem.find(u8, args, "-skin") == null);
        }

        const pid = emulator.process.?.pid;
        const closing = rt.now();
        emulator.close();
        try testing.expect(rt.now() - closing < 5); // the console kill worked
        try testing.expect(!runtime.testing.alive(pid));
        const remaining = try rt.read(connections);
        defer rt.allocator.free(remaining);
        try testing.expectEqualStrings("unrelated-device\n", remaining);
    }
}
