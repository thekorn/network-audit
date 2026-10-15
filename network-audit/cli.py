#!/usr/bin/env python3
"""Build, launch, capture, and report an Android or iOS Simulator audit."""

import argparse
import json
import math
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from datetime import UTC, datetime
from pathlib import Path

from android import DIMENSION_SHORTCUTS, Emulator, apk_identity, check_emulator, wait_for
from domains import normalize_domains, proxy_pattern
from ios import Simulator, SimulatorRecording, app_identity, build_app, check_simulator
from recording import ScreenRecording
from report import generate_report
from scenario import load_scenario, run_scenario

ROOT = Path(__file__).resolve().parent


def parser():
    result = argparse.ArgumentParser(prog="network-audit", description=__doc__)
    result.add_argument(
        "app", type=Path, help="Flutter project directory, Android APK, or iOS Simulator .app"
    )
    result.add_argument(
        "--backend",
        choices=("android", "ios"),
        default="android",
        help="Device backend (default: android); ios is experimental and requires macOS/Xcode",
    )
    result.add_argument(
        "--ios-runtime",
        help="iOS runtime identifier (default: newest available compatible runtime)",
    )
    result.add_argument(
        "--ios-device-type",
        help="iOS device type identifier (default: first compatible iPhone)",
    )
    result.add_argument(
        "--use-fvm",
        action="store_true",
        help="Use 'fvm flutter' for Flutter project builds (ignored for prebuilt apps)",
    )
    result.add_argument(
        "--flavor",
        metavar="IDENTIFIER",
        help="Flutter build flavor; overrides scenario flavor; not for prebuilt apps",
    )
    result.add_argument(
        "--dart-define-from-file",
        action="append",
        default=[],
        metavar="PATH",
        help="JSON or .env file for Flutter compile-time values; repeatable or comma-separated; paths relative to the current directory; not for prebuilt apps",
    )
    result.add_argument(
        "--domain",
        action="append",
        help="Exact hostname or '*.example.com'; repeatable; overrides scenario domains",
    )
    result.add_argument(
        "--output",
        type=Path,
        default=Path(".network-audit/runs"),
        help="Parent directory for private session files",
    )
    result.add_argument(
        "--outputHar",
        dest="output_har",
        action="store_true",
        help="Also save session.har with all intercepted HTTP(S) hosts, ignoring domain filters",
    )
    result.add_argument(
        "--headless",
        action="store_true",
        # The pinned Linux emulator uses Qt/X11, including on Wayland via XWayland.
        default=sys.platform == "linux" and not os.environ.get("DISPLAY"),
        help="Hide the emulator/Simulator window (automatic on Linux without DISPLAY)",
    )
    result.add_argument(
        "--dimensions",
        choices=DIMENSION_SHORTCUTS,
        help="Android display shortcut; overrides scenario dimensions (ignored with a warning on iOS)",
    )
    result.add_argument(
        "--record",
        action="store_true",
        help="Record the device screen to a silent recording.mp4 beside the report",
    )
    result.add_argument(
        "--scenario",
        type=Path,
        help="Scenario .toml with a trusted JavaScript executor; omitted domains capture all HTTP(S)",
    )
    result.add_argument(
        "--scenario-timeout",
        type=float,
        default=300,
        help="Maximum scenario seconds after app launch (default: 300)",
    )
    result.add_argument(
        "--close-grace",
        type=float,
        default=5,
        help="Android: seconds outside the foreground before finishing (default: 5); iOS: use Ctrl+C",
    )
    result.add_argument(
        "--body-limit",
        type=int,
        default=1048576,
        help="Body preview bytes/characters per message; full bodies remain in flows.mitm",
    )
    return result


def stop_proxy(proxy):
    if proxy and proxy.poll() is None:
        proxy.send_signal(signal.SIGINT)
        try:
            proxy.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proxy.terminate()
            try:
                proxy.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proxy.kill()
                proxy.wait()


