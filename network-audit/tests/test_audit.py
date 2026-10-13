import base64
import gzip
import http.client
import json
import os
import plistlib
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
from contextlib import chdir, contextmanager, nullcontext, redirect_stderr, redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import StringIO
from itertools import product
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from android import Emulator, apk_identity, check_emulator, wait_for
from cli import audit, parser
from domains import matches, normalize_domains, proxy_pattern
from ios import SimulatorRecording, app_identity, build_app, check_simulator
from recording import ScreenRecording
from report import generate_report, read_events
from scenario import RUNNER, run_scenario, validate_executor

ROOT = Path(__file__).resolve().parents[1]


class AuditSessionTest(unittest.TestCase):
    def test_session_outcomes_preserve_reports(self):
        for outcome, state, options in (
            ("closed", "emulator closed", []),
            ("closed", "emulator closed", ["--use-fvm"]),
            ("background", "app closed", []),
            ("interrupt", "interrupted by user", []),
            ("launch failure", "failed", []),
            ("proxy failure", "failed", []),
            ("background", "app closed", ["--record"]),
            ("interrupt", "interrupted by user", ["--record"]),
            ("launch failure", "failed", ["--record"]),
            ("recording start failure", "failed", ["--record"]),
            ("recording stopped", "failed", ["--record"]),
            ("recording save failure", "failed", ["--record"]),
            ("launch and recording failure", "failed", ["--record"]),
        ):
            with (
                self.subTest(outcome=outcome, options=options),
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
                        *options,
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
                if outcome == "proxy failure":
                    proxy.poll.side_effect = [None, 1, 1]

                running = {"emulator", "proxy"}
                device.close.side_effect = lambda: running.remove("emulator")
                proxy.send_signal.side_effect = lambda _: running.remove("proxy")

                def launch(*_args):
                    if "--record" in options:
                        self.assertIn("recording", running, "App launch must be recorded")
                    if outcome == "interrupt":
                        raise KeyboardInterrupt
                    if outcome.startswith("launch"):
                        raise subprocess.TimeoutExpired(
                            "adb", 30, stderr=b"launch timed out\xff"
                        )

                device.launch.side_effect = launch

                def recorder(_device, session):
                    self.assertIn("--record", options, "Recording must be opt-in")
                    result = Mock()

                    def start():
                        if outcome == "recording start failure":
                            raise RuntimeError("encoder unavailable")
                        running.add("recording")

                    def stop():
                        self.assertIn("emulator", running, "Video needs the live device")
                        running.discard("recording")
                        if outcome in (
                            "recording save failure", "launch and recording failure"
                        ):
                            raise RuntimeError("video transfer failed")
                        if outcome == "recording start failure":
                            return None
                        video = session / "recording.mp4"
                        video.write_bytes(b"finalized video fixture")
                        return video

                    result.start.side_effect = start
                    result.stop.side_effect = stop
                    if outcome == "recording stopped":
                        result.check.side_effect = RuntimeError("encoder exited")
                    return result

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
                    patch(
                        "cli.shutil.which",
                        side_effect=lambda name: (
                            None if name in ("flutter", "fvm") else "tool"
                        ),
                    ),
                    patch("cli.check_emulator", return_value="test-image"),
                    patch(
                        "cli.apk_identity", return_value=("org.example.app", ".Main")
                    ),
                    patch("cli.subprocess.Popen", side_effect=start_proxy),
                    patch("cli.Emulator", return_value=device),
                    patch("cli.time.sleep", side_effect=sleep),
                    patch("cli.time.monotonic", side_effect=lambda: elapsed[0]),
                    patch("cli.ScreenRecording", side_effect=recorder),
                    redirect_stderr(StringIO()) as errors,
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
                self.assertNotIn("emulator", running)
                self.assertNotIn("recording", running)
                if outcome != "proxy failure":
                    self.assertNotIn("proxy", running)
                if "--record" in options and outcome not in (
                    "recording start failure",
                    "recording save failure",
                    "launch and recording failure",
                ):
                    self.assertEqual(metadata["recording"], "recording.mp4")
                    self.assertEqual(
                        (session / "recording.mp4").read_bytes(), b"finalized video fixture"
                    )
                    self.assertIn(
                        f"Video: {(session / 'recording.mp4').resolve()}",
                        output.getvalue().splitlines(),
                    )
                else:
                    self.assertNotIn("recording", metadata)
                    self.assertFalse((session / "recording.mp4").exists())
                    self.assertNotIn("Video:", output.getvalue())
                if outcome in ("recording save failure", "launch and recording failure"):
                    self.assertIn("video transfer failed", metadata["recording_failure"])
                    self.assertIn("video transfer failed", errors.getvalue())
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
                if outcome.startswith("launch"):
                    self.assertEqual(metadata["failure"], "launch timed out\ufffd")
                    self.assertIn("launch timed out", report)
                elif outcome == "proxy failure":
                    self.assertIn("mitmdump stopped unexpectedly", metadata["failure"])
                elif outcome == "background":
                    self.assertEqual(elapsed[0], 5)

    def test_flutter_build_uses_selected_executable_in_project_directory(self):
        build_cases = [
            (mode, None, None, None, "app-debug.apk")
            for mode in (
                "none", "single", "repeated", "comma-separated",
                "scenario-relative", "scenario-absolute", "scenario-override",
            )
        ] + [
            ("single", None, "freeStaging", "freeStaging", "app-freestaging-debug.apk"),
            ("scenario-relative", "staging", None, "staging", "app-staging-debug.apk"),
            ("scenario-relative", None, "dev", "dev", "app-dev-debug.apk"),
            ("scenario-override", "staging", "paidProd", "paidProd", "app-paidprod-debug.apk"),
        ]
        for (options, tool, prefix), build_case in product(
            (([], "flutter", []), (["--use-fvm"], "fvm", ["flutter"])),
            build_cases,
        ):
            define_mode, scenario_flavor, cli_flavor, expected_flavor, apk_name = build_case
            with (
                self.subTest(tool=tool, build_case=build_case),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory).resolve()
                app = root / "project with spaces"
                app.mkdir()
                (app / "pubspec.lock").touch()
                base = root / "base config.json"
                base.write_text('{"API_URL": "https://base.test"}')
                override = root / "override.env"
                override.write_text("API_URL=https://override.test\n")
                define_options, define_arguments = {
                    "none": ([], []),
                    "single": (
                        ["--dart-define-from-file", base.name],
                        [f"--dart-define-from-file={base}"],
                    ),
                    "repeated": (
                        [
                            f"--dart-define-from-file={base.name}",
                            "--dart-define-from-file",
                            str(override),
                        ],
                        [
                            f"--dart-define-from-file={base}",
                            f"--dart-define-from-file={override}",
                        ],
                    ),
                    "comma-separated": (
                        [f"--dart-define-from-file={base.name},{override}"],
                        [
                            f"--dart-define-from-file={base}",
                            f"--dart-define-from-file={override}",
                        ],
                    ),
                    "scenario-relative": ([], [f"--dart-define-from-file={base}"]),
                    "scenario-absolute": ([], [f"--dart-define-from-file={base}"]),
                    "scenario-override": (
                        [f"--dart-define-from-file={override.name}"],
                        [f"--dart-define-from-file={override}"],
                    ),
                }[define_mode]
                scenario_options = []
                if define_mode.startswith("scenario-"):
                    scenario = root / "scenarios with spaces" / "browse.toml"
                    scenario.parent.mkdir()
                    (scenario.parent / "browse.mjs").write_text(
                        "export default async function () {}\n"
                    )
                    env_file = str(base) if define_mode == "scenario-absolute" else f"../{base.name}"
                    scenario.write_text(
                        f'executor = "browse.mjs"\nenv-file = {json.dumps(env_file)}\n'
                        + (f'flavor = {json.dumps(scenario_flavor)}\n' if scenario_flavor else "")
                    )
                    scenario_options = ["--scenario", str(scenario)]
                    if define_mode == "scenario-override":
                        # An explicit CLI file replaces, not layers onto, the
                        # default, even if that default is absent locally.
                        base.unlink()
                bin_dir = root / "bin"
                bin_dir.mkdir()
                executable = bin_dir / tool
                # Real subprocesses record their argv/cwd. Flavor builds succeed
                # and reach APK inspection; other cases still check build errors.
                # Both failures must propagate without starting a capture session.
                apk = app / "build/app/outputs/flutter-apk" / apk_name
                apk.parent.mkdir(parents=True)
                apk.write_bytes(b"built APK fixture")
                executable.write_text(
                    f"#!{sys.executable}\n"
                    "import json, os, sys\n"
                    "from pathlib import Path\n"
                    f"with Path({str(app / 'commands.jsonl')!r}).open('a') as log:\n"
                    "    log.write(json.dumps([sys.argv[1:], os.getcwd()]) + '\\n')\n"
                    "if 'dump' in sys.argv:\n"
                    "    assert Path(sys.argv[-1]).read_bytes() == b'built APK fixture'\n"
                    "    sys.exit(42)\n"
                    f"sys.exit(42 if 'build' in sys.argv and {expected_flavor is None!r} else 0)\n"
                )
                executable.chmod(0o755)
                for name in ("adb", "emulator", "avdmanager", "mitmdump", "openssl"):
                    (bin_dir / name).symlink_to(executable)
                sdk = root / "sdk"
                aapt = sdk / "build-tools/36.0.0/aapt"
                aapt.parent.mkdir(parents=True)
                aapt.symlink_to(executable)
                args = parser().parse_args(
                    [
                        str(app),
                        "--domain",
                        "example.test",
                        "--output",
                        str(root / "runs"),
                        *options,
                        *define_options,
                        *scenario_options,
                        *(["--flavor", cli_flavor] if cli_flavor is not None else []),
                    ]
                )
                with (
                    chdir(root),
                    patch.dict(
                        os.environ,
                        {
                            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
                            "ANDROID_HOME": str(sdk),
                        },
                    ),
                    patch("cli.check_emulator", return_value="test-image"),
                    self.assertRaises(subprocess.CalledProcessError) as failure,
                ):
                    audit(args)
                self.assertEqual(failure.exception.returncode, 42)
                self.assertEqual(
                    [
                        json.loads(line)
                        for line in (app / "commands.jsonl").read_text().splitlines()
                    ],
                    [
                        [[*prefix, "pub", "get", "--enforce-lockfile"], str(app)],
                        [
                            [
                                *prefix,
                                "build",
                                "apk",
                                "--debug",
                                "--no-pub",
                                *(["--flavor", expected_flavor] if expected_flavor is not None else []),
                                *define_arguments,
                            ],
                            str(app),
                        ],
                    ] + (
                        [[["dump", "badging", str(apk)], str(root)]]
                        if expected_flavor is not None else []
                    ),
                )
                self.assertFalse((root / "runs").exists())

    def test_missing_selected_flutter_tool_fails_before_creating_a_session(self):
        for options, missing in (([], "flutter"), (["--use-fvm"], "fvm")):
            with (
                self.subTest(missing=missing),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory)
                (root / "pubspec.lock").touch()
                args = parser().parse_args(
                    [
                        str(root),
                        "--domain",
                        "example.test",
                        "--output",
                        str(root / "runs"),
                        *options,
                    ]
                )
                with (
                    patch(
                        "cli.shutil.which",
                        side_effect=lambda name: None if name == missing else "tool",
                    ),
                    self.assertRaisesRegex(RuntimeError, rf"Missing {missing}\."),
                ):
                    audit(args)
                self.assertFalse((root / "runs").exists())

    def test_invalid_inputs_fail_before_creating_a_session(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            apk = root / "app.apk"
            apk.touch()
            defines = root / "config.json"
            defines.write_text('{"API_URL": "https://example.test"}')
            (root / "network-audit.toml").write_text('domains = ["legacy.test"]')
            cases = [
                ([str(root / "missing.apk")], "App not found"),
                ([str(apk)], "No domains configured"),
                ([str(apk), "--domain", "https://example.com"], "Invalid domain"),
                (
                    [str(apk), "--dart-define-from-file", str(defines)],
                    "requires a Flutter project, not an APK",
                ),
                ([str(apk), "--flavor", "staging"], "requires a Flutter project, not an APK"),
                ([str(root), "--flavor", ""], "must be a non-blank identifier"),
                ([str(root), "--flavor", "  "], "must be a non-blank identifier"),
            ]
            for path in (root / "missing.json", root, ""):
                cases.append(
                    (
                        [
                            str(root),
                            "--dart-define-from-file",
                            str(defines),
                            "--dart-define-from-file",
                            str(path),
                        ],
                        "Dart define file not found or not a file",
                    )
                )
            (root / "executor.mjs").write_text("export default async function () {}\n")
            flavored = root / "flavored.toml"
            flavored.write_text('executor = "executor.mjs"\nflavor = "staging"\n')
            cases.append(
                ([str(apk), "--scenario", str(flavored)], "requires a Flutter project, not an APK")
            )
            for name, env_file in (("missing", "missing.env"), ("directory", ".")):
                scenario = root / f"{name}.toml"
                scenario.write_text(
                    f'executor = "executor.mjs"\nenv-file = {json.dumps(env_file)}\n'
                )
                cases.extend(
                    [
                        (
                            [str(root), "--scenario", str(scenario)],
                            "Dart define file not found or not a file",
                        ),
                        (
                            [str(apk), "--scenario", str(scenario)],
                            "requires a Flutter project, not an APK",
                        ),
                    ]
                )
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
            defines = root / "override.json"
            defines.write_text('{"API_URL": "https://override.test"}')
            args = parser().parse_args(
                [str(root), "--scenario", str(config), "--output", str(root / "runs")]
            )
            for filename, definition, message in (
                (config, None, "existing .toml"),
                (module, None, "existing .toml"),
                (config, "[broken", "Invalid scenario TOML"),
                (config, "", "'executor' is a required property"),
                (
                    config,
                    'domains = ["config.test"]',
                    "'executor' is a required property",
                ),
                (config, 'executor = ""', "executor: .*does not match"),
                (config, 'executor = "  "', "executor: .*does not match"),
                (
                    config,
                    'executor = ["executor.mjs"]',
                    "executor: .*not of type 'string'",
                ),
                (config, "executor = 123", "executor: .*not of type 'string'"),
                (
                    config,
                    'executor = "executor.mjs"\nenv-file = ""',
                    "env-file: .*does not match",
                ),
                (
                    config,
                    'executor = "executor.mjs"\nenv-file = "  "',
                    "env-file: .*does not match",
                ),
                (
                    config,
                    'executor = "executor.mjs"\nenv-file = 123',
                    "env-file: .*not of type 'string'",
                ),
                (
                    config,
                    'executor = "executor.mjs"\nenv-file = ["dev.json"]',
                    "env-file: .*not of type 'string'",
                ),
                (
                    config,
                    'executor = "executor.mjs"\nflavor = ""',
                    "flavor: .*does not match",
                ),
                (
                    config,
                    'executor = "executor.mjs"\nflavor = "  "',
                    "flavor: .*does not match",
                ),
                (
                    config,
                    'executor = "executor.mjs"\nflavor = 123',
                    "flavor: .*not of type 'string'",
                ),
                (
                    config,
                    'executor = "executor.mjs"\nflavor = ["staging"]',
                    "flavor: .*not of type 'string'",
                ),
                (
                    config,
                    'executor = "executor.mjs"\ndomains = []',
                    "domains: .*should be non-empty",
                ),
                (
                    config,
                    'executor = "executor.mjs"\ndomains = "config.test"',
                    "domains: .*not of type 'array'",
                ),
                (
                    config,
                    'executor = "executor.mjs"\ndomains = ["config.test", 123]',
                    r"domains\.1: .*not of type 'string'",
                ),
                (
                    config,
                    'executor = "executor.mjs"\ndomains = [""]',
                    r"domains\.0: .*should be non-empty",
                ),
                (
                    config,
                    'executor = "executor.mjs"\ndomains = ["https://config.test"]',
                    "Invalid domain",
                ),
                (
                    config,
                    'executor = "executor.mjs"\ndomians = ["config.test"]',
                    "Additional properties are not allowed.*domians",
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
                    # A CLI override must not hide an invalid TOML definition.
                    for override in (None, ["override.test"]):
                        args.domain = override
                        args.dart_define_from_file = [str(defines)] if override else []
                        args.flavor = "staging" if override else None
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

    def test_invalid_dimensions_fail_before_build_or_session_creation(self):
        valid = {"width": 1280, "height": 2856, "density": 480}
        cases = [
            (json.dumps(value), "dimensions: .*not one of")
            for value in ("small", "BIG", " big ", "", "1280x2856")
        ] + [
            ("480", "dimensions: .*not of type 'object'"),
            ("true", "dimensions: .*not of type 'object'"),
            ('["big"]', "dimensions: .*not of type 'object'"),
            ("{}", "dimensions: .*required property"),
            (
                "{ width = 1280, height = 2856, density = 480, dpi = 480 }",
                "dimensions: .*Additional properties.*dpi",
            ),
        ]
        for field in valid:
            for value in ("0", "-2", "1.5", '"480"', "true"):
                fields = {key: str(number) for key, number in valid.items()}
                fields[field] = value
                cases.append(
                    (
                        "{ " + ", ".join(f"{k} = {v}" for k, v in fields.items()) + " }",
                        rf"dimensions\.{field}:",
                    )
                )
            fields = {key: number for key, number in valid.items() if key != field}
            cases.append(
                (
                    "{ " + ", ".join(f"{k} = {v}" for k, v in fields.items()) + " }",
                    f"dimensions: .*'{field}' is a required property",
                )
            )
        cases.append(
            (
                "{ width = 1279, height = 2856, density = 480 }",
                "dimensions.width: .*not a multiple of 2",
            )
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "scenario.toml"
            args = parser().parse_args(
                [str(root), "--scenario", str(config), "--output", str(root / "runs")]
            )
            for definition, message in cases:
                with self.subTest(dimensions=definition):
                    config.write_text(
                        f'executor = "executor.mjs"\ndimensions = {definition}\n'
                    )
                    for backend, override in product(("android", "ios"), (None, "big")):
                        args.backend = backend
                        args.dimensions = override
                        with self.assertRaisesRegex(ValueError, message):
                            audit(args)
                    self.assertFalse((root / "runs").exists())

    def test_cli_dimensions_reject_non_shortcuts(self):
        for value in (
            "small", "BIG", " big ", "", "1280x2856",
            "{ width = 1280, height = 2856, density = 480 }",
        ):
            with (
                self.subTest(dimensions=value),
                redirect_stderr(StringIO()) as errors,
                self.assertRaises(SystemExit) as failure,
            ):
                parser().parse_args(["app.apk", "--dimensions", value])
            self.assertEqual(failure.exception.code, 2)
            self.assertIn("invalid choice", errors.getvalue())
            self.assertIn("big", errors.getvalue())


class ScreenRecordingTest(unittest.TestCase):
    def test_recording_finalizes_before_transfer_and_rejects_incomplete_transfers(self):
        # Real child processes and signals, with ADB/Android as the boundary.
        # Bytes are a lifecycle fixture, not a claim of native MP4 verification.
        for mode in ("complete", "pull failure", "empty"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                binaries = root / "bin"
                binaries.mkdir()
                remote = root / "device"
                remote.mkdir()
                session = root / "session with spaces"
                session.mkdir()
                adb = binaries / "adb"
                adb.write_text(
                    f"#!{sys.executable}\n"
                    + """
import os, subprocess, sys
from pathlib import Path
assert sys.argv[1:3] == ['-s', '127.0.0.1:5581'], 'Must target the owned transport'
root = Path(__file__).resolve().parents[1]
remote = root / 'device'
if sys.argv[3] == 'shell':
    script = sys.argv[4].replace('/data/local/tmp/', str(remote) + '/')
    sys.exit(subprocess.call(['sh', '-c', script]))
assert sys.argv[3] == 'pull'
source = remote / Path(sys.argv[4]).name
assert source.read_bytes() == b'finalized', 'Transfer preceded graceful finalization'
target = Path(sys.argv[5])
mode = os.environ['RECORDING_FIXTURE_MODE']
target.write_bytes(b'' if mode == 'empty' else source.read_bytes())
sys.exit(1 if mode == 'pull failure' else 0)
"""
                )
                screenrecord = binaries / "screenrecord"
                screenrecord.write_text(
                    f"#!{sys.executable}\n"
                    + """
import signal, sys, time
from pathlib import Path
assert sys.argv[1:3] == ['--time-limit', '0'], 'Audit must not stop at 180 seconds'
output = Path(sys.argv[3])
def finish(*_):
    output.write_bytes(b'finalized')
    sys.exit(0)
signal.signal(signal.SIGINT, finish)
output.write_bytes(b'open')
while True:
    time.sleep(0.1)
"""
                )
                adb.chmod(0o700)
                screenrecord.chmod(0o700)
                device = Emulator(root, None, 8080, True, "test-image")
                device.serial = "127.0.0.1:5581"
                recording = ScreenRecording(device, session)
                with patch.dict(
                    os.environ,
                    {
                        "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
                        "RECORDING_FIXTURE_MODE": mode,
                    },
                ):
                    try:
                        recording.start()
                        recording.check()
                    finally:
                        if mode == "complete":
                            video = recording.stop()
                            self.assertEqual(video, session / "recording.mp4")
                            assert video is not None
                            self.assertEqual(video.read_bytes(), b"finalized")
                        else:
                            with self.assertRaises(
                                (RuntimeError, subprocess.CalledProcessError)
                            ):
                                recording.stop()
                            self.assertFalse((session / "recording.mp4").exists())
                pid = int((remote / "network-audit-recording.pid").read_text())
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)


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


class IOSBackendTest(unittest.TestCase):
    def bundle(self, root, name="Sample.app", platform="iPhoneSimulator"):
        app = root / name
        app.mkdir(parents=True)
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "test.ios.app",
            "CFBundleSupportedPlatforms": [platform],
        }, fmt=plistlib.FMT_BINARY))
        return app

    def test_backend_defaults_and_rejects_incompatible_inputs_before_session(self):
        self.assertEqual(parser().parse_args(["sample-app"]).backend, "android")
        with redirect_stderr(StringIO()), self.assertRaises(SystemExit):
            parser().parse_args(["sample-app", "--backend=windows"])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = self.bundle(root)
            device_app = self.bundle(root, "Device.app", "iPhoneOS")
            invalid_app = self.bundle(root, "Invalid.app")
            (invalid_app / "Info.plist").write_text('<?xml version="1.0"?><plist><dict>')
            apk = root / "app.apk"
            apk.touch()
            cases = (
                (app, ["--backend=ios"], RuntimeError, "requires macOS"),
                (app, [], ValueError, "require --backend=ios"),
                (apk, ["--backend=ios"], ValueError, "not an IPA/APK"),
                (device_app, ["--backend=ios"], ValueError, "not a physical iOS device"),
                (invalid_app, ["--backend=ios"], ValueError, "Cannot read Simulator app Info.plist"),
                (app, ["--backend=ios", "--flavor=stage"], ValueError, "requires a Flutter project"),
                (app, ["--backend=ios", "--dart-define-from-file=x.json"], ValueError, "requires a Flutter project"),
                (apk, ["--ios-runtime=test"], ValueError, "require --backend=ios"),
                (apk, ["--ios-runtime="], ValueError, "require --backend=ios"),
                (apk, ["--ios-device-type="], ValueError, "require --backend=ios"),
            )
            for path, options, error, message in cases:
                with (
                    self.subTest(options=options, app=path.name),
                    patch("ios.sys.platform", "linux"),
                    self.assertRaisesRegex(error, message),
                ):
                    audit(parser().parse_args([
                        str(path), "--domain=example.test", "--output", str(root / "runs"),
                        *options,
                    ]))
                self.assertFalse((root / "runs").exists())

    def test_runtime_selection_uses_available_compatible_ios_versions(self):
        prefix = "com.apple.CoreSimulator.SimRuntime."
        phone = {"identifier": "phone", "productFamily": "iPhone"}
        tablet = {"identifier": "tablet", "productFamily": "iPad"}
        runtimes = [
            {"identifier": prefix + name, "version": version, "isAvailable": available,
             "supportedDeviceTypes": devices}
            for name, version, available, devices in (
                ("iOS-9-0", "9.0", True, [phone]),
                ("iOS-18-2", "18.2", True, [tablet, phone]),
                ("iOS-18-10", "18.10", True, [phone]),
                ("iOS-99-0", "99.0", False, [phone]),
                ("tvOS-100-0", "100.0", True, [phone]),
            )
        ]
        with tempfile.TemporaryDirectory() as directory:
            developer = Path(directory)
            application = developer / "Applications/Simulator.app"
            application.mkdir(parents=True)
            with (
                patch("ios.sys.platform", "darwin"),
                patch.dict(os.environ, {"DEVELOPER_DIR": str(developer)}),
                patch("ios.run", return_value=json.dumps({"runtimes": runtimes})),
            ):
                self.assertEqual(check_simulator(), (prefix + "iOS-18-10", "phone", application))
                self.assertEqual(check_simulator(device_type="tablet"), (prefix + "iOS-18-2", "tablet", application))
                self.assertEqual(check_simulator(prefix + "iOS-9-0")[0], prefix + "iOS-9-0")
                for runtime, device_type in ((prefix + "iOS-99-0", None), (None, "missing"), (prefix + "iOS-9-0", "tablet")):
                    with self.assertRaisesRegex(RuntimeError, "No available iOS"):
                        check_simulator(runtime, device_type)

    def test_simulator_application_supports_xcode_layouts(self):
        for relative in (
            "Developer/Applications/Simulator.app",
            "Developer/Applications/DeviceHub.app",
            "Applications/DeviceHub.app",
        ):
            with self.subTest(application=relative), tempfile.TemporaryDirectory() as directory:
                contents = Path(directory) / "Xcode Beta.app/Contents"
                developer = contents / "Developer"
                developer.mkdir(parents=True)
                application = contents / relative
                application.mkdir(parents=True)
                runtime = {
                    "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                    "version": "27.0",
                    "isAvailable": True,
                    "supportedDeviceTypes": [{"identifier": "phone", "productFamily": "iPhone"}],
                }
                with (
                    patch("ios.sys.platform", "darwin"),
                    patch.dict(os.environ, {"DEVELOPER_DIR": str(developer)}),
                    patch("ios.run", return_value=json.dumps({"runtimes": [runtime]})),
                ):
                    self.assertEqual(check_simulator(), (runtime["identifier"], "phone", application))

    def test_flutter_build_selects_reported_bundle_not_stale_or_runner_app(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            selected = self.bundle(root, "build/ios/iphonesimulator/My Stage App.app")
            self.bundle(root, "build/ios/iphonesimulator/Runner.app")
            executable = root / "flutter fixture"
            executable.write_text(
                f"#!{sys.executable}\nimport json,sys\nfrom pathlib import Path\n"
                "Path('arguments.json').write_text(json.dumps(sys.argv[1:]))\n"
                f"print('✓ Built {selected.relative_to(root)} (12.3MB)')\n"
            )
            executable.chmod(0o700)
            for prefix in ([], ["flutter"]):
                with self.subTest(prefix=prefix), redirect_stdout(StringIO()):
                    result = build_app(root, [str(executable), *prefix], "Stage", [root / "config file.json"])
                self.assertEqual(result, selected)
                self.assertEqual(app_identity(result), "test.ios.app")
                self.assertEqual(json.loads((root / "arguments.json").read_text()), [
                    *prefix, "build", "ios", "--simulator", "--debug", "--no-codesign",
                    "--no-pub", "--flavor", "Stage", f"--dart-define-from-file={root / 'config file.json'}",
                ])
            executable.write_text(f"#!{sys.executable}\nprint('build did not finish')\n")
            with redirect_stdout(StringIO()), self.assertRaisesRegex(RuntimeError, "did not report"):
                build_app(root, [str(executable)], None, [])
            executable.write_text(f"#!{sys.executable}\nimport sys\nsys.exit(7)\n")
            with redirect_stdout(StringIO()), self.assertRaises(subprocess.CalledProcessError):
                build_app(root, [str(executable)], None, [])

    @unittest.skipUnless(shutil.which("mitmdump"), "mitmdump is supplied by devenv")
    def test_owned_simulator_cleanup_and_reports_across_failures(self):
        # Real mitmproxy/report IO, but regular proxy transport replaces macOS
        # local capture and an in-memory simctl boundary replaces CoreSimulator.
        # These are lifecycle tests, not evidence of native iOS interception.
        owned = "E83EA845-AD13-43CC-BCAD-B56C379847CA"
        other = "9B2D97C0-BB1E-4087-BFAB-60008CE7F0C8"
        popen = subprocess.Popen
        outcomes = (
            "completed", "create", "boot", "keychain", "install", "launch",
            "scenario", "interrupt", "proxy", "shutdown", "launch and shutdown",
            "manual interrupt", "manual shutdown",
        )
        table = "dimensions = { width = 720, height = 1600, density = 240 }"
        cases = [(outcome, "", None) for outcome in outcomes] + [
            ("completed", table, None),
            ("completed", 'dimensions = "big"', None),
            ("completed", "", "big"),
            ("completed", table, "big"),
            ("manual shutdown", "", "big"),
        ]
        for outcome, definition, shortcut in cases:
            with (
                self.subTest(outcome=outcome, dimensions=definition, shortcut=shortcut),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory)
                app = self.bundle(root)
                scenario = root / "scenario.toml"
                scenario.write_text(f'executor = "executor.mjs"\n{definition}\n')
                (root / "executor.mjs").write_text("export default async function () {}\n")
                devices = {other: "Booted"}
                names = {other: "Unrelated"}
                installed = {}
                trusted = set()
                children = []

                def simctl(command, **_kwargs):
                    self.assertEqual(command[:2], ["xcrun", "simctl"])
                    action, *arguments = command[2:]
                    if action == "create":
                        devices[owned] = "Shutdown"
                        names[owned] = arguments[0]
                        if outcome == "create":
                            raise subprocess.TimeoutExpired(command, 60)
                        return owned
                    if action == "list":
                        if "booted" in arguments and outcome == "manual interrupt":
                            raise KeyboardInterrupt
                        if "booted" in arguments and outcome == "manual shutdown":
                            devices[owned] = "Shutdown"
                        return json.dumps({"devices": {"runtime": [
                            {"udid": identifier, "state": state, "name": names[identifier]}
                            for identifier, state in devices.items()
                            if "booted" not in arguments or state == "Booted"
                        ]}})
                    self.assertEqual(arguments[0], owned, "Must never mutate an unrelated Simulator")
                    if action in outcome.split(" and "):
                        raise subprocess.CalledProcessError(1, command, stderr=f"fixture {action} failure")
                    if action == "boot":
                        devices[owned] = "Booted"
                    elif action == "keychain":
                        self.assertEqual(arguments[1], "add-root-cert")
                        self.assertIn("BEGIN CERTIFICATE", Path(arguments[2]).read_text())
                        trusted.add(owned)
                    elif action == "install":
                        self.assertIn(owned, trusted)
                        installed[owned] = app_identity(Path(arguments[1]))
                    elif action == "launch":
                        self.assertEqual(installed[owned], arguments[1])
                    elif action == "shutdown":
                        devices[owned] = "Shutdown"
                    elif action == "delete":
                        del devices[owned]
                    else:
                        self.assertEqual(action, "bootstatus")
                    return ""

                def start(command, **kwargs):
                    if command[0] == "mitmdump":
                        self.assertEqual(command[1:3], ["--mode", f"local:{owned}/"])
                        command = [command[0], *command[3:]]
                        if outcome == "proxy":
                            command = [sys.executable, "-c", "raise SystemExit(1)"]
                        child = popen(command, **kwargs)
                        children.append(child)
                        return child
                    return popen(command, **kwargs)

                def execute(_path, *, backend, serial, device_id, package, check_running, launch_app, **_kwargs):
                    self.assertEqual((backend, serial, device_id, package), ("ios", owned, owned, "test.ios.app"))
                    check_running()
                    launch_app()
                    if outcome == "scenario":
                        raise RuntimeError("fixture scenario failure")
                    if outcome == "interrupt":
                        raise KeyboardInterrupt

                with (
                    patch("cli.check_simulator", return_value=("runtime", "phone", "Simulator.app")),
                    patch("cli.check_emulator", side_effect=AssertionError("iOS must not check Android")),
                    patch("ios.run", side_effect=simctl),
                    patch("cli.subprocess.Popen", side_effect=start),
                    patch("cli.run_scenario", side_effect=execute),
                    patch("cli.shutil.which", side_effect=lambda name: None if name in ("adb", "emulator", "flutter", "fvm") else "available"),
                    redirect_stdout(StringIO()),
                    redirect_stderr(StringIO()) as errors,
                ):
                    args = parser().parse_args([
                        str(app), "--backend=ios", "--use-fvm", "--headless",
                        *(["--domain=example.test"] if outcome.startswith("manual") else ["--scenario", str(scenario)]),
                        *(["--dimensions", shortcut] if shortcut else []),
                        "--output", str(root / "runs"),
                    ])
                    if outcome == "completed" or outcome.startswith("manual"):
                        self.assertEqual(audit(args), 0)
                    elif outcome == "interrupt":
                        self.assertEqual(audit(args), 130)
                    else:
                        with self.assertRaises(RuntimeError):
                            audit(args)
                self.assertEqual(
                    errors.getvalue().count("dimensions are ignored on iOS"),
                    1 if definition or shortcut else 0,
                )
                self.assertEqual(devices, {other: "Booted"})
                self.assertTrue(all(child.poll() is not None for child in children))
                (session,) = (root / "runs").iterdir()
                metadata = json.loads((session / "session.json").read_text())
                self.assertEqual(metadata["backend"], "ios")
                self.assertEqual(metadata["device"], owned)
                if definition or shortcut:
                    self.assertEqual(metadata["ios_device_type"], "phone")
                self.assertEqual(metadata["state"], {
                    "completed": "scenario completed", "interrupt": "interrupted by user",
                    "manual interrupt": "interrupted by user", "manual shutdown": "simulator closed",
                }.get(outcome, "failed"))
                if outcome == "launch and shutdown":
                    self.assertEqual(metadata["failure"], "fixture launch failure")
                    self.assertIn("device_cleanup_failure", metadata)
                report = (session / "report.html").read_text()
                self.assertIn("Experimental iOS Simulator", report)
                self.assertIn("shared WebKit/system helpers are not included", report)
                self.assertNotIn("QUIC is blocked", report)
                self.assertIn("Total requests: 0", (session / "report.txt").read_text())

    def test_recording_starts_before_output_and_requires_successful_finalization(self):
        popen = subprocess.Popen
        for outcome in ("success", "failure"):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as directory:
                session = Path(directory)
                recorder = SimulatorRecording(Mock(serial="owned"), session)

                def start(command, **kwargs):
                    child = popen([
                        sys.executable, "-c",
                        "import signal,sys\nfrom pathlib import Path\n"
                        "path = Path(sys.argv[1])\n"
                        "def finish(*_):\n"
                        "    path.write_bytes(b'finalized fixture')\n"
                        f"    sys.exit({0 if outcome == 'success' else 9})\n"
                        "signal.signal(signal.SIGINT, finish)\n"
                        # simctl acknowledges the first frame on stderr, but
                        # may not write the MP4 until SIGINT finalizes it.
                        "print('Recording started', file=sys.stderr, flush=True)\n"
                        "signal.pause()\n",
                        command[-1],
                    ], **kwargs)
                    self.addCleanup(child.wait, timeout=5)
                    self.addCleanup(child.terminate)
                    return child

                with patch("ios.subprocess.Popen", side_effect=start):
                    recorder.start()
                    self.assertFalse((session / "recording.mp4").exists())
                    self.assertFalse((session / "recording.partial.mp4").exists())
                    if outcome == "success":
                        self.assertEqual(recorder.stop(), session / "recording.mp4")
                        self.assertEqual((session / "recording.mp4").read_bytes(), b"finalized fixture")
                    else:
                        with self.assertRaisesRegex(RuntimeError, "recording failed"):
                            recorder.stop()
                        self.assertFalse((session / "recording.mp4").exists())
                        self.assertTrue((session / "recording.partial.mp4").exists())


@unittest.skipUnless(shutil.which("mitmdump"), "mitmdump is supplied by devenv")
class ScenarioAuditTest(unittest.TestCase):
    def test_omitted_domains_capture_all_and_cli_override_filters(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            for override, expected_hosts in (
                ([], ["localhost", "127.0.0.1"]),
                (["--domain", "localhost"], ["localhost"]),
            ):
                with (
                    self.subTest(override=override),
                    tempfile.TemporaryDirectory() as directory,
                ):
                    root = Path(directory)
                    apk = root / "sample.apk"
                    apk.touch()
                    config = root / "scenario.toml"
                    config.write_text('executor = "executor.mjs"\n')
                    (root / "executor.mjs").write_text(
                        "export default async function () {}\n"
                    )
                    args = parser().parse_args(
                        [
                            str(apk),
                            "--scenario",
                            str(config),
                            "--output",
                            str(root / "runs"),
                            *override,
                        ]
                    )

                    def execute(*_args, launch_app, **_kwargs):
                        launch_app()
                        # Use the proxy port handed to the emulator boundary.
                        port = emulator.call_args.args[2]
                        for host in ("localhost", "127.0.0.1"):
                            conn = http.client.HTTPConnection(
                                "127.0.0.1", port, timeout=10
                            )
                            conn.request(
                                "GET", f"http://{host}:{server.server_port}/ok"
                            )
                            response = conn.getresponse()
                            self.assertEqual(response.status, 200)
                            response.read()
                            conn.close()

                    with (
                        patch("cli.shutil.which", return_value="available"),
                        patch("cli.check_emulator", return_value="test-image"),
                        patch("cli.apk_identity", return_value=("test.app", "Main")),
                        patch("cli.Emulator") as emulator,
                        patch("cli.run_scenario", side_effect=execute),
                        redirect_stdout(StringIO()) as output,
                    ):
                        emulator.return_value.serial = "emulator-5580"
                        emulator.return_value.foreground.return_value = True
                        self.assertEqual(audit(args), 0)
                    (session,) = (root / "runs").iterdir()
                    metadata = json.loads((session / "session.json").read_text())
                    self.assertEqual(
                        metadata["domains"], ["localhost"] if override else None
                    )
                    flows, diagnostics = read_events(session / "events.jsonl")
                    self.assertEqual([flow["host"] for flow in flows], expected_hosts)
                    self.assertEqual(diagnostics, [])
                    self.assertTrue(
                        all(flow["response"]["status"] == 200 for flow in flows)
                    )
                    self.assertIn(
                        f"Total requests: {len(expected_hosts)}",
                        (session / "report.txt").read_text(),
                    )
                    report = (session / "report.html").read_text()
                    if override:
                        self.assertIn("Other domains are not recorded.", report)
                    else:
                        self.assertIn(
                            "Capturing: all HTTP(S) requests", output.getvalue()
                        )
                        self.assertIn("All HTTP(S) requests", report)
                        self.assertNotIn("Other domains are not recorded.", report)
        finally:
            server.shutdown()
            server.server_close()

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

                def execute(path, *, session, launch_app, **_kwargs):
                    launch_app()
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
    def test_ios_preparation_preserves_first_app_launch_and_bounds_failures(self):
        # Real private daemon, runner and process cleanup; only the device-side
        # install/start commands are fixtures. Native acceptance covers DeviceKit.
        popen = subprocess.Popen
        for backend, outcome, error in (
            ("ios", "success", None),
            ("android", "success", None),
            ("ios", "install failure", "iOS agent installation exited with status 7"),
            ("ios", "startup failure", "iOS agent startup exited with status 8"),
            ("ios", "startup timeout", "Scenario timed out"),
        ):
            with self.subTest(backend=backend, outcome=outcome), tempfile.TemporaryDirectory() as directory:
                session = Path(directory)
                ready = session / "agent.ready"
                foreground = session / "foreground"
                completed = session / "completed"
                module = session / "scenario.mjs"
                module.write_text(f"""
import assert from 'node:assert/strict';
import {{ readFileSync, writeFileSync }} from 'node:fs';
assert.equal(readFileSync({json.dumps(str(foreground))}, 'utf8'), 'app');
writeFileSync({json.dumps(str(completed))}, 'ok');
// Test the preparation boundary without connecting to a physical device.
process.exit(0);
""")
                children = []
                homes = set()
                launches = []

                def start(command, **kwargs):
                    if command[1:3] in (["agent", "install"], ["apps", "foreground"]):
                        home = Path(kwargs["env"]["MOBILECLI_HOME"])
                        homes.add(home)
                        self.assertTrue((home / "daemon.sock").exists())
                        self.assertEqual(command[3:], ["--device", "owned-udid"])
                        source = "import signal,time\nfrom pathlib import Path\n"
                        if command[1] == "agent":
                            source += f"raise SystemExit({7 if outcome == 'install failure' else 0})\n"
                        elif outcome == "startup failure":
                            source += "raise SystemExit(8)\n"
                        elif outcome == "startup timeout":
                            source += "signal.signal(signal.SIGTERM, signal.SIG_IGN)\ntime.sleep(60)\n"
                        else:
                            # DeviceKit startup backgrounds any existing app.
                            source += (
                                f"Path({str(foreground)!r}).write_text('agent')\n"
                                f"Path({str(ready)!r}).touch()\n"
                            )
                        command = [sys.executable, "-c", source]
                    child = popen(command, **kwargs)
                    children.append(child)
                    return child

                def launch_app():
                    self.assertEqual(ready.exists(), backend == "ios")
                    launches.append("app")
                    foreground.write_text("app")

                with (
                    patch("scenario.subprocess.Popen", side_effect=start),
                    self.assertRaisesRegex(RuntimeError, error) if error else nullcontext(),
                ):
                    run_scenario(
                        module,
                        serial="owned-udid", device_id="owned-udid", package="test.app",
                        session=session, timeout=3 if error else 10,
                        check_running=lambda: None, backend=backend, launch_app=launch_app,
                    )
                self.assertEqual(launches, [] if error else ["app"])
                self.assertEqual(completed.exists(), error is None)
                self.assertTrue(all(child.poll() is not None for child in children))
                self.assertTrue(all(not home.exists() for home in homes))

    def test_ios_runner_attaches_without_relaunching_or_using_android_driver(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executor = root / "executor.mjs"
            executor.write_text("""
import assert from 'node:assert/strict';
export default async function ({ backend, serial, packageName, screen }) {
  assert.equal(backend, 'ios');
  assert.equal(serial, 'owned-udid');
  assert.equal(packageName, 'test.ios.app');
  assert.equal(screen.marker, 'attached screen');
}
""")
            script = """
import assert from 'node:assert/strict';
import { ios, android } from 'mobilewright';
import { MobilecliDriver } from '@mobilewright/driver-mobilecli';
import { NativeIOSDriver } from './native-ios-driver.mjs';
let attached = false, closed = false, disposed = false;
android.launch = async () => { throw new Error('Used Android launcher for iOS'); };
ios.launch = async (options) => {
  assert.equal(options.deviceId, 'owned-udid');
  assert.equal(options.autoAppLaunch, false);
  assert.equal(options.driver.constructor, NativeIOSDriver);
  attached = true;
  return { screen: { marker: 'attached screen' }, close: async () => { closed = true; } };
};
MobilecliDriver.prototype.dispose = async () => { disposed = true; };
process.argv = ['node', 'runner.mjs', process.argv[1], 'owned-udid', 'owned-udid', 'test.ios.app', process.argv[2], 'ios'];
await import('./runner.mjs');
assert.ok(attached && closed && disposed);
"""
            result = subprocess.run(
                ["node", "--input-type=module", "-e", script, str(executor), str(root)],
                cwd=RUNNER.parent, capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

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

    def test_native_ios_locators_find_webview_consent_and_tap_in_screen_points(self):
        # DeviceKit 0.0.33 AX snapshots use numeric elementType and capitalized
        # frame fields, unlike both its normalized tree and Android raw dumps.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dump = root / "dump.json"
            binary = root / "mobilecli fixture"
            node = {
                "elementType": 9,
                "label": "",
                "identifier": "",
                "frame": {"X": 37.25, "Y": 446.5, "Width": 328.5, "Height": 45.5},
                "children": [],
            }
            tree = {
                **node,
                "elementType": 0,
                "frame": {"X": 0, "Y": 0, "Width": 0, "Height": 0},
                "children": [
                    {**node, "label": "BUNTE\nTab 2 of 2", "selected": True},
                    {
                        **node,
                        "elementType": 58,
                        "children": [
                            {**node, "label": "Akzeptieren", "identifier": "consent-accept"},
                            {**node, "label": "Disabled", "enabled": False},
                            {
                                **node, "label": "Offscreen",
                                "frame": {"X": 0, "Y": -100, "Width": 80, "Height": 40},
                            },
                        ],
                    },
                    {**node, "elementType": 40, "label": "Tracking", "value": "1"},
                    {
                        **node, "elementType": 49, "identifier": "search",
                        "placeholderValue": "Search", "value": "Royals", "hasFocus": True,
                    },
                ],
            }
            dump.write_text(json.dumps({"status": "ok", "data": {"rawData": tree}}))
            binary.write_text(
                f"#!{shutil.which('node')}\n" + """
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
import { readFileSync, writeFileSync } from 'node:fs';
import { Screen } from 'mobilewright';
import { NativeIOSDriver } from './native-ios-driver.mjs';
const driver = new NativeIOSDriver({
  deviceId: 'owned-device', mobilecliPath: process.argv[1],
});
const screen = new Screen(driver);
assert.equal(await screen.getByRole('button', { name: /^BUNTE/ }).isVisible(), true);
assert.equal(await screen.getByRole('button', { name: /^akzeptieren$/i }).isVisible(), true);
assert.equal(await screen.getByTestId('consent-accept').isVisible(), true);
assert.equal(await screen.getByText('Offscreen').isVisible(), false);
await assert.rejects(screen.getByText('Disabled').tap({ timeout: 100 }), /not enabled/);
assert.equal(await screen.getByRole('switch', { name: 'Tracking' }).isChecked(), true);
assert.equal(await screen.getByPlaceholder('Search').getValue(), 'Royals');
const consent = screen.getByText(/^(Akzeptieren|Alle akzeptieren|Zustimmen|Accept all)$/i);
assert.deepEqual(await consent.boundingBox(), { x: 37.25, y: 446.5, width: 328.5, height: 45.5 });
let tapped = false;
driver.tap = async (x, y) => {
  // Actual AX bounds are points. Do not multiply these by the Retina scale.
  assert.deepEqual([x, y], [202, 469]);
  tapped = true;
  const response = JSON.parse(readFileSync(process.argv[2], 'utf8'));
  response.data.rawData.children[1].children = [];
  writeFileSync(process.argv[2], JSON.stringify(response));
};
await consent.tap();
assert.equal(tapped, true);
await consent.waitFor({ state: 'hidden', timeout: 1000 });
writeFileSync(process.argv[2], JSON.stringify({ data: { rawData: { elements: [] } } }));
await assert.rejects(screen.getByText('Akzeptieren').isVisible(), /DeviceKit AX hierarchy/);
"""
            result = subprocess.run(
                ["node", "--input-type=module", "-e", script, str(binary), str(dump)],
                cwd=RUNNER.parent, capture_output=True, text=True, timeout=30,
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
    config.write_text(
        "hw.ramSize=2048\ndisk.dataPartition.size=12G\n"
        "hw.lcd.width=320\nhw.lcd.height=640\nhw.lcd.density=160\n"
        "skin.name=HVGA\n"
    )
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

    @unittest.skipUnless(shutil.which("mitmdump"), "mitmdump is supplied by devenv")
    def test_dimensions_are_applied_before_emulator_boot(self):
        for definition, shortcut, expected_display, skin in (
            (None, None, ("320", "640", "160"), None),
            (None, "big", ("1280", "2856", "480"), "1280x2856"),
            ("", None, ("320", "640", "160"), None),
            ("", "big", ("1280", "2856", "480"), "1280x2856"),
            ('dimensions = "big"', None, ("1280", "2856", "480"), "1280x2856"),
            (
                "dimensions = { width = 1280, height = 2856, density = 480 }",
                None,
                ("1280", "2856", "480"),
                "1280x2856",
            ),
            (
                "[dimensions]\nwidth = 1920\nheight = 1080\ndensity = 320",
                None,
                ("1920", "1080", "320"),
                "1920x1080",
            ),
            (
                "[dimensions]\nwidth = 1920\nheight = 1080\ndensity = 320",
                "big",
                ("1280", "2856", "480"),
                "1280x2856",
            ),
            (
                "dimensions = { width = 720.0, height = 1600.0, density = 240.0 }",
                None,
                ("720", "1600", "240"),
                "720x1600",
            ),
        ):
            with (
                self.subTest(dimensions=definition, shortcut=shortcut),
                tempfile.TemporaryDirectory(prefix="network-audit-") as directory,
            ):
                root = Path(directory)
                scenario = root / "scenario.toml"
                if definition is not None:
                    scenario.write_text(f'executor = "executor.mjs"\n{definition}\n')
                (root / "executor.mjs").write_text("export default async function () {}\n")
                apk = root / "sample.apk"
                apk.touch()
                args = parser().parse_args(
                    [
                        str(apk), "--domain", "example.test",
                        "--output", str(root / "runs"),
                        *(["--scenario", str(scenario)] if definition is not None else []),
                        *(["--dimensions", shortcut] if shortcut is not None else []),
                    ]
                )
                popen = subprocess.Popen

                def launch(command, **kwargs):
                    if command[0] != "emulator":
                        return popen(command, **kwargs)
                    avd = command[command.index("-avd") + 1]
                    config = Path(kwargs["env"]["ANDROID_AVD_HOME"]) / f"{avd}.avd" / "config.ini"
                    entries = [
                        line.split("=", 1) for line in config.read_text().splitlines()
                    ]
                    settings = dict(entries)
                    self.assertEqual(len(entries), len(settings), "Duplicate AVD settings")
                    self.assertEqual(
                        settings,
                        {
                            "hw.ramSize": "2048",
                            "disk.dataPartition.size": "6G",
                            "hw.lcd.width": expected_display[0],
                            "hw.lcd.height": expected_display[1],
                            "hw.lcd.density": expected_display[2],
                            "skin.name": "HVGA",
                        },
                    )
                    if skin is None:
                        self.assertNotIn("-skin", command)
                    else:
                        self.assertEqual(command[command.index("-skin") + 1], skin)
                    # The real CLI and AVD writer ran; stop at the native boundary.
                    raise RuntimeError("Display configuration verified before boot")

                with (
                    patch("cli.shutil.which", return_value="available"),
                    patch("cli.check_emulator", return_value="test-image"),
                    patch("cli.apk_identity", return_value=("test.app", "Main")),
                    patch("android.shutil.disk_usage", return_value=Mock(free=8 * 1024**3)),
                    patch("android.run", side_effect=create_avd),
                    patch("android.subprocess.Popen", side_effect=launch),
                    redirect_stdout(StringIO()),
                    self.assertRaisesRegex(RuntimeError, "Display configuration verified before boot"),
                ):
                    audit(args)

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

    def test_report_parses_paths_and_ordered_query_pairs_without_changing_capture(self):
        cases = [
            (
                "https://api.test/a/../items%2Fspecial;v=1?"
                "q=red+shoes&tag=first&tag=second&empty=&flag&=unnamed&"
                "encoded=%252F%2B%26%3D&na%20me=%C3%BC&"
                "html=%3C%2Fscript%3E%3Cimg+src%3Dx%3E#ignored=fragment",
                {
                    "path": "/a/../items%2Fspecial;v=1",
                    "query": [
                        ["q", "red shoes"],
                        ["tag", "first"],
                        ["tag", "second"],
                        ["empty", ""],
                        ["flag", ""],
                        ["", "unnamed"],
                        ["encoded", "%2F+&="],
                        ["na me", "ü"],
                        ["html", "</script><img src=x>"],
                    ],
                },
            ),
            ("https://api.test", {"path": "/", "query": []}),
            ("https://api.test/health?", {"path": "/health", "query": []}),
            (
                "https://api.test/?bad=%ZZ&utf8=%FF",
                {"path": "/", "query": [["bad", "%ZZ"], ["utf8", "�"]]},
            ),
            ("https://[invalid/path?x=1", None),
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "session.json").write_text(
                json.dumps(
                    {
                        "app": "URL details",
                        "domains": ["api.test"],
                        "started": "2026-10-10T10:00:00Z",
                        "state": "complete",
                    }
                )
            )
            events = "\n".join(
                json.dumps(
                    {
                        "id": str(index),
                        "host": "api.test",
                        "url": url,
                        "started": index,
                        "response": None,
                        "error": None,
                    }
                )
                for index, (url, _) in enumerate(cases)
            )
            (path / "events.jsonl").write_text(events)
            report = generate_report(path).read_text()
            data = re.search(
                r'<script type="application/json" id="audit-data">(.*?)</script>',
                report,
                re.DOTALL,
            )
            self.assertIsNotNone(data)
            assert data is not None
            flows = json.loads(data[1])["flows"]
            self.assertEqual([flow["url_parts"] for flow in flows], [c[1] for c in cases])
            self.assertEqual([flow["url"] for flow in flows], [c[0] for c in cases])
            self.assertNotIn("</script><img", report)
            self.assertEqual((path / "events.jsonl").read_text(), events)

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
