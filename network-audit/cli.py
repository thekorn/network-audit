#!/usr/bin/env python3
"""Build, launch, capture, and report a local Android audit."""

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
import tomllib
from datetime import UTC, datetime
from pathlib import Path

from android import Emulator, apk_identity, wait_for
from domains import normalize_domains, proxy_pattern
from report import generate_report

ROOT = Path(__file__).resolve().parent


def parser():
    result = argparse.ArgumentParser(prog="network-audit", description=__doc__)
    result.add_argument(
        "app", type=Path, help="Flutter project directory or Android APK"
    )
    result.add_argument(
        "--domain",
        action="append",
        help="Exact hostname or '*.example.com'; repeatable; overrides app config",
    )
    result.add_argument(
        "--output",
        type=Path,
        default=Path(".network-audit/runs"),
        help="Parent directory for private session files",
    )
    result.add_argument(
        "--headless",
        action="store_true",
        help="Hide the emulator window (for automation)",
    )
    result.add_argument(
        "--close-grace",
        type=float,
        default=5,
        help="Seconds outside the foreground before finishing (default: 5)",
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
    if (
        not math.isfinite(args.close_grace)
        or args.close_grace <= 0
        or args.body_limit <= 0
    ):
        raise ValueError("--close-grace and --body-limit must be positive")
    config_file = (app if app.is_dir() else app.parent) / "network-audit.toml"
    config = tomllib.loads(config_file.read_text()) if config_file.exists() else {}
    domains = normalize_domains(
        args.domain if args.domain is not None else config.get("domains", [])
    )
    if sys.platform != "linux" or not os.access("/dev/kvm", os.R_OK | os.W_OK):
        raise RuntimeError(
            "A KVM-capable Linux host is required. In Amp use thekorn-amp-runner; never run an emulator in an orb."
        )
    for tool in (
        "adb",
        "emulator",
        "avdmanager",
        "mitmdump",
        "openssl",
        *(["flutter"] if app.is_dir() else []),
    ):
        if not shutil.which(tool):
            raise RuntimeError(
                f"Missing {tool}. Enter devenv with androidEmulator.enable = true on the KVM host."
            )
    if app.is_dir():
        if not (app / "pubspec.lock").exists():
            raise ValueError("Flutter projects must have a committed pubspec.lock")
        subprocess.run(
            ["flutter", "pub", "get", "--enforce-lockfile"], cwd=app, check=True
        )
        subprocess.run(
            ["flutter", "build", "apk", "--debug", "--no-pub"], cwd=app, check=True
        )
        apk = app / "build/app/outputs/flutter-apk/app-debug.apk"
    else:
        apk = app
    package, activity = apk_identity(apk)
    args.output.mkdir(parents=True, exist_ok=True)
    session = Path(
        tempfile.mkdtemp(
            prefix=datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ-"),
            dir=args.output,
        )
    ).resolve()
    metadata = {
        "app": app.name,
        "package": package,
        "domains": domains,
        "started": datetime.now(UTC).isoformat(),
        "state": "starting",
        "body_limit": args.body_limit,
        "close_grace": args.close_grace,
    }

    def save():
        (session / "session.json").write_text(json.dumps(metadata, indent=2) + "\n")

    save()
    print(f"Session: {session}\nCapturing: {', '.join(domains)}", flush=True)
    print(
        "Sensitive data: headers and bodies are not redacted. Keep reports private.",
        flush=True,
    )
    proxy = emulator = None
    failure = None
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
                }
                proxy = subprocess.Popen(
                    [
                        "mitmdump",
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
                        f"allow_hosts={proxy_pattern(domains)}",
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

                wait_for(proxy_ready, "mitmproxy", timeout=30)
                emulator = Emulator(temporary, emulator_log, port, args.headless)
                print("Booting a disposable Android API 36 emulator…", flush=True)
                emulator_process = emulator.start()
                emulator.install_ca(ca_dir / "mitmproxy-ca-cert.pem")
                metadata["device"] = emulator.serial
                save()
                emulator.launch(apk, package, activity)
                wait_for(
                    lambda: emulator.foreground(package),
                    "app in foreground",
                    timeout=30,
                )
                metadata["state"] = "capturing"
                save()
                print(
                    f"App running on {emulator.serial}. Close/leave the app for {args.close_grace:g}s, or press Ctrl+C to finish.",
                    flush=True,
                )
                absent_since = None
                while True:
                    if proxy.poll() is not None:
                        raise RuntimeError(
                            "mitmdump stopped unexpectedly; see proxy.log"
                        )
                    if emulator_process.poll() is not None:
                        metadata["state"] = "emulator closed"
                        break
                    if emulator.foreground(package):
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
                    try:
                        if emulator:
                            emulator.close()
                    finally:
                        stop_proxy(proxy)
                finally:
                    for sig, handler in previous.items():
                        signal.signal(sig, handler)
    except KeyboardInterrupt:
        metadata["state"] = "interrupted by user"
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        metadata["state"] = "failed"
        detail = getattr(error, "stderr", None) or str(error)
        # TimeoutExpired retains bytes even when subprocess.run uses text=True.
        if isinstance(detail, bytes):
            detail = detail.decode(errors="replace")
        metadata["failure"] = detail
        failure = detail
    finally:
        metadata["ended"] = datetime.now(UTC).isoformat()
        save()
        report = generate_report(session)
        print(f"\nReport: {report}\nRaw flows: {session / 'flows.mitm'}", flush=True)
    if failure:
        raise RuntimeError(failure)
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
                description="Regenerate HTML from an existing audit session"
            )
            regenerate.add_argument("session", type=Path)
            args = regenerate.parse_args(sys.argv[2:])
            print(generate_report(args.session.resolve()))
            return 0
        return audit(parser().parse_args())
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"network-audit: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
