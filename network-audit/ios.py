"""Experimental, owned iOS Simulator sessions on macOS with Xcode.

Capture uses mitmproxy's macOS local mode, scoped to the new device's UUID in
executable paths, plus an app-scoped WebKit proxy on iOS 17+. Neither changes
host proxy preferences or trust stores.
"""

import json
import os
import platform
import plistlib
import re
import signal
import subprocess
import sys
import uuid
from pathlib import Path
from xml.parsers.expat import ExpatError

from android import run, wait_for


def check_simulator(runtime=None, device_type=None):
    if sys.platform != "darwin":
        raise RuntimeError(
            "--backend=ios requires macOS with full Xcode and an iOS Simulator "
            "runtime. Linux runners and Amp orbs cannot run iOS Simulator."
        )
    # Command Line Tools alone do not include simctl or an iPhoneSimulator SDK.
    run(["xcrun", "--find", "simctl"])
    run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"])
    developer = Path(os.environ.get("DEVELOPER_DIR") or run(["xcode-select", "-p"]))
    # Xcode 27 moved DeviceHub to Contents/Applications, outside Developer.
    simulator_app = next(
        (
            applications / name
            for applications in (developer / "Applications", developer.parent / "Applications")
            for name in ("Simulator.app", "DeviceHub.app")
            if (applications / name).is_dir()
        ),
        None,
    )
    if simulator_app is None:
        raise RuntimeError("Select full Xcode with xcode-select or DEVELOPER_DIR")
    runtimes = json.loads(run(["xcrun", "simctl", "list", "runtimes", "--json"]))
    available = [
        item for item in runtimes["runtimes"]
        if item.get("isAvailable")
        and item["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
        and (runtime is None or item["identifier"] == runtime)
    ]
    available.sort(
        key=lambda item: tuple(int(part) for part in item["version"].split(".")),
        reverse=True,
    )
    for item in available:
        devices = [
            device for device in item.get("supportedDeviceTypes", [])
            if (
                device["identifier"] == device_type if device_type else
                device.get("productFamily") == "iPhone"
            )
        ]
        if devices:
            return item["identifier"], devices[0]["identifier"], simulator_app
    raise RuntimeError(
        "No available iOS Simulator runtime/device matches. Install a runtime "
        "in Xcode Settings, then use identifiers from 'xcrun simctl list runtimes "
        "--json' with --ios-runtime and --ios-device-type."
    )


def app_identity(app):
    if not app.is_dir() or app.suffix != ".app":
        raise ValueError(
            "iOS needs a Simulator .app bundle or a Flutter project, not an IPA/APK"
        )
    try:
        with (app / "Info.plist").open("rb") as source:
            info = plistlib.load(source)
    except (OSError, plistlib.InvalidFileException, ValueError, ExpatError) as error:
        raise ValueError(f"Cannot read Simulator app Info.plist: {app}") from error
    if not isinstance(info, dict):
        raise ValueError("Simulator app Info.plist must contain a dictionary")
    package = info.get("CFBundleIdentifier")
    if not isinstance(package, str) or not re.fullmatch(r"[A-Za-z0-9.-]+", package):
        raise ValueError("Simulator app must have a valid CFBundleIdentifier")
    platforms = info.get("CFBundleSupportedPlatforms")
    if not isinstance(platforms, list) or "iPhoneSimulator" not in platforms:
        raise ValueError("App must be built for iPhoneSimulator, not a physical iOS device")
    return package


def build_app(project, flutter, flavor, define_files):
    # Use Flutter's reported product, not Runner.app or a glob that could select
    # a stale bundle from a different flavor. Keep paths with spaces intact.
    result = subprocess.run(
        [
            *flutter, "build", "ios", "--simulator", "--debug", "--no-codesign",
            "--no-pub",
            *(["--flavor", flavor] if flavor is not None else []),
            *(f"--dart-define-from-file={path}" for path in define_files),
        ],
        cwd=project,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    print(result.stdout, end="", flush=True)
    result.check_returncode()
    output = re.sub(r"\x1b\[[0-9;]*m", "", result.stdout)
    paths = re.findall(
        r"^\s*(?:[✓✔√]\s*)?Built (.+?\.app)(?: \(.*\))?\s*$", output, re.MULTILINE
    )
    if len(paths) != 1:
        raise RuntimeError(
            "Flutter did not report one built Simulator .app; pass the .app directly"
        )
    app = (project / paths[0]).resolve()
    app_identity(app)
    return app


class WebKitProxy:
    def __init__(self, directory, port, device, package, session):
        self.path = directory / "ios-webkit.dylib"
        self.ready = directory / "webkit.ready"
        self.log = session / "ios-app.log"
        self.ad_channel = directory / "ios-ads"
        self.ad_channel.mkdir(mode=0o700)
        # Full Xcode is already required. Compile a launch-only helper, never
        # modify/resign the input bundle or change the shared redirector.
        run([
            "xcrun", "--sdk", "iphonesimulator", "clang",
            "-target", f"{platform.machine()}-apple-ios17.0-simulator",
            "-fobjc-arc", "-dynamiclib", "-framework", "Foundation",
            "-framework", "WebKit", "-framework", "Network",
            str(Path(__file__).with_name("ios_webkit.m")),
            str(Path(__file__).with_name("ios_ads.m")), "-o", str(self.path),
        ], timeout=120)
        inherited = os.environ.get("SIMCTL_CHILD_DYLD_INSERT_LIBRARIES")
        self.environment = {
            **os.environ,
            "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": ":".join(
                [str(self.path), *([inherited] if inherited else [])]
            ),
            "SIMCTL_CHILD_NETWORK_AUDIT_PROXY_PORT": str(port),
            "SIMCTL_CHILD_NETWORK_AUDIT_DEVICE": device,
            "SIMCTL_CHILD_NETWORK_AUDIT_BUNDLE": package,
            "SIMCTL_CHILD_NETWORK_AUDIT_WEBKIT_READY": str(self.ready),
            "SIMCTL_CHILD_NETWORK_AUDIT_IOS_AD_CHANNEL": str(self.ad_channel),
        }

    def check(self):
        wait_for(
            lambda: self.ready.is_file() and self.ready.read_text() == "ready\n",
            "app-scoped WebKit proxy injection; the app must allow Simulator "
            "library injection (see ios-app.log)",
            timeout=30,
        )


class Simulator:
    def __init__(self, name, log, headless, configuration):
        self.name = name
        self.log = log
        self.headless = headless
        self.runtime, self.device_type, self.application = configuration
        self.serial = None
        self.creation_attempted = False
        self.restored = False
        self.webkit = None

    def simctl(self, *args, timeout=60, **kwargs):
        self.log.write(f"simctl {' '.join(map(str, args))}\n")
        self.log.flush()
        return run(["xcrun", "simctl", *args], timeout=timeout, **kwargs)

    def create(self):
        # Never use 'booted', an existing device, or a blanket shutdown/delete.
        self.creation_attempted = True
        identifier = self.simctl("create", self.name, self.device_type, self.runtime)
        self.serial = str(uuid.UUID(identifier)).upper()

    def clone(self, tool, source_set, serial):
        # Recover by our unique name if native cloning times out before returning
        # its UUID, exactly as for a failed create. The destination is the default
        # set so existing Simulator UI and Mobilewright discovery still work.
        self.creation_attempted = True
        self.serial = tool.clone(source_set, None, serial, self.name)
        self.restored = True

    @property
    def capture_mode(self):
        if self.serial is None:
            raise RuntimeError("Create the owned Simulator before starting capture")
        # macOS local mode matches substrings of executable paths, not ancestry.
        # The slash also ensures this is not treated as a numeric PID selector.
        return f"local:{self.serial}/"

    @property
    def device_id(self):
        return self.serial

    def prepare_webkit(self, directory, port, package, session):
        version = re.search(r"\.iOS-(\d+)-", self.runtime)
        if version and int(version[1]) >= 17:
            self.webkit = WebKitProxy(directory, port, self.serial, package, session)

    def start(self):
        self.simctl("boot", self.serial, timeout=180)
        self.simctl("bootstatus", self.serial, "-b", timeout=240)
        if not self.headless:
            run([
                "open", "-a", str(self.application), "--args",
                "-CurrentDeviceUDID", self.serial,
            ])

    def install_ca(self, certificate):
        self.simctl("keychain", self.serial, "add-root-cert", str(certificate))

    def launch(self, app, package, activity=None):
        # The checkpoint already contains the exact verified app. Reinstalling
        # it can change containers and invalidate the saved starting point.
        if not self.restored:
            self.simctl("install", self.serial, str(app), timeout=180)
        if self.webkit:
            self.simctl(
                "launch", f"--stderr={self.webkit.log}", self.serial, package,
                env=self.webkit.environment,
            )
            self.webkit.check()
        else:
            self.simctl("launch", self.serial, package)

    def is_booted(self):
        devices = json.loads(self.simctl("list", "devices", "booted", "--json"))["devices"]
        return any(
            device["udid"].upper() == self.serial and device["state"] == "Booted"
            for group in devices.values() for device in group
        )

    def power_off(self):
        if not self.is_booted():
            raise RuntimeError("Simulator already stopped; cannot guarantee a clean checkpoint")
        self.simctl("shutdown", self.serial, timeout=180)

        def stopped():
            devices = json.loads(self.simctl("list", "devices", "--json"))["devices"]
            return any(
                device["udid"].upper() == self.serial and device["state"] == "Shutdown"
                for group in devices.values() for device in group
            )

        wait_for(stopped, "Simulator shutdown before checkpoint", timeout=60)

    def close(self):
        if not self.creation_attempted:
            return
        devices = json.loads(self.simctl("list", "devices", "--json"))["devices"]
        owned = [
            device for group in devices.values() for device in group
            if (
                device["udid"].upper() == self.serial if self.serial else
                device["name"] == self.name
            )
        ]
        # A timeout/interrupt can happen after creation but before simctl returns
        # its UUID. Recover only our unique temporary name, never a default device.
        if not owned:
            return
        if len(owned) != 1:
            raise RuntimeError(
                f"Ambiguous Simulator ownership for {self.name}; refusing cleanup"
            )
        self.serial = str(uuid.UUID(owned[0]["udid"])).upper()
        try:
            if owned[0]["state"] != "Shutdown":
                self.simctl("shutdown", self.serial, timeout=60)
        finally:
            # Also delete a device whose boot failed. The shared Simulator UI
            # and any unrelated devices are left alone.
            self.simctl("delete", self.serial, timeout=60)


class SimulatorRecording:
    def __init__(self, simulator, session):
        self.simulator = simulator
        self.path = session / "recording.mp4"
        # Keep the .mp4 extension so simctl chooses the correct container.
        self.partial = session / "recording.partial.mp4"
        self.log = session / "recording.log"
        self.process = None

    def start(self):
        with self.log.open("w") as log:
            self.process = subprocess.Popen(
                [
                    "xcrun", "simctl", "io", self.simulator.serial, "recordVideo",
                    "--codec=h264", str(self.partial),
                ],
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )

        def ready():
            self.check()
            # simctl documents this acknowledgement after the first frame.
            # The MP4 may stay empty until SIGINT, so its size is not readiness.
            return "Recording started" in self.log.read_text().splitlines()

        wait_for(ready, "Simulator recording; see recording.log", timeout=30)

    def check(self):
        if self.process is not None and self.process.poll() is not None:
            raise RuntimeError("Simulator recording stopped unexpectedly; see recording.log")

    def stop(self):
        if self.process is None:
            return None
        unexpected = self.process.poll() is not None
        try:
            if not unexpected:
                self.process.send_signal(signal.SIGINT)
            status = self.process.wait(timeout=30)
            if unexpected or status != 0:
                raise RuntimeError("Simulator recording failed; see recording.log")
            if not self.partial.is_file() or self.partial.stat().st_size == 0:
                raise RuntimeError("Simulator recording is empty; see recording.log")
            self.partial.replace(self.path)
            return self.path
        finally:
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
