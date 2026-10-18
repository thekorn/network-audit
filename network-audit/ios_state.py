"""Experimental cold Simulator checkpoints, isolated from the default device set.

CoreSimulator owns cloning/registration; ditto preserves the dormant device set's
macOS metadata. Never open a saved set with CoreSimulator: even listing a set can
write metadata. Restore from a verified temporary copy instead.
"""

import hashlib
import json
import os
import platform
import shutil
import stat
import subprocess
import tempfile
import uuid
from datetime import UTC, datetime
from pathlib import Path

from android import run
from state import file_digest


def tree_manifest(directory):
    """Describe content, modes and links without following directory symlinks."""
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError(f"Missing or linked checkpoint directory: {directory}")

    def unreadable(error):
        raise error

    entries = {}
    for parent, directories, files in os.walk(directory, followlinks=False, onerror=unreadable):
        for name in sorted(directories + files):
            path = Path(parent) / name
            info = path.lstat()
            entry: dict[str, str | int] = {"mode": stat.S_IMODE(info.st_mode)}
            if stat.S_ISLNK(info.st_mode):
                entry.update(kind="link", target=os.readlink(path))
            elif stat.S_ISDIR(info.st_mode):
                entry.update(kind="directory")
            elif stat.S_ISREG(info.st_mode):
                entry.update(kind="file", size=info.st_size, sha256=file_digest(path))
            else:
                raise ValueError(f"Unsupported checkpoint file: {path}")
            entries[path.relative_to(directory).as_posix()] = entry
    return entries


def checkpoint_identity(app, package, configuration):
    runtime, device_type, _application = configuration
    runtimes = json.loads(run(["xcrun", "simctl", "list", "runtimes", "--json"]))["runtimes"]
    selected = next((item for item in runtimes if item["identifier"] == runtime), None)
    if selected is None or not selected.get("version") or not selected.get("buildversion"):
        raise ValueError("Cannot identify the selected iOS runtime build for checkpointing")
    framework = Path("/Library/Developer/PrivateFrameworks/CoreSimulator.framework")
    developer = Path(os.environ.get("DEVELOPER_DIR") or run(["xcode-select", "-p"]))
    entries = tree_manifest(app)
    for name, entry in entries.items():
        if entry["kind"] == "link" and not (app / name).resolve().is_relative_to(app.resolve()):
            raise ValueError("Checkpoint app bundles must not link to files outside the .app")
    bundle = json.dumps(entries, sort_keys=True).encode()
    return {
        "package": package,
        "app_sha256": hashlib.sha256(bundle).hexdigest(),
        "runtime": runtime,
        "runtime_version": selected["version"],
        "runtime_build": selected["buildversion"],
        "device_type": device_type,
        "developer_dir": str(developer.resolve()),
        "xcode": run(["xcrun", "xcodebuild", "-version"]),
        "coresimulator_sha256": file_digest(framework / "CoreSimulator"),
        "macos": platform.mac_ver()[0],
        "architecture": platform.machine(),
    }


class CloneTool:
    def __init__(self, directory, identity):
        self.developer = identity["developer_dir"]
        self.path = directory / "ios-clone"
        # This source ships with the Python tool, including the Nix package.
        # No downloaded helper or extra dependency; full Xcode is already needed.
        run([
            "xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-framework", "Foundation",
            str(Path(__file__).with_name("ios_clone.m")), "-o", str(self.path),
        ], timeout=120)

    def clone(self, source_set, destination_set, serial, name):
        try:
            identifier = run([
                str(self.path), self.developer,
                str(source_set.resolve()) if source_set is not None else "-",
                str(destination_set.resolve()) if destination_set is not None else "-",
                serial, name,
            ], timeout=600)
        except subprocess.CalledProcessError as error:
            # Saves happen during cleanup, where the normal CLI subprocess-error
            # handler cannot display stderr. Preserve native API diagnostics.
            raise RuntimeError(error.stderr or str(error)) from error
        return str(uuid.UUID(identifier)).upper()


def copy_device_set(source, destination):
    # shutil.copytree does not preserve all macOS metadata. Explicit flags also
    # override a caller's DITTONORSRC. Neither endpoint may be a symlink.
    if source.is_symlink() or not source.is_dir() or destination.exists() or destination.is_symlink():
        raise ValueError("Device-set copy requires a real source and a new destination")
    run([
        "/usr/bin/ditto", "--rsrc", "--extattr", "--acl", str(source), str(destination),
    ], timeout=600)


