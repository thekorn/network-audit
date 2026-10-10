"""An owned, ephemeral API 36 AVD. No existing devices or AVDs are modified."""

import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path


DIMENSION_SHORTCUTS = {
    "big": {"width": 1280, "height": 2856, "density": 480},
}

# The pinned emulator raises smaller userdata requests to 6 GiB.
DATA_PARTITION_GIB = 6
# Allow room for writable emulator images in addition to userdata. Builds and
# caches need their own headroom; this is a preflight, not a reservation.
MIN_TEMP_FREE_BYTES = (DATA_PARTITION_GIB + 2) * 1024**3


def check_storage(directory):
    free = shutil.disk_usage(directory).free
    if free < MIN_TEMP_FREE_BYTES:
        raise RuntimeError(
            f"Insufficient emulator storage at {directory}: "
            f"{free / 1024**3:.2f} GiB free; need at least "
            f"{MIN_TEMP_FREE_BYTES / 1024**3:.0f} GiB "
            f"({DATA_PARTITION_GIB} GiB userdata plus emulator headroom). "
            "Set TMPDIR to a writable directory on a larger filesystem or free "
            "space there. --output only moves reports. Flutter/Gradle builds "
            "and caches need additional space."
        )


def run(args, *, timeout=60, **kwargs):
    return subprocess.run(
        args, check=True, text=True, capture_output=True, timeout=timeout, **kwargs
    ).stdout.strip()


def check_emulator():
    """Fail before building an APK; return the image declared by devenv."""
    machine = platform.machine()
    if sys.platform == "darwin" and machine in ("arm64", "aarch64"):
        acceleration = "macOS Hypervisor.Framework"
    elif sys.platform == "linux" and machine == "x86_64":
        acceleration = "Linux KVM"
        if not os.access("/dev/kvm", os.R_OK | os.W_OK):
            raise RuntimeError(
                "Linux requires readable/writable /dev/kvm. "
                "In Amp use thekorn-amp-runner; never run an emulator in an orb."
            )
    else:
        raise RuntimeError(
            f"Unsupported host: {sys.platform}/{machine}. Use an Apple Silicon Mac "
            "or an x86_64 Linux KVM host. The pinned Nix toolchain does not support "
            "Intel Macs; on Apple Silicon use native ARM64 Nix, not Rosetta."
        )
    image = os.environ.get("NETWORK_AUDIT_SYSTEM_IMAGE")
    sdk = os.environ.get("ANDROID_HOME")
    if not image or not sdk:
        raise RuntimeError("Enter devenv with androidEmulator.enable = true.")
    if not (Path(sdk).joinpath(*image.split(";")) / "package.xml").is_file():
        raise RuntimeError(
            f"Missing {image}. Set androidEmulator.enable = true and re-enter devenv; "
            "do not install SDK components into /nix/store manually."
        )
    try:
        run(["emulator", "-accel-check"], timeout=30)
    except subprocess.CalledProcessError as error:
        detail = "\n".join(
            part.strip() for part in (error.stdout, error.stderr) if part
        )
        raise RuntimeError(f"{acceleration} is unavailable: {detail}") from error
    check_storage(tempfile.gettempdir())
    return image


def wait_for(check, description, timeout=180):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(1)
    raise RuntimeError(f"Timed out waiting for {description}")


def emulator_port():
    for port in range(5554, 5680, 2):
        sockets = []
        try:
            for candidate in (port, port + 1):
                sock = socket.socket()
                sockets.append(sock)
                sock.bind(("127.0.0.1", candidate))
            return port
        except OSError:
            pass
        finally:
            for sock in sockets:
                sock.close()
    raise RuntimeError("No free emulator port")


