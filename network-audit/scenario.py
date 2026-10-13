"""Load a scenario definition and run its trusted Mobilewright executor."""

import json
import os
import shutil
import signal
import subprocess
import tempfile
import time
import tomllib
from pathlib import Path

from jsonschema import ValidationError, validate

from android import DIMENSION_SHORTCUTS, wait_for
from domains import normalize_domains

RUNNER = Path(
    os.environ.get(
        "NETWORK_AUDIT_SCENARIO_RUNNER",
        Path(__file__).resolve().parent / "mobilewright" / "runner.mjs",
    )
)


def load_scenario(path):
    path = path.resolve()
    if not path.is_file() or path.suffix != ".toml":
        raise ValueError(f"Scenario must be an existing .toml file: {path}")
    try:
        config = tomllib.loads(path.read_text())
    except tomllib.TOMLDecodeError as error:
        raise ValueError(f"Invalid scenario TOML: {path}: {error}") from error
    schema = json.loads(Path(__file__).with_name("scenario.schema.json").read_text())
    try:
        validate(config, schema)
    except ValidationError as error:
        field = ".".join(map(str, error.absolute_path)) or "<root>"
        raise ValueError(
            f"Invalid scenario schema: {path}: {field}: {error.message}"
        ) from error
    domains = normalize_domains(config["domains"]) if "domains" in config else None
    env_file = (path.parent / config["env-file"]).resolve() if "env-file" in config else None
    dimensions = config.get("dimensions")
    if isinstance(dimensions, str):
        dimensions = DIMENSION_SHORTCUTS[dimensions]
    # JSON Schema accepts integral floats too; write canonical integers to the AVD.
    if dimensions is not None:
        dimensions = {key: int(value) for key, value in dimensions.items()}
    return (
        domains,
        validate_executor(path.parent / config["executor"]),
        env_file,
        dimensions,
        config.get("flavor"),
    )


def validate_executor(path):
    path = path.resolve()
    if not path.is_file() or path.suffix not in (".js", ".mjs"):
        raise ValueError(f"Executor must be an existing .js or .mjs file: {path}")
    if not shutil.which("node"):
        raise RuntimeError("Scenarios need Node.js >=22.12. Use devenv or the Nix package.")
    checks = (
        (
            ["node", str(RUNNER), "--check"],
            "Scenario runtime unavailable. Re-enter devenv or rebuild the Nix package.",
        ),
        (["node", "--check", str(path)], f"Invalid executor syntax: {path}"),
    )
    for command, message in checks:
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        if result.returncode:
            raise RuntimeError(f"{message}\n{result.stderr}")
    return path


def stop_group(process, grace=5):
    """Stop our children, including descendants left behind by an exited parent."""
    if process is None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        pass
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def run_scenario(
    path, *, serial, device_id, package, session, timeout, check_running,
    backend="android", launch_app=None,
):
    deadline = time.monotonic() + timeout
    binary = subprocess.run(
        ["node", str(RUNNER), "--check"],
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    ).stdout.strip()
    # mobilecli normally auto-starts a detached daemon. Own a foreground daemon
    # instead, with a private, short Unix socket path (also on macOS).
    with (
        tempfile.TemporaryDirectory(prefix="na-mw-", dir="/tmp") as home,
        (session / "scenario.log").open("w") as log,
    ):
        env = {**os.environ, "MOBILECLI_HOME": home}
        daemon = subprocess.Popen(
            [binary, "daemon", "start", "--idle-timeout", "0"],
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        process = None

        def check():
            check_running()
            if daemon.poll() is not None:
                raise RuntimeError("Mobilecli daemon stopped; see scenario.log")
            if time.monotonic() >= deadline:
                raise RuntimeError(
                    f"Scenario timed out after {timeout:g}s; see scenario.log"
                )

        def daemon_ready():
            check()
            return (Path(home) / "daemon.sock").exists()

        def execute(command, description):
            nonlocal process
            check()
            process = subprocess.Popen(
                command,
                env=env,
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            while True:
                check()
                status = process.poll()
                if status is not None:
                    if status != 0:
                        raise RuntimeError(
                            f"{description} exited with status {status}; see scenario.log"
                        )
                    return
                time.sleep(0.2)

        try:
            wait_for(daemon_ready, "Mobilecli daemon", timeout=min(timeout, 10))
            if backend == "ios":
                # Mobilewright 0.0.64 throws on a missing agent's status exit
                # before reaching its auto-install branch. Use the pinned CLI.
                execute(
                    [binary, "agent", "install", "--device", device_id],
                    "iOS agent installation",
                )
                # This starts DeviceKit lazily. Starting it after our app would
                # background that app; do it under our private daemon first.
                execute(
                    [binary, "apps", "foreground", "--device", device_id],
                    "iOS agent startup",
                )
            if launch_app is not None:
                check()
                launch_app()
            execute(
                [
                    "node", str(RUNNER), str(path), serial, device_id,
                    package, str(session), backend,
                ],
                "Scenario",
            )
        finally:
            # Ignore repeated interrupts until both owned process groups stop.
            previous = {
                sig: signal.signal(sig, signal.SIG_IGN)
                for sig in (signal.SIGINT, signal.SIGTERM)
            }
            try:
                try:
                    stop_group(process)
                finally:
                    # Foreground mobilecli handles SIGTERM with its shutdown
                    # hooks, including stopping the on-device helper.
                    stop_group(daemon, grace=15)
                    # If mobilecli replaced a crashed daemon automatically,
                    # stop that replacement through only our private socket.
                    if (Path(home) / "daemon.sock").exists():
                        subprocess.run(
                            [binary, "daemon", "stop"],
                            env=env,
                            stdout=log,
                            stderr=subprocess.STDOUT,
                            check=True,
                            timeout=15,
                        )
            finally:
                for sig, handler in previous.items():
                    signal.signal(sig, handler)