class Checkpoint:
    def __init__(self, path):
        path = path.resolve()
        self.path = path if (path / "manifest.json").is_file() else path / "state"
        try:
            self.manifest = json.loads((self.path / "manifest.json").read_text())
        except (OSError, ValueError) as error:
            raise ValueError(f"Cannot read a complete iOS state checkpoint at {path}: {error}") from error
        manifest = self.manifest
        if (
            not isinstance(manifest, dict)
            or type(manifest.get("version")) is not int
            or manifest["version"] != 1
            or manifest.get("format") != "ios-simulator-set"
            or not isinstance(manifest.get("identity"), dict)
            or not isinstance(manifest.get("entries"), dict)
            or not isinstance(manifest.get("device"), str)
        ):
            raise ValueError("Invalid or incompatible iOS state checkpoint manifest")
        try:
            self.serial = str(uuid.UUID(manifest["device"])).upper()
        except ValueError as error:
            raise ValueError("Invalid iOS checkpoint device UUID") from error
        if self.serial != manifest["device"]:
            raise ValueError("Invalid iOS checkpoint device UUID")
        self.device_set = self.path / "device-set"
        for relative, kind in ((f"{self.serial}/device.plist", "file"), (f"{self.serial}/data", "directory")):
            entry = manifest["entries"].get(relative)
            if not isinstance(entry, dict) or entry.get("kind") != kind:
                raise ValueError("Incomplete iOS checkpoint device set")

    def validate(self, identity):
        if self.manifest["identity"] != identity:
            mismatched = sorted(
                key for key in identity if self.manifest["identity"].get(key) != identity[key]
            )
            raise ValueError(
                "Incompatible iOS state checkpoint: " + ", ".join(mismatched)
                + ". Use the same app, Xcode, iOS runtime, device type and macOS/architecture."
            )
        self.verify(self.device_set)

    def verify(self, directory):
        if tree_manifest(directory) != self.manifest["entries"]:
            raise ValueError("iOS state checkpoint is corrupt or incomplete")

    def restore(self, simulator, tool):
        self.verify(self.device_set)
        with tempfile.TemporaryDirectory(prefix="network-audit-restore-") as temporary:
            working = Path(temporary) / "device-set"
            required = sum(entry.get("size", 0) for entry in self.manifest["entries"].values())
            if shutil.disk_usage(temporary).free < required + 1024**3:
                raise RuntimeError("Insufficient temporary storage to restore iOS state checkpoint")
            # Do not let even the clone operation open the saved set itself.
            copy_device_set(self.device_set, working)
            self.verify(working)
            simulator.clone(tool, working, self.serial)


def save_checkpoint(simulator, session, identity, tool):
    """Shutdown must succeed before cloning; never publish a partial checkpoint."""
    destination = session / "state"
    if destination.exists() or destination.is_symlink():
        raise ValueError(f"Refusing to replace an existing checkpoint: {destination}")
    simulator.power_off()
    with (
        tempfile.TemporaryDirectory(prefix="network-audit-save-") as temporary,
        tempfile.TemporaryDirectory(prefix=".state-", dir=session) as staging,
    ):
        live_set = Path(temporary) / "device-set"
        live_set.mkdir(mode=0o700)
        serial = tool.clone(None, live_set, simulator.serial, f"{simulator.name}-checkpoint")
        staged = Path(staging) / "state"
        staged.mkdir(mode=0o700)
        archived = staged / "device-set"
        entries = tree_manifest(live_set)
        required = sum(entry.get("size", 0) for entry in entries.values())
        if shutil.disk_usage(session).free < required + 1024**3:
            raise RuntimeError("Insufficient storage to save iOS state checkpoint")
        copy_device_set(live_set, archived)
        if tree_manifest(archived) != entries:
            raise ValueError("iOS checkpoint copy is incomplete")
        manifest = {
            "version": 1,
            "format": "ios-simulator-set",
            "created": datetime.now(UTC).isoformat(),
            "source_run": session.name,
            "identity": identity,
            "device": serial,
            "entries": entries,
        }
        manifest_file = staged / "manifest.json"
        manifest_file.write_text(json.dumps(manifest, indent=2) + "\n")
        manifest_file.chmod(0o600)
        Checkpoint(staged)
        staged.rename(destination)
    return destination