def audit(args):
    app = args.app.resolve()
    if not app.exists():
        raise ValueError(f"App not found: {app}")
    is_ios = args.backend == "ios"
    is_project = app.is_dir() and app.suffix != ".app"
    if not is_ios and (args.ios_runtime is not None or args.ios_device_type is not None):
        raise ValueError("--ios-runtime and --ios-device-type require --backend=ios")
    if is_ios and not is_project:
        app_identity(app)
    elif not is_ios and app.suffix == ".app":
        raise ValueError("Simulator .app bundles require --backend=ios")
    if (
        not math.isfinite(args.close_grace)
        or args.close_grace <= 0
        or args.body_limit <= 0
    ):
        raise ValueError("--close-grace and --body-limit must be positive")
    if not math.isfinite(args.scenario_timeout) or args.scenario_timeout <= 0:
        raise ValueError("--scenario-timeout must be positive and finite")
    scenario = args.scenario.resolve() if args.scenario else None
    if scenario:
        domains, executor, env_file, dimensions, flavor = load_scenario(scenario)
    else:
        domains = None
        executor = None
        env_file = None
        dimensions = None
        flavor = None
    if args.dimensions is not None:
        dimensions = DIMENSION_SHORTCUTS[args.dimensions].copy()
    if is_ios and dimensions is not None:
        print(
            "Warning: dimensions are ignored on iOS; use --ios-device-type to select an iOS display.",
            file=sys.stderr,
            flush=True,
        )
        dimensions = None
    if args.flavor is not None:
        flavor = args.flavor
    if flavor is not None:
        if not flavor.strip():
            raise ValueError("--flavor must be a non-blank identifier")
        if not is_project:
            raise ValueError(
                "Flavor configuration (--flavor or scenario flavor) "
                "requires a Flutter project, not an APK or .app"
            )
    define_files = [
        Path(path).resolve()
        for value in args.dart_define_from_file
        for path in value.split(",")
    ]
    if not define_files and env_file is not None:
        define_files = [env_file]
    if define_files and not is_project:
        raise ValueError(
            "Dart define configuration (--dart-define-from-file or scenario env-file) "
            "requires a Flutter project, not an APK or .app"
        )
    for path in define_files:
        if not path.is_file():
            raise ValueError(f"Dart define file not found or not a file: {path}")
    if args.domain is not None or not scenario:
        domains = normalize_domains(args.domain or [])
    flutter = ["fvm", "flutter"] if args.use_fvm else ["flutter"]
    # Reject Linux before dependency checks, rather than suggesting Android tools.
    configuration = check_simulator(args.ios_runtime, args.ios_device_type) if is_ios else None
    for tool in (
        *(("xcrun",) if is_ios else ("adb", "emulator", "avdmanager")),
        "mitmdump",
        "openssl",
        *([flutter[0]] if is_project else []),
    ):
        if not shutil.which(tool):
            if tool == "fvm":
                raise RuntimeError(
                    "Missing fvm. Install FVM and add it to PATH to use --use-fvm."
                )
            if is_ios:
                raise RuntimeError(
                    f"Missing {tool}. Use the Nix core package and a macOS Flutter/Xcode environment."
                )
            raise RuntimeError(
                f"Missing {tool}. Enter devenv with androidEmulator.enable = true "
                "on an Apple Silicon Mac or x86_64 Linux KVM host."
            )
    system_image = None if is_ios else check_emulator()
    if is_project:
        if not (app / "pubspec.lock").exists():
            raise ValueError("Flutter projects must have a committed pubspec.lock")
        if is_ios and not (app / "ios").is_dir():
            raise ValueError(
                "Flutter project has no ios platform; add it with 'flutter create --platforms=ios .'"
            )
        subprocess.run(
            [*flutter, "pub", "get", "--enforce-lockfile"], cwd=app, check=True
        )
        if is_ios:
            artifact = build_app(app, flutter, flavor, define_files)
        else:
            subprocess.run(
                [
                    *flutter,
                    "build",
                    "apk",
                    "--debug",
                    "--no-pub",
                    *(["--flavor", flavor] if flavor is not None else []),
                    *(f"--dart-define-from-file={path}" for path in define_files),
                ],
                cwd=app,
                check=True,
            )
            apk_name = f"app-{flavor.lower()}-debug.apk" if flavor is not None else "app-debug.apk"
            artifact = app / "build/app/outputs/flutter-apk" / apk_name
    else:
        artifact = app
    package, activity = (app_identity(artifact), None) if is_ios else apk_identity(artifact)
    args.output.mkdir(parents=True, exist_ok=True)
    session = Path(
        tempfile.mkdtemp(
            prefix=datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ-"),
            dir=args.output,
        )
    ).resolve()
    metadata = {
        "app": app.name,
        "backend": args.backend,
        "package": package,
        "domains": domains,
        "started": datetime.now(UTC).isoformat(),
        "state": "starting",
        "body_limit": args.body_limit,
        "close_grace": None if is_ios else args.close_grace,
    }
    if is_ios:
        metadata["capture_scope"] = (
            "Executable paths within the owned Simulator; "
            "shared WebKit/system helpers are not included"
        )
    if scenario:
        metadata["scenario"] = str(scenario)
        metadata["executor"] = str(executor)
        metadata["scenario_timeout"] = args.scenario_timeout

    def save():
        (session / "session.json").write_text(json.dumps(metadata, indent=2) + "\n")

    save()
    scope = ", ".join(domains) if domains is not None else "all HTTP(S) requests"
    print(f"Session: {session}\nCapturing: {scope}", flush=True)
    print(
        "Sensitive data: headers and bodies are not redacted. Keep reports private.",
        flush=True,
    )
    if args.output_har:
        print(
            "HAR enabled: intercepting all HTTP(S) hosts, including domains outside "
            "the report filter. This may affect certificate-pinned connections.",
            flush=True,
        )
    if is_ios:
        print(
            "Experimental iOS capture: macOS may request approval for Mitmproxy Redirector. "
            "Only executable paths within this Simulator are captured; shared WebKit/system "
            "helpers are not included. Host proxy settings and host trust are not changed. "
            "Finish with Ctrl+C or scenario completion (Home does not stop capture).",
            flush=True,
        )
    elif args.headless:
        print(
            "Running headless (no emulator window). Use ADB to interact, "
            "or press Ctrl+C to finish. For a window on Linux, run from a "
            "graphical session with DISPLAY set and omit --headless.",
            flush=True,
        )
    proxy = emulator = simulator = recording = None
    failure = None
    recording_failure = None
    cleanup_failure = None
    try:
        with (
            tempfile.TemporaryDirectory(prefix="network-audit-") as temporary,
            (session / "emulator.log").open("w") as emulator_log,
            (session / "proxy.log").open("w") as proxy_log,
        ):
            try:
                with socket.socket() as sock:
                    sock.bind(("127.0.0.1", 0))
                    port = sock.getsockname()[1]
                ca_dir = Path(temporary) / "ca"
                env = {
                    **os.environ,
                    "NETWORK_AUDIT_SESSION": str(session),
                    "NETWORK_AUDIT_DOMAINS": json.dumps(domains),
                    "NETWORK_AUDIT_BODY_LIMIT": str(args.body_limit),
                    "NETWORK_AUDIT_OUTPUT_HAR": "1" if args.output_har else "0",
                }
                if is_ios:
                    simulator = Simulator(
                        Path(temporary).name, emulator_log, args.headless, configuration
                    )
                    metadata["ios_device_name"] = simulator.name
                    save()
                    simulator.create()
                    metadata["device"] = simulator.serial
                    metadata["ios_runtime"] = simulator.runtime
                    metadata["ios_device_type"] = simulator.device_type
                    save()
                proxy = subprocess.Popen(
                    [
                        "mitmdump",
                        *(["--mode", simulator.capture_mode] if simulator else []),
                        "--listen-host",
                        "127.0.0.1",
                        "--listen-port",
                        str(port),
                        "--set",
                        f"confdir={ca_dir}",
                        "--set",
                        "flow_detail=0",
                        "--set",
                        "termlog_verbosity=warn",
                        "--set",
                        f"allow_hosts={proxy_pattern(None if args.output_har else domains)}",
                        "-s",
                        str(ROOT / "capture.py"),
                    ],
                    env=env,
                    stderr=proxy_log,
                    start_new_session=True,
                )

                def proxy_ready():
                    if proxy.poll() is not None:
                        raise RuntimeError("mitmdump exited; see proxy.log")
                    return (session / "proxy.ready").exists() and (
                        ca_dir / "mitmproxy-ca-cert.pem"
                    ).exists()

                wait_for(
                    proxy_ready,
                    "mitmproxy (approve Mitmproxy Redirector if prompted)" if is_ios else "mitmproxy",
                    timeout=120 if is_ios else 30,
                )
                emulator_process = None
                if simulator:
                    print("Booting a disposable iOS Simulator…", flush=True)
                    simulator.start()
                    device = simulator
                else:
                    emulator = Emulator(
                        temporary,
                        emulator_log,
                        port,
                        args.headless,
                        system_image,
                        dimensions=dimensions,
                    )
                    print("Booting a disposable Android API 36 emulator…", flush=True)
                    emulator_process = emulator.start()
                    device = emulator
                device.install_ca(ca_dir / "mitmproxy-ca-cert.pem")
                metadata["device"] = device.serial
                save()
                if args.record:
                    recording = (
                        SimulatorRecording(simulator, session) if simulator else
                        ScreenRecording(emulator, session)
                    )
                    recording.start()
                    print("Recording the device screen (no audio).", flush=True)

                def launch_app():
                    device.launch(artifact, package, activity)
                    if emulator:
                        foreground = emulator.foreground
                        wait_for(
                            lambda: foreground(package),
                            "app in foreground",
                            timeout=30,
                        )
                    metadata["state"] = "capturing"
                    save()

                def device_running():
                    if simulator:
                        return simulator.is_booted()
                    assert emulator_process is not None
                    return emulator_process.poll() is None

                def check_running():
                    if proxy.poll() is not None:
                        raise RuntimeError(
                            "mitmdump stopped unexpectedly; see proxy.log"
                        )
                    if not device_running():
                        raise RuntimeError(
                            "Device stopped during scenario; see emulator.log"
                        )
                    if recording:
                        recording.check()

                if executor:
                    print(
                        f"Running scenario on {device.serial}: {scenario}\n"
                        f"Scenario log: {session / 'scenario.log'}",
                        flush=True,
                    )
                    run_scenario(
                        executor,
                        serial=device.serial,
                        device_id=device.device_id,
                        package=package,
                        session=session,
                        timeout=args.scenario_timeout,
                        check_running=check_running,
                        backend=args.backend,
                        launch_app=launch_app,
                    )
                    metadata["state"] = "scenario completed"
                else:
                    launch_app()
                    print(
                        f"App running on {device.serial}. " + (
                            "Press Ctrl+C to finish." if is_ios else
                            f"Close/leave the app for {args.close_grace:g}s, or press Ctrl+C to finish."
                        ),
                        flush=True,
                    )
                    absent_since = None
                    while True:
                        if proxy.poll() is not None:
                            raise RuntimeError(
                                "mitmdump stopped unexpectedly; see proxy.log"
                            )
                        if not device_running():
                            metadata["state"] = "simulator closed" if is_ios else "emulator closed"
                            break
                        if recording:
                            recording.check()
                        if emulator is None or emulator.foreground(package):
                            absent_since = None
                        elif absent_since is None:
                            absent_since = time.monotonic()
                        elif time.monotonic() - absent_since >= args.close_grace:
                            metadata["state"] = "app closed"
                            break
                        time.sleep(1)
            finally:
                # Ignore a second interrupt while stopping only our own children.
                previous = {
                    sig: signal.signal(sig, signal.SIG_IGN)
                    for sig in (signal.SIGINT, signal.SIGTERM)
                }
                try:
                    if recording:
                        try:
                            video = recording.stop()
                            if video:
                                metadata["recording"] = video.name
                        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                            # Keep the original audit failure as well as any
                            # recording failure, and always clean up the device.
                            recording_failure = f"Could not save recording: {error}"
                            metadata["recording_failure"] = recording_failure
                            print(recording_failure, file=sys.stderr, flush=True)
                    try:
                        if simulator:
                            try:
                                simulator.close()
                            except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
                                cleanup_failure = f"Simulator cleanup failed: {error}"
                                metadata["device_cleanup_failure"] = cleanup_failure
                                print(cleanup_failure, file=sys.stderr, flush=True)
                            finally:
                                metadata["device"] = simulator.serial
                        elif emulator:
                            emulator.close()
                    finally:
                        stop_proxy(proxy)
                finally:
                    for sig, handler in previous.items():
                        signal.signal(sig, handler)
    except KeyboardInterrupt:
        metadata["state"] = "interrupted by user"
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        metadata["state"] = "failed"
        detail = getattr(error, "stderr", None) or str(error)
        # TimeoutExpired retains bytes even when subprocess.run uses text=True.
        if isinstance(detail, bytes):
            detail = detail.decode(errors="replace")
        metadata["failure"] = detail
        failure = detail
    finally:
        if cleanup_failure and not failure:
            metadata["state"] = "failed"
            metadata["failure"] = cleanup_failure
            failure = cleanup_failure
        if recording_failure and not failure:
            metadata["state"] = "failed"
            metadata["failure"] = recording_failure
            failure = recording_failure
        if args.output_har:
            if (session / "session.har").is_file():
                metadata["har"] = "session.har"
            else:
                har_failure = "Could not save session.har; see proxy.log (session.har.partial may remain)"
                metadata["har_failure"] = har_failure
                print(har_failure, file=sys.stderr, flush=True)
                if not failure:
                    metadata["state"] = "failed"
                    metadata["failure"] = har_failure
                    failure = har_failure
        metadata["ended"] = datetime.now(UTC).isoformat()
        save()
        report = generate_report(session)
        summary = session / "report.txt"
        print(
            f"\nReport: {report}\nText report: {summary}\nRaw flows: {session / 'flows.mitm'}\n",
            flush=True,
        )
        if "recording" in metadata:
            print(f"Video: {session / metadata['recording']}\n", flush=True)
        if "har" in metadata:
            print(f"HAR: {session / metadata['har']}\n", flush=True)
        print(summary.read_text(), end="", flush=True)
    if failure:
        raise RuntimeError(failure)
    if scenario and metadata["state"] == "interrupted by user":
        return 130
    return 0


def interrupt(*_):
    raise KeyboardInterrupt


def main():
    os.umask(0o077)
    # A terminated automated run should still clean up and emit a partial report.
    signal.signal(signal.SIGTERM, interrupt)
    try:
        if len(sys.argv) > 1 and sys.argv[1] == "report":
            regenerate = argparse.ArgumentParser(
                description="Regenerate HTML and text reports from an existing audit session"
            )
            regenerate.add_argument("session", type=Path)
            args = regenerate.parse_args(sys.argv[2:])
            session = args.session.resolve()
            print(generate_report(session))
            summary = session / "report.txt"
            print(f"Text report: {summary}\n")
            print(summary.read_text(), end="", flush=True)
            return 0
        return audit(parser().parse_args())
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"network-audit: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