class Emulator:
    def __init__(
        self, temporary, log, proxy_port, headless, system_image, *, dimensions=None
    ):
        self.root = Path(temporary)
        # mobilecli identifies emulators by AVD name, not their ADB serial.
        # The owned temporary directory gives concurrent runs distinct names.
        self.name = self.root.name
        self.log = log
        self.proxy_port = proxy_port
        self.headless = headless
        self.system_image = system_image
        self.dimensions = dimensions
        self.process = None
        self.port = emulator_port()
        self.serial = f"emulator-{self.port}"

    @property
    def device_id(self):
        # mobilecli uses AVD names for emulator transports, but the serial for TCP.
        return self.name if self.serial.startswith("emulator-") else self.serial

    def adb(self, *args, timeout=60):
        return run(["adb", "-s", self.serial, *args], timeout=timeout)

    def shell(self, script):
        return self.adb("shell", script)

    def start(self):
        # The Flutter build may have consumed space since the early preflight.
        check_storage(self.root)
        env = {**os.environ, "ANDROID_AVD_HOME": str(self.root / "avd")}
        Path(env["ANDROID_AVD_HOME"]).mkdir()
        run(
            [
                "avdmanager",
                "create",
                "avd",
                "--name",
                self.name,
                "--package",
                self.system_image,
            ],
            env=env,
            input="no\n",
            timeout=120,
        )
        config = Path(env["ANDROID_AVD_HOME"]) / f"{self.name}.avd" / "config.ini"
        overrides = {"disk.dataPartition.size": f"{DATA_PARTITION_GIB}G"}
        if self.dimensions is not None:
            overrides.update(
                {f"hw.lcd.{key}": str(value) for key, value in self.dimensions.items()}
            )
        lines = [
            line
            for line in config.read_text().splitlines()
            if line.split("=", 1)[0].strip() not in overrides
        ]
        lines.extend(f"{key}={value}" for key, value in overrides.items())
        config.write_text("\n".join(lines) + "\n")
        command = [
            "emulator",
            "-avd",
            self.name,
            "-port",
            str(self.port),
            "-accel",
            "on",
            "-no-snapshot",
            "-no-boot-anim",
            "-no-audio",
            "-gpu",
            "swiftshader",
            "-http-proxy",
            f"http://127.0.0.1:{self.proxy_port}",
        ]
        if self.dimensions is not None:
            # A named skin can override LCD dimensions; use a matching numeric skin.
            command.extend(
                ["-skin", f"{self.dimensions['width']}x{self.dimensions['height']}"]
            )
        if self.headless:
            command.append("-no-window")
        process = self.process = subprocess.Popen(
            command, env=env, stdout=self.log, stderr=self.log, start_new_session=True
        )

        def booted():
            if process.poll() is not None:
                raise RuntimeError("Emulator exited during boot; see emulator.log")
            try:
                return self.shell("getprop sys.boot_completed") == "1"
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                return False

        wait_for(booted, "emulator boot", timeout=240)

        def rooted():
            # adbd can close its transport while restarting as root. Check the
            # resulting identity before retrying instead of trusting the ACK.
            try:
                if self.adb("shell", "id -u", timeout=5) == "0":
                    return True
                result = self.adb("root", timeout=10)
                if "cannot run as root" in result:
                    raise RuntimeError(
                        "The audit needs a rootable google_apis image, not Google Play"
                    )
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                return False
            return False

        wait_for(rooted, "root ADB connection", timeout=45)
        if sys.platform == "darwin":
            # The pinned ARM64 emulator's vsock ADB transport can drop large
            # transfers (including UI dumps) without restarting adbd. Route
            # through its loopback-only console redirection instead. The API 36
            # image already listens on guest TCP 5555; no adb tcpip restart needed.
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                port = sock.getsockname()[1]
            result = self.adb("emu", "redir", "add", f"tcp:{port}:5555")
            # `adb emu` may exit successfully even when the console reports KO.
            if result != "OK":
                raise RuntimeError(f"Could not forward emulator ADB: {result}")
            self.serial = f"127.0.0.1:{port}"

            def connected():
                try:
                    run(["adb", "connect", self.serial], timeout=10)
                    if self.adb("shell", "id -u", timeout=5) != "0":
                        return False
                    name = self.adb("shell", "getprop ro.boot.qemu.avd_name", timeout=5)
                    if name != self.name:
                        raise RuntimeError("Loopback ADB did not reach the owned emulator")
                    return True
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                    return False

            wait_for(connected, "loopback ADB connection", timeout=45)
        # QUIC bypasses the emulator's TCP proxy. Force HTTPS clients to use TCP.
        self.shell("iptables -I OUTPUT -p udp --dport 443 -j REJECT")
        self.shell("ip6tables -I OUTPUT -p udp --dport 443 -j REJECT")
        self.shell("input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard")
        return process

    def install_ca(self, certificate):
        digest = run(
            ["openssl", "x509", "-in", str(certificate), "-subject_hash_old", "-noout"]
        )
        if not re.fullmatch(r"[0-9a-f]{8}", digest):
            raise RuntimeError("Unexpected certificate subject hash")
        target = f"/data/local/tmp/{digest}.0"
        self.adb("push", str(certificate), target)
        # A tmpfs preserves the base image. Conscrypt (Android 14+) also needs
        # the mount in Zygote namespaces, inherited by newly launched apps.
        self.shell(f"""
set -eu
system=/system/etc/security/cacerts
apex=/apex/com.android.conscrypt/cacerts
backup=/data/local/tmp/network-audit-ca
mkdir -m 700 "$backup"
cp "$apex"/* "$backup"/
mount -t tmpfs tmpfs "$system"
cp "$backup"/* "$system"/
cp {target} "$system"/
chown root:root "$system" "$system"/*
chmod 755 "$system"
chmod 644 "$system"/*
chcon u:object_r:system_file:s0 "$system" "$system"/*
zygotes="$(pidof zygote64) $(pidof zygote || true) $(pidof webview_zygote || true)"
for pid in $zygotes; do
    nsenter --mount=/proc/$pid/ns/mnt -- mount --bind "$system" "$apex"
done
# Include already-started WebView and system processes. Some may exit during
# enumeration; only Zygote injection above is required to succeed.
for pid in $(ps -A -o PID,PPID | awk -v parents="$zygotes" 'NR>1 {{split(parents,p); for (i in p) if ($2==p[i]) print $1}}'); do
    nsenter --mount=/proc/$pid/ns/mnt -- mount --bind "$system" "$apex" 2>/dev/null || true
done
test -r "$system/{digest}.0"
""")

    def launch(self, apk, package, activity):
        self.adb("install", "-r", str(apk), timeout=180)
        result = self.adb("shell", "am", "start", "-W", "-n", f"{package}/{activity}")
        # Android's ~10s first-draw wait can expire on a cold emulator even
        # though the activity started. The caller still verifies foreground;
        # do not relaunch and accidentally duplicate the initial requests.
        if not re.search(r"^Status: (ok|timeout)$", result, re.MULTILINE):
            raise RuntimeError(f"App did not launch: {result}")

    def foreground(self, package):
        activities = self.shell("dumpsys activity activities")
        resumed = [
            line
            for line in activities.splitlines()
            if "mResumedActivity:" in line or "topResumedActivity=" in line
        ]
        return any(
            re.search(r"\b" + re.escape(package) + r"/", line) for line in resumed
        )

    def close(self):
        try:
            if self.process is not None and self.process.poll() is None:
                try:
                    # `emu` addresses the console, not the loopback TCP device.
                    run(["adb", "-s", f"emulator-{self.port}", "emu", "kill"], timeout=10)
                    self.process.wait(timeout=20)
                except (subprocess.SubprocessError, OSError):
                    self.process.terminate()
                    try:
                        self.process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        self.process.kill()
                        self.process.wait()
        finally:
            if self.serial.startswith("127.0.0.1:"):
                # Only remove our connection, never restart the shared ADB server.
                run(["adb", "disconnect", self.serial], timeout=10)


def apk_identity(apk):
    sdk = Path(os.environ["ANDROID_HOME"])
    aapt = sdk / "build-tools" / "36.0.0" / "aapt"
    info = run([str(aapt), "dump", "badging", str(apk)])
    package = re.search(r"^package: name='([^']+)'", info, re.MULTILINE)
    activity = re.search(r"^launchable-activity: name='([^']+)'", info, re.MULTILINE)
    if not package or not activity:
        raise ValueError("APK must have a package and a launchable activity")
    for match in (package, activity):
        if not re.fullmatch(r"[A-Za-z0-9_.$]+", match[1]):
            raise ValueError("Unsupported Android package/activity name")
    return package[1], activity[1]
