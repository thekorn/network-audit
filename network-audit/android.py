"""An owned, ephemeral API 36 AVD. No existing devices or AVDs are modified."""

import os
import re
import socket
import subprocess
import time
from pathlib import Path


def run(args, *, timeout=60, **kwargs):
    return subprocess.run(
        args, check=True, text=True, capture_output=True, timeout=timeout, **kwargs
    ).stdout.strip()


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
    def __init__(self, temporary, log, proxy_port, headless):
        self.root = Path(temporary)
        self.log = log
        self.proxy_port = proxy_port
        self.headless = headless
        self.process = None
        self.port = emulator_port()
        self.serial = f"emulator-{self.port}"

    def adb(self, *args, timeout=60):
        return run(["adb", "-s", self.serial, *args], timeout=timeout)

    def shell(self, script):
        return self.adb("shell", script)

    def start(self):
        env = {**os.environ, "ANDROID_AVD_HOME": str(self.root / "avd")}
        Path(env["ANDROID_AVD_HOME"]).mkdir()
        run(
            [
                "avdmanager",
                "create",
                "avd",
                "--name",
                "network-audit",
                "--package",
                "system-images;android-36;google_apis;x86_64",
            ],
            env=env,
            input="no\n",
            timeout=120,
        )
        command = [
            "emulator",
            "-avd",
            "network-audit",
            "-port",
            str(self.port),
            "-no-snapshot",
            "-no-boot-anim",
            "-no-audio",
            "-gpu",
            "swiftshader",
            "-http-proxy",
            f"http://127.0.0.1:{self.proxy_port}",
        ]
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
        if "Status: ok" not in result:
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
        if self.process is not None and self.process.poll() is None:
            try:
                self.adb("emu", "kill", timeout=10)
                self.process.wait(timeout=20)
            except (subprocess.SubprocessError, OSError):
                self.process.terminate()
                try:
                    self.process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()


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
