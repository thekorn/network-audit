import base64
import gzip
import http.client
import json
import os
import re
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from contextlib import contextmanager, redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import StringIO
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from android import Emulator, apk_identity, check_emulator, wait_for
from cli import audit, parser
from domains import matches, normalize_domains, proxy_pattern
from report import generate_report, read_events
from scenario import RUNNER, run_scenario, validate_executor

ROOT = Path(__file__).resolve().parents[1]


class AuditSessionTest(unittest.TestCase):
    def test_session_outcomes_preserve_reports(self):
        for outcome, state in (
            ("closed", "emulator closed"),
            ("background", "app closed"),
            ("interrupt", "interrupted by user"),
            ("launch failure", "failed"),
            ("proxy failure", "failed"),
        ):
            with (
                self.subTest(outcome=outcome),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory)
                apk = root / "app.apk"
                apk.touch()
                # Legacy app-wide configuration must no longer be read.
                (root / "network-audit.toml").write_text("not valid TOML")
                args = parser().parse_args(
                    [
                        str(apk),
                        "--output",
                        str(root / "runs"),
                        "--domain",
                        "CLI.test",
                        "--body-limit",
                        "37",
                        "--close-grace",
                        "2",
                        "--headless",
                    ]
                )
                proxy = Mock()
                proxy.poll.return_value = None
                device = Mock()
                device.serial = "emulator-5554"
                device.start.return_value.poll.return_value = (
                    0 if outcome == "closed" else None
                )
                elapsed = [0]

                def sleep(seconds):
                    elapsed[0] += seconds
                    self.assertLess(
                        elapsed[0], 10, "Capture did not finish after leaving the app"
                    )

                # A brief excursion must not consume the grace period of a
                # later excursion: the app returns before leaving for good.
                device.foreground.side_effect = lambda _: elapsed[0] in (0, 2)
                if outcome == "interrupt":
                    device.launch.side_effect = KeyboardInterrupt
                elif outcome == "launch failure":
                    device.launch.side_effect = subprocess.TimeoutExpired(
                        "adb", 30, stderr=b"launch timed out\xff"
                    )
                elif outcome == "proxy failure":
                    proxy.poll.side_effect = [None, 1, 1]

                def start_proxy(*_args, **kwargs):
                    session = Path(kwargs["env"]["NETWORK_AUDIT_SESSION"])
                    (session / "proxy.ready").touch()
                    command = _args[0]
                    ca = Path(
                        next(
                            v.split("=", 1)[1]
                            for v in command
                            if v.startswith("confdir=")
                        )
                    )
                    ca.mkdir()
                    (ca / "mitmproxy-ca-cert.pem").touch()
                    return proxy

                with (
                    patch("cli.shutil.which", return_value="tool"),
                    patch("cli.check_emulator", return_value="test-image"),
                    patch(
                        "cli.apk_identity", return_value=("org.example.app", ".Main")
                    ),
                    patch("cli.subprocess.Popen", side_effect=start_proxy),
                    patch("cli.Emulator", return_value=device),
                    patch("cli.time.sleep", side_effect=sleep),
                    patch("cli.time.monotonic", side_effect=lambda: elapsed[0]),
                    redirect_stdout(StringIO()) as output,
                ):
                    if state == "failed":
                        with self.assertRaises(RuntimeError):
                            audit(args)
                    else:
                        self.assertEqual(audit(args), 0)
                (session,) = (root / "runs").iterdir()
                metadata = json.loads((session / "session.json").read_text())
                self.assertEqual(metadata["state"], state)
                self.assertEqual(metadata["domains"], ["cli.test"])
                self.assertEqual(metadata["body_limit"], 37)
                self.assertEqual(metadata["device"], "emulator-5554")
                self.assertIn("ended", metadata)
                self.assertEqual(session.stat().st_mode & 0o777, 0o700)
                report = (session / "report.html").read_text()
                self.assertIn("No matching HTTP exchanges", report)
                # The CLI resolves symlinks, including macOS's /tmp -> /private/tmp.
                self.assertIn(
                    f"Report: {(session / 'report.html').resolve()}",
                    output.getvalue().splitlines(),
                )
                summary = (session / "report.txt").read_text()
                self.assertIn("No matching HTTP requests captured.", summary)
                self.assertIn("Total requests: 0", summary)
                self.assertIn(
                    f"Text report: {(session / 'report.txt').resolve()}",
                    output.getvalue().splitlines(),
                )
                self.assertTrue(output.getvalue().endswith(summary))
                if outcome == "launch failure":
                    self.assertEqual(metadata["failure"], "launch timed out\ufffd")
                    self.assertIn("launch timed out", report)
                elif outcome == "proxy failure":
                    self.assertIn("mitmdump stopped unexpectedly", metadata["failure"])
                elif outcome == "background":
                    self.assertEqual(elapsed[0], 5)

    def test_invalid_inputs_fail_before_creating_a_session(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            apk = root / "app.apk"
            apk.touch()
            (root / "network-audit.toml").write_text('domains = ["legacy.test"]')
            cases = [
                ([str(root / "missing.apk")], "App not found"),
                ([str(apk)], "No domains configured"),
                ([str(apk), "--domain", "https://example.com"], "Invalid domain"),
            ]
            for option, values in (
                ("--close-grace", ["0", "-1", "nan", "inf"]),
                ("--body-limit", ["0", "-1"]),
                ("--scenario-timeout", ["0", "-1", "nan", "inf"]),
            ):
                cases.extend(
                    ([str(apk), option, value], "must be positive") for value in values
                )
            for arguments, message in cases:
                with self.subTest(arguments=arguments):
                    args = parser().parse_args(
                        arguments + ["--output", str(root / "runs")]
                    )
                    with self.assertRaisesRegex(ValueError, message):
                        audit(args)
                    self.assertFalse((root / "runs").exists())

    def test_scenario_and_flutter_lockfile_are_validated_before_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "scenario.toml"
            module = root / "executor.mjs"
            module.write_text("export default async function () {}\n")
            args = parser().parse_args(
                [str(root), "--scenario", str(config), "--output", str(root / "runs")]
            )
            for filename, definition, message in (
                (config, None, "existing .toml"),
                (module, None, "existing .toml"),
                (config, "[broken", "Invalid scenario TOML"),
                (config, 'executor = "executor.mjs"', "No domains configured"),
                (config, 'domains = []', "No domains configured"),
                (config, 'domains = "config.test"', "list of hostnames"),
                (config, 'domains = [123]', "list of hostnames"),
                (config, 'domains = ["https://config.test"]', "Invalid domain"),
                (config, 'domains = ["config.test"]', "non-empty JavaScript path"),
                (
                    config,
                    'domains = ["config.test"]\nexecutor = "  "',
                    "non-empty JavaScript path",
                ),
                (
                    config,
                    'domains = ["config.test"]\nexecutor = ["executor.mjs"]',
                    "non-empty JavaScript path",
                ),
                (
                    config,
                    'domains = ["config.test"]\nexecutor = "missing.js"',
                    "existing .js or .mjs",
                ),
                (
                    config,
                    'domains = ["config.test"]\nexecutor = "scenario.toml"',
                    "existing .js or .mjs",
                ),
            ):
                with self.subTest(definition=definition, filename=filename):
                    if definition is not None:
                        config.write_text(definition)
                    args.scenario = filename
                    with self.assertRaisesRegex(ValueError, message):
                        audit(args)
                    self.assertFalse((root / "runs").exists())
            config.write_text('domains = ["config.test"]\nexecutor = "executor.mjs"')
            with patch(
                "cli.shutil.which",
                side_effect=lambda name: "node" if name == "node" else None,
            ):
                with self.assertRaisesRegex(RuntimeError, "Missing adb"):
                    audit(args)
            with (
                patch("cli.shutil.which", return_value="tool"),
                patch("cli.check_emulator", return_value="test-image"),
                self.assertRaisesRegex(ValueError, "committed pubspec.lock"),
            ):
                audit(args)
            self.assertFalse((root / "runs").exists())


class AndroidOutputTest(unittest.TestCase):
    def test_apk_identity_requires_safe_package_and_launcher_names(self):
        for package, activity, error in (
            ("org.example_app", "org.example_app.Main$Nested", None),
            ("org.example", ".Main", None),
            (None, ".Main", "launchable activity"),
            ("org.example", None, "launchable activity"),
            ("org.example;bad", ".Main", "Unsupported"),
            ("org.example", "Main/Other", "Unsupported"),
        ):
            info = "sdkVersion:'36'\n"
            if package is not None:
                info += f"package: name='{package}' versionCode='1'\n"
            if activity is not None:
                info += f"launchable-activity: name='{activity}' label='Example'\n"
            with (
                self.subTest(package=package, activity=activity),
                patch.dict(os.environ, {"ANDROID_HOME": "/unused-sdk"}),
                patch("android.run", return_value=info),
            ):
                if error:
                    with self.assertRaisesRegex(ValueError, error):
                        apk_identity(Path("app.apk"))
                else:
                    self.assertEqual(apk_identity(Path("app.apk")), (package, activity))

    def test_foreground_checks_only_resumed_activity_and_exact_package(self):
        with patch("android.emulator_port", return_value=5554):
            device = Emulator("unused", None, 8080, True, "test-image")
        for activities, expected in (
            ("mResumedActivity: ActivityRecord{abc u0 org.example/.Main t42}", True),
            ("topResumedActivity=ActivityRecord{abc u0 org.example/.Main t42}", True),
            (
                "mResumedActivity: ActivityRecord{abc u0 org.example.other/.Main t42}",
                False,
            ),
            ("mResumedActivity: ActivityRecord{abc u0 orgXexample/.Main t42}", False),
            (
                "mLastPausedActivity: org.example/.Main\nmResumedActivity: other/.Main",
                False,
            ),
            ("", False),
        ):
            with (
                self.subTest(activities=activities),
                patch.object(device, "shell", return_value=activities),
            ):
                self.assertEqual(device.foreground("org.example"), expected)

    def test_wait_for_retries_and_times_out_with_context(self):
        with (
            patch("android.time.sleep"),
            patch("android.time.monotonic", side_effect=range(20)),
        ):
            wait_for(Mock(side_effect=[False, True]), "ready", timeout=3)
        with (
            patch("android.time.sleep"),
            patch("android.time.monotonic", side_effect=range(20)),
            self.assertRaisesRegex(
                RuntimeError, "Timed out waiting for app foreground"
            ),
        ):
            wait_for(lambda: False, "app foreground", timeout=3)


class EmulatorOptionsTest(unittest.TestCase):
    def test_headless_default_depends_on_host_display(self):
        for host, display, expected in (
            ("linux", None, True),
            ("linux", "", True),
            ("linux", ":0", False),
            ("linux", "localhost:10.0", False),
            ("darwin", None, False),
        ):
            with (
                self.subTest(host=host, display=display),
                patch("cli.sys.platform", host),
                patch.dict(os.environ, {}, clear=True),
            ):
                if display is not None:
                    os.environ["DISPLAY"] = display
                self.assertEqual(parser().parse_args(["sample-app"]).headless, expected)
                self.assertTrue(
                    parser().parse_args(["sample-app", "--headless"]).headless
                )


@unittest.skipUnless(shutil.which("mitmdump"), "mitmdump is supplied by devenv")
class ScenarioAuditTest(unittest.TestCase):
    def test_completion_failure_and_interrupt_always_emit_report(self):
        # Exercise real proxy/report IO; Android and scenario outcomes are the
        # boundaries here. Native acceptance covers the actual Mobilewright UI.
        for outcome, state, exit_code, override in (
            (None, "scenario completed", 0, []),
            (
                RuntimeError("Scenario exited with status 7; see scenario.log"),
                "failed",
                1,
                ["--domain", "localhost"],
            ),
            (KeyboardInterrupt(), "interrupted by user", 130, []),
        ):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                apk = root / "sample.apk"
                apk.touch()
                scenario = root / "scenarios with spaces" / "browse.toml"
                scenario.parent.mkdir()
                executor = root / ("executor.js" if override else "executor.mjs")
                source = "export default async function () {}\n"
                executor.write_text(source)
                # Relative paths belong to the manifest, not the app or cwd;
                # absolute executor paths also work, and CLI domains replace.
                domains = ["config.test"] if override else ["LOCALHOST.", "localhost"]
                path = str(executor) if override else "../executor.mjs"
                scenario.write_text(
                    f"domains = {json.dumps(domains)}\nexecutor = {json.dumps(path)}\n"
                )
                args = parser().parse_args(
                    [
                        str(apk),
                        *override,
                        "--scenario",
                        str(scenario),
                        "--output",
                        str(root / "runs"),
                    ]
                )

                def execute(path, *, session, **_kwargs):
                    (session / "scenario.log").write_text(path.read_text())
                    if outcome:
                        raise outcome

                output = StringIO()
                with (
                    patch("cli.shutil.which", return_value="available"),
                    patch("cli.check_emulator", return_value="test-image"),
                    patch("cli.apk_identity", return_value=("test.app", "Main")),
                    patch("cli.Emulator") as emulator,
                    patch("cli.run_scenario", side_effect=execute),
                    redirect_stdout(output),
                ):
                    emulator.return_value.serial = "emulator-5580"
                    emulator.return_value.foreground.return_value = True
                    if exit_code == 1:
                        with self.assertRaisesRegex(RuntimeError, "status 7"):
                            audit(args)
                    else:
                        self.assertEqual(audit(args), exit_code)
                (session,) = (root / "runs").iterdir()
                metadata = json.loads((session / "session.json").read_text())
                self.assertEqual(metadata["state"], state)
                self.assertEqual(metadata["scenario"], str(scenario.resolve()))
                self.assertEqual(metadata["executor"], str(executor.resolve()))
                self.assertEqual(metadata["domains"], ["localhost"])
                self.assertEqual(metadata["device"], "emulator-5580")
                self.assertEqual((session / "scenario.log").read_text(), source)
                self.assertIn(state, (session / "report.html").read_text())
                self.assertIn(
                    f"Report: {(session / 'report.html').resolve()}",
                    output.getvalue().splitlines(),
                )


class ScenarioProcessTest(unittest.TestCase):
    def test_native_android_locators_use_accessibility_labels_and_webview_children(self):
        # Exercise the packaged driver through real Mobilewright locators and a
        # subprocess CLI boundary. The device's accessibility service is the fixture.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dump = root / "dump.json"
            binary = root / "mobilecli fixture"
            attributes = {
                "text": "",
                "content-desc": "",
                "rect": {"x": 19, "y": 83, "width": 211, "height": 37},
                "visible": True,
                "enabled": True,
                "children": None,
            }
            hierarchy = [
                {
                    **attributes,
                    "class": "android.widget.FrameLayout",
                    "children": [
                        {
                            **attributes,
                            "class": "android.widget.Button",
                            "content-desc": "BUNTE, Tab 2 of 2",
                        },
                        {
                            **attributes,
                            "class": "android.webkit.WebView",
                            "children": [
                                {
                                    **attributes,
                                    "class": "android.widget.Button",
                                    "text": "AKZEPTIEREN",
                                    "resource-id": "consent-accept",
                                }
                            ],
                        },
                        {
                            **attributes,
                            "class": "android.widget.Button",
                            "text": "Hidden button",
                            "visible": False,
                        },
                    ],
                }
            ]
            dump.write_text(
                json.dumps(
                    {
                        "status": "ok",
                        "data": {"rawData": json.dumps({"hierarchy": hierarchy})},
                    }
                )
            )
            binary.write_text(
                f"#!{shutil.which('node')}\n"
                + """
const fs = require('node:fs');
const args = process.argv.slice(2);
if (args[args.indexOf('--device') + 1] !== 'owned-device' ||
    args[args.indexOf('--format') + 1] !== 'raw') process.exit(1);
process.stdout.write(fs.readFileSync(__dirname + '/dump.json'));
"""
            )
            binary.chmod(0o700)
            script = """
import assert from 'node:assert/strict';
import { writeFileSync } from 'node:fs';
import { Screen } from 'mobilewright';
import { NativeAndroidDriver } from './native-android-driver.mjs';
const driver = new NativeAndroidDriver({
  deviceId: 'owned-device', mobilecliPath: process.argv[1],
});
const screen = new Screen(driver);
assert.equal(await screen.getByRole('button', { name: /^BUNTE/ }).isVisible(), true);
assert.equal(await screen.getByText(/^akzeptieren$/i).isVisible(), true);
assert.equal(await screen.getByTestId('consent-accept').isVisible(), true);
assert.equal(await screen.getByText('Hidden button').isVisible(), false);
assert.equal(await screen.getByText('Absent button').isVisible(), false);
writeFileSync(process.argv[2], JSON.stringify({ data: { rawData: '<hierarchy/>' } }));
await assert.rejects(driver.getViewHierarchy(), /DeviceServer JSON hierarchy/);
"""
            result = subprocess.run(
                ["node", "--input-type=module", "-e", script, str(binary), str(dump)],
                cwd=RUNNER.parent,
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_invalid_modules_fail_before_connecting_to_a_device(self):
        with tempfile.TemporaryDirectory() as directory:
            session = Path(directory)
            module = session / "invalid scenario.mjs"
            with self.assertRaisesRegex(ValueError, "existing .js or .mjs"):
                validate_executor(module)
            module.write_text("export default async function ( {\n")
            with self.assertRaisesRegex(RuntimeError, "SyntaxError"):
                validate_executor(module)
            for suffix in (".js", ".mjs"):
                with self.subTest(suffix=suffix):
                    module = session / f"invalid scenario{suffix}"
                    module.write_text("export const wrong = 1;\n")
                    self.assertEqual(validate_executor(module), module.resolve())
                    with self.assertRaisesRegex(RuntimeError, "status 1"):
                        run_scenario(
                            module,
                            serial="not-a-device",
                            device_id="test-avd",
                            package="test.app",
                            session=session,
                            timeout=10,
                            check_running=lambda: None,
                        )
                    self.assertIn(
                        "must export default async function",
                        (session / "scenario.log").read_text(),
                    )

    def test_timeout_stops_a_modules_child_process_too(self):
        with tempfile.TemporaryDirectory() as directory:
            session = Path(directory)
            module = session / "hanging scenario.mjs"
            # Hang at module load, before discovery; the child ignores SIGTERM
            # so this checks forced process-group cleanup, not just Node exit.
            module.write_text("""
import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
const child = spawn(process.execPath, ['-e',
  'process.on("SIGTERM", () => {}); setInterval(() => {}, 1000)']);
writeFileSync(new URL('./child.pid', import.meta.url), String(child.pid));
const home = process.env.MOBILECLI_HOME;
const daemon = JSON.parse(readFileSync(`${home}/daemon.pid`, 'utf8'));
writeFileSync(new URL('./daemon.json', import.meta.url), JSON.stringify({ home, pid: daemon.pid }));
console.log('scenario is hanging');
await new Promise(() => {});
""")
            ambient_home = session / "unrelated-mobilecli"
            ambient_home.mkdir()
            with (
                patch.dict(os.environ, {"MOBILECLI_HOME": str(ambient_home)}),
                self.assertRaisesRegex(RuntimeError, "timed out"),
            ):
                run_scenario(
                    module,
                    serial="not-a-device",
                    device_id="test-avd",
                    package="test.app",
                    session=session,
                    timeout=3,
                    check_running=lambda: None,
                )
            daemon = json.loads((session / "daemon.json").read_text())
            self.assertNotEqual(Path(daemon["home"]), ambient_home)
            self.assertEqual(list(ambient_home.iterdir()), [])
            self.assertFalse(Path(daemon["home"]).exists())
            for pid in (int((session / "child.pid").read_text()), daemon["pid"]):
                # A terminated orphan can briefly be a zombie until init reaps it.
                state = subprocess.run(
                    ["ps", "-o", "stat=", "-p", str(pid)],
                    text=True,
                    capture_output=True,
                ).stdout.strip()
                self.assertTrue(not state or state.startswith("Z"), state)
            self.assertIn("scenario is hanging", (session / "scenario.log").read_text())


def create_avd(args, **kwargs):
    name = args[args.index("--name") + 1]
    config = Path(kwargs["env"]["ANDROID_AVD_HOME"]) / f"{name}.avd" / "config.ini"
    config.parent.mkdir(parents=True)
    config.write_text("hw.ramSize=2048\ndisk.dataPartition.size=12G\n")
    return ""


class EmulatorPreflightTest(unittest.TestCase):
    def test_transport_identity_and_cleanup_on_each_host(self):
        for host in ("darwin", "linux"):
            with self.subTest(host=host), tempfile.TemporaryDirectory() as directory:
                emulator = Emulator(directory, None, 8080, True, "test-image")
                console = emulator.serial
                connections = {"unrelated-device"}
                running = [True]
                process = Mock()
                process.poll.side_effect = lambda: None if running[0] else 0

                def command(args, **kwargs):
                    if args[0] == "avdmanager":
                        return create_avd(args, **kwargs)
                    if args[1] == "connect":
                        connections.add(args[2])
                        return "connected"
                    if args[1] == "disconnect":
                        connections.remove(args[2])
                        return "disconnected"
                    serial, *action = args[2:]
                    if action == ["emu", "kill"] and serial == console:
                        running[0] = False
                    if action == ["shell", "getprop sys.boot_completed"]:
                        return "1"
                    if action == ["shell", "id -u"]:
                        return "0"
                    if action == ["shell", "getprop ro.boot.qemu.avd_name"]:
                        return Path(directory).name
                    if action == ["shell", "echo transport"]:
                        return serial
                    return "OK"

                with (
                    patch("android.sys.platform", host),
                    patch("android.shutil.disk_usage", return_value=Mock(free=8 * 1024**3)),
                    patch("android.run", side_effect=command),
                    patch("android.subprocess.Popen", return_value=process),
                ):
                    emulator.start()
                    if host == "darwin":
                        self.assertRegex(emulator.serial, r"^127\.0\.0\.1:\d+$")
                        self.assertEqual(emulator.device_id, emulator.serial)
                        self.assertIn(emulator.serial, connections)
                    else:
                        self.assertEqual(emulator.serial, console)
                        self.assertEqual(emulator.device_id, Path(directory).name)
                    self.assertEqual(emulator.shell("echo transport"), emulator.serial)
                    emulator.close()
                self.assertFalse(running[0], "Shutdown must address the emulator console")
                self.assertEqual(connections, {"unrelated-device"})

    def test_transport_setup_rejects_busy_ports_and_wrong_devices(self):
        for replies, message in (
            (["KO: port is busy"], "Could not forward emulator ADB"),
            (["OK", "connected", "0", "unrelated-avd"], "did not reach the owned emulator"),
        ):
            with self.subTest(message=message), tempfile.TemporaryDirectory() as directory:
                emulator = Emulator(directory, None, 8080, True, "test-image")
                console = emulator.serial
                process = Mock()
                process.poll.return_value = None
                responses = iter(["1", "0", *replies])

                def command(args, **kwargs):
                    if args[0] == "avdmanager":
                        return create_avd(args, **kwargs)
                    return next(responses)

                with (
                    patch("android.sys.platform", "darwin"),
                    patch("android.shutil.disk_usage", return_value=Mock(free=8 * 1024**3)),
                    patch("android.subprocess.Popen", return_value=process),
                    patch("android.run", side_effect=command),
                    self.assertRaisesRegex(RuntimeError, message),
                ):
                    emulator.start()
                if replies[0].startswith("KO"):
                    self.assertEqual(emulator.serial, console)
                    self.assertEqual(emulator.device_id, Path(directory).name)

    def test_start_limits_storage_for_the_unique_avd(self):
        with tempfile.TemporaryDirectory(prefix="network-audit-") as directory:
            device = Emulator(directory, None, 8080, True, "test-image")

            with (
                patch("android.shutil.disk_usage", return_value=Mock(free=8 * 1024**3)),
                patch("android.run", side_effect=create_avd),
                patch("android.subprocess.Popen"),
                patch("android.wait_for"),
                patch.object(device, "adb", return_value="OK"),
                patch.object(device, "shell"),
            ):
                device.start()

            config = Path(directory) / "avd" / f"{device.name}.avd" / "config.ini"
            self.assertEqual(
                dict(line.split("=", 1) for line in config.read_text().splitlines()),
                {"hw.ramSize": "2048", "disk.dataPartition.size": "6G"},
            )

    def test_launch_accepts_first_draw_timeout_but_rejects_start_errors(self):
        emulator = Emulator("/unused", None, 8080, True, "test-image")
        for status in ("ok", "timeout"):
            output = (
                f"Status: {status}\nLaunchState: UNKNOWN (-1)\n"
                "Activity: test.app/.MainActivity\nWaitTime: 10987\nComplete"
            )
            with (
                self.subTest(status=status),
                patch("android.run", side_effect=["Success", output]),
            ):
                emulator.launch(Path("sample.apk"), "test.app", ".MainActivity")
        for output in ("Error: Activity class does not exist", "Status: failed", ""):
            with (
                self.subTest(output=output),
                patch("android.run", side_effect=["Success", output]),
                self.assertRaisesRegex(RuntimeError, "App did not launch"),
            ):
                emulator.launch(Path("sample.apk"), "test.app", ".MainActivity")

    def test_supported_hosts_use_the_declared_image(self):
        for host, machine, abi, kvm in (
            ("darwin", "arm64", "arm64-v8a", False),
            ("darwin", "aarch64", "arm64-v8a", False),
            ("linux", "x86_64", "x86_64", True),
        ):
            with (
                self.subTest(host=host, machine=machine),
                tempfile.TemporaryDirectory() as sdk,
            ):
                image = f"system-images;android-36;google_apis;{abi}"
                package = Path(sdk).joinpath(*image.split(";")) / "package.xml"
                package.parent.mkdir(parents=True)
                package.touch()
                with (
                    patch("android.sys.platform", host),
                    patch("android.platform.machine", return_value=machine),
                    patch("android.os.access", return_value=kvm),
                    patch("android.shutil.disk_usage", return_value=Mock(free=8 * 1024**3)),
                    patch.dict(
                        os.environ,
                        {"ANDROID_HOME": sdk, "NETWORK_AUDIT_SYSTEM_IMAGE": image},
                    ),
                    patch(
                        "android.subprocess.run",
                        return_value=subprocess.CompletedProcess(
                            ["emulator", "-accel-check"],
                            0,
                            stdout="accel:\n0\nusable\naccel",
                        ),
                    ),
                ):
                    self.assertEqual(check_emulator(), image)
                    with (
                        patch("android.tempfile.gettempdir", return_value="/chosen-volume"),
                        patch(
                            "android.shutil.disk_usage",
                            return_value=Mock(free=8 * 1024**3 - 1),
                        ),
                        patch("cli.shutil.which", return_value="available"),
                        self.assertRaisesRegex(
                            RuntimeError,
                            "Insufficient emulator storage at /chosen-volume:.*"
                            "need at least 8 GiB.*TMPDIR.*--output",
                        ),
                    ):
                        # A Flutter directory without a lockfile would fail at
                        # build preparation if the storage preflight were late.
                        audit(parser().parse_args([sdk, "--domain", "example.test"]))
                    with (
                        patch(
                            "android.subprocess.run",
                            side_effect=subprocess.CalledProcessError(
                                1,
                                ["emulator", "-accel-check"],
                                output="accel:\n1\ndisabled",
                                stderr="hypervisor unavailable",
                            ),
                        ),
                        self.assertRaisesRegex(
                            RuntimeError,
                            "(?s)unavailable.*disabled.*hypervisor unavailable",
                        ),
                    ):
                        check_emulator()
                    package.unlink()
                    with self.assertRaisesRegex(
                        RuntimeError, "Missing system-images.*androidEmulator.enable"
                    ):
                        check_emulator()
                    with (
                        patch.dict(os.environ, {}, clear=True),
                        self.assertRaisesRegex(RuntimeError, "Enter devenv"),
                    ):
                        check_emulator()

    def test_unsupported_hosts_and_linux_without_kvm_are_rejected(self):
        for host, machine, message in (
            ("darwin", "x86_64", "Intel Macs"),
            ("linux", "aarch64", "Unsupported host"),
            ("win32", "AMD64", "Unsupported host"),
            ("linux", "x86_64", "/dev/kvm"),
        ):
            with (
                self.subTest(host=host, machine=machine),
                patch("android.sys.platform", host),
                patch("android.platform.machine", return_value=machine),
                patch("android.os.access", return_value=False),
                self.assertRaisesRegex(RuntimeError, message),
            ):
                check_emulator()


class DomainsTest(unittest.TestCase):
    def test_exact_and_wildcard_have_hostname_boundaries(self):
        domains = normalize_domains(["*.BUNTE.de", "dummyjson.com."])
        for host in ("www.bunte.de", "a.b.bunte.de", "dummyjson.com"):
            self.assertTrue(matches(host, domains), host)
            self.assertIsNotNone(re.fullmatch(proxy_pattern(domains), host + ":443"))
        for host in (
            "bunte.de",
            "evilbunte.de",
            "dummyjson.com.attacker.net",
            "sub.dummyjson.com",
            "127.0.0.1",
        ):
            self.assertFalse(matches(host, domains), host)
            self.assertIsNone(re.fullmatch(proxy_pattern(domains), host + ":443"))
        for invalid in (
            "https://bunte.de",
            "*bunte.de",
            "foo:443",
            "foo..com",
            "x/",
            "-foo.com",
        ):
            with self.assertRaises(ValueError):
                normalize_domains([invalid])
        for invalid in ("example.com", None, [123], []):
            with self.assertRaises(ValueError):
                normalize_domains(invalid)


class ReportTest(unittest.TestCase):
    def test_report_command_summarizes_unique_requests_per_host(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "session.json").write_text(
                json.dumps(
                    {
                        "app": "Summary contract",
                        "domains": ["assets.test", "api.test", "*.api.test"],
                        "started": "2026-10-10T10:00:00Z",
                        "state": "interrupted",
                    }
                )
            )
            first = {
                "id": "first",
                "host": "assets.test",
                "started": 10,
                "response": None,
                "error": None,
            }
            events = [
                first,
                {**first, "response": {"status": 200}},
                {
                    **first,
                    "id": "http-error",
                    "host": "api.test",
                    "started": 20,
                    "response": {"status": 503},
                },
                {
                    **first,
                    "id": "transport-error",
                    "host": "api.test",
                    "started": 30,
                    "error": "connection reset",
                },
                {**first, "id": "pending", "host": "api.test", "started": 40},
                {**first, "id": "subdomain", "host": "sub.api.test", "started": 50},
                {"diagnostic": "TLS client failure for api.test"},
            ]
            (path / "events.jsonl").write_text(
                "\n".join(json.dumps(event) for event in events) + '\n{"id":'
            )
            result = subprocess.run(
                [sys.executable, str(ROOT / "cli.py"), "report", str(path)],
                check=True,
                capture_output=True,
                text=True,
            )
            summary = (path / "report.txt").read_text()
            self.assertEqual(
                summary,
                "Requests per domain:\n"
                "api.test: 3\n"
                "assets.test: 1\n"
                "sub.api.test: 1\n"
                "Total requests: 5\n",
            )
            self.assertIn(
                str((path / "report.html").resolve()), result.stdout.splitlines()
            )
            self.assertIn(
                f"Text report: {(path / 'report.txt').resolve()}",
                result.stdout.splitlines(),
            )
            self.assertTrue(result.stdout.endswith(summary))
            self.assertIn("Summary contract", (path / "report.html").read_text())

    def test_event_recovery_keeps_latest_state_and_sorts_by_start_time(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "events.jsonl"
            early = {"id": "early", "started": 10, "response": None}
            late = {"id": "late", "started": 20, "response": None}
            complete = {**early, "response": {"status": 503}}
            path.write_text(
                "\n".join(
                    [
                        json.dumps(late),
                        json.dumps(early),
                        '{"id":',
                        json.dumps({"diagnostic": "TLS server failure"}),
                        json.dumps(complete),
                    ]
                )
            )
            flows, diagnostics = read_events(path)
            self.assertEqual(flows, [complete, late])
            self.assertEqual(
                diagnostics,
                [
                    "Unreadable capture record at line 3 (possibly interrupted write)",
                    "TLS server failure",
                ],
            )

    def test_empty_and_interrupted_reports_escape_network_data(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "session.json").write_text(
                json.dumps(
                    {
                        "app": "<img src=x onerror=alert(1)>@@DATA@@",
                        "domains": ["example.test"],
                        "started": "2026-10-10T10:00:00Z",
                        "state": "failed",
                        "failure": "</script><script>alert(1)</script>",
                    }
                )
            )
            report = generate_report(path).read_text()
            self.assertIn("&lt;img", report)
            self.assertNotIn("<script>alert(1)</script>", report)
            self.assertIn('"flows": []', report)
            (path / "events.jsonl").write_text('{"id":')
            self.assertIn(
                "Unreadable capture record", generate_report(path).read_text()
            )


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            # The untrusted-client test deliberately aborts TLS while mitmproxy
            # may already have an idle origin connection for certificate lookup.
            pass

    def log_message(self, format, *args):
        pass

    def do_GET(self):
        if self.path == "/disconnect":
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        body = gzip.compress(
            b'{"answer":42,"markup":"</script><img src=x onerror=alert(1)>"}'
        )
        self.send_response(418 if self.path == "/error" else 200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Encoding", "gzip")
        self.send_header("Set-Cookie", "first=1")
        self.send_header("Set-Cookie", "second=2")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(201)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


@contextmanager
def proxy_session(directory, extra=(), limit=1048576):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    ca = directory / "ca"
    env = {
        **os.environ,
        "NETWORK_AUDIT_SESSION": str(directory),
        "NETWORK_AUDIT_DOMAINS": '["localhost"]',
        "NETWORK_AUDIT_BODY_LIMIT": str(limit),
    }
    with (directory / "console.log").open("w") as log:
        process = subprocess.Popen(
            [
                "mitmdump",
                "-q",
                "--listen-host",
                "127.0.0.1",
                "--listen-port",
                str(port),
                "--set",
                f"confdir={ca}",
                "--set",
                f"allow_hosts={proxy_pattern(['localhost'])}",
                "-s",
                str(ROOT / "capture.py"),
                *extra,
            ],
            env=env,
            stdout=log,
            stderr=log,
        )
        try:
            deadline = time.monotonic() + 20
            while not (directory / "proxy.ready").exists():
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError((directory / "console.log").read_text())
                time.sleep(0.1)
            yield port, ca
        finally:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


@unittest.skipUnless(shutil.which("mitmdump"), "mitmdump is supplied by devenv")
class CaptureTest(unittest.TestCase):
    def test_http_capture_filter_errors_binary_and_full_raw_flow(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory)
                origin_port = server.server_port
                with proxy_session(path, limit=20) as (port, _):
                    for host, endpoint, expected in (
                        ("localhost", "/ok", 200),
                        ("localhost", "/error", 418),
                        ("127.0.0.1", "/excluded", 200),
                        ("localhost", "/disconnect", 502),
                    ):
                        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
                        conn.request("GET", f"http://{host}:{origin_port}{endpoint}")
                        response = conn.getresponse()
                        self.assertEqual(response.status, expected)
                        response.read()
                        conn.close()
                    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
                    body = bytes(range(256))
                    conn.request(
                        "POST",
                        f"http://localhost:{origin_port}/binary",
                        body,
                        {"Content-Type": "application/octet-stream"},
                    )
                    self.assertEqual(conn.getresponse().read(), body)
                    conn.close()
                flows, diagnostics = read_events(path / "events.jsonl")
                self.assertEqual(len(flows), 4)
                self.assertEqual(diagnostics, [])
                ok = next(f for f in flows if f["url"].endswith("/ok"))
                self.assertEqual(ok["response"]["status"], 200)
                self.assertTrue(ok["response"]["body_text"].startswith('{"answer":42'))
                self.assertTrue(ok["response"]["truncated"])
                cookies = [
                    v for k, v in ok["response"]["headers"] if k.lower() == "set-cookie"
                ]
                self.assertEqual(cookies, ["first=1", "second=2"])
                self.assertTrue(
                    next(f for f in flows if f["url"].endswith("/disconnect"))["error"]
                )
                binary = next(f for f in flows if f["method"] == "POST")
                self.assertEqual(
                    base64.b64decode(binary["request"]["body_base64"]), body[:20]
                )
                self.assertEqual(binary["response"]["bytes"], 256)
                self.assertIn(body, (path / "flows.mitm").read_bytes())
                self.assertNotIn("/excluded", (path / "console.log").read_text())
        finally:
            server.shutdown()
            server.server_close()

    def test_tls_connect_to_ip_uses_sni_and_installed_ca(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            cert, key = path / "origin.pem", path / "origin.key"
            subprocess.run(
                [
                    "openssl",
                    "req",
                    "-x509",
                    "-newkey",
                    "rsa:2048",
                    "-nodes",
                    "-keyout",
                    str(key),
                    "-out",
                    str(cert),
                    "-days",
                    "1",
                    "-subj",
                    "/CN=localhost",
                    "-addext",
                    "subjectAltName=DNS:localhost",
                ],
                check=True,
                capture_output=True,
            )
            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(cert, key)
            server.socket = context.wrap_socket(server.socket, server_side=True)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                with proxy_session(
                    path, ["--set", f"ssl_verify_upstream_trusted_ca={cert}"]
                ) as (port, ca):
                    # Match the emulator: CONNECT to an IP, then TLS with hostname SNI.
                    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
                    sock.sendall(
                        f"CONNECT 127.0.0.1:{server.server_port} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".encode()
                    )
                    headers = b""
                    while not headers.endswith(b"\r\n\r\n"):
                        chunk = sock.recv(1)
                        self.assertTrue(chunk, "Proxy closed the CONNECT tunnel")
                        headers += chunk
                    self.assertIn(b"200", headers)
                    trusted = ssl.create_default_context(
                        cafile=str(ca / "mitmproxy-ca-cert.pem")
                    )
                    tls = trusted.wrap_socket(sock, server_hostname="localhost")
                    tls.sendall(
                        b"GET /tls HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
                    )
                    response = http.client.HTTPResponse(tls)
                    response.begin()
                    self.assertEqual(response.status, 200)
                    self.assertEqual(
                        json.loads(gzip.decompress(response.read()))["answer"], 42
                    )
                    tls.close()
                    # A client without our CA must fail, and produce a TLS
                    # diagnostic rather than an invented HTTP exchange.
                    untrusted = http.client.HTTPSConnection(
                        "127.0.0.1",
                        port,
                        timeout=10,
                        context=ssl.create_default_context(),
                    )
                    untrusted.set_tunnel("localhost", server.server_port)
                    with self.assertRaises(ssl.SSLCertVerificationError):
                        untrusted.request("GET", "/untrusted")
                    untrusted.close()
                flows, diagnostics = read_events(path / "events.jsonl")
                self.assertEqual(len(flows), 1)
                self.assertTrue(
                    any("TLS client failure for localhost" in d for d in diagnostics)
                )
                self.assertEqual(flows[0]["host"], "localhost")
                self.assertIn('"answer":42', flows[0]["response"]["body_text"])
                (path / "session.json").write_text(
                    json.dumps(
                        {
                            "app": "TLS contract",
                            "domains": ["localhost"],
                            "started": "2026-10-10",
                            "state": "complete",
                        }
                    )
                )
                report = generate_report(path).read_text()
                self.assertNotIn("</script><img src=x", report)
                self.assertIn("\\u003c/script\\u003e", report)
            finally:
                server.shutdown()
                server.server_close()


if __name__ == "__main__":
    unittest.main()
