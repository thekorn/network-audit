"""Versioned, private cold-device checkpoints, never booted in place.

Flatten the emulator's writable QCOW2 chains into standalone sparse raw images.
Only these images cross runs: no RAM snapshots, locks or proxy private keys.
"""

import hashlib
import json
import os
import platform
import re
import shutil
import sys
import tempfile
from datetime import UTC, datetime
from pathlib import Path

from android import run

DISKS = ("userdata-qemu.img", "encryptionkey.img", "cache.img", "sdcard.img")
BLOCK = bytes(1024 * 1024)


def file_digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def checkpoint_identity(apk, package, system_image):
    sdk = Path(os.environ["ANDROID_HOME"])
    image = sdk.joinpath(*system_image.split(";"))
    emulator = shutil.which("emulator")
    if emulator is None:
        raise RuntimeError("Missing emulator")
    return {
        "package": package,
        "apk_sha256": file_digest(apk),
        "system_image": system_image,
        "image_path": str(image.resolve()),
        "image_sha256": file_digest(image / "package.xml"),
        "emulator_path": str(Path(emulator).resolve()),
        "emulator_version": run(["emulator", "-version"]).splitlines()[0],
        "host": sys.platform,
        "architecture": platform.machine(),
    }


def image_tool():
    tool = Path(os.environ["ANDROID_HOME"]) / "emulator" / "qemu-img"
    if not tool.is_file() or not os.access(tool, os.X_OK):
        raise RuntimeError(f"State checkpoints require the SDK's bundled qemu-img: {tool}")
    return tool


def avd_configuration(directory):
    # Compare hardware and partition sizes, not the new AVD's identity/paths.
    return {
        key: value
        for line in (directory / "config.ini").read_text().splitlines()
        if "=" in line
        for key, value in [line.split("=", 1)]
        if key.startswith(("hw.", "disk.")) and not key.endswith(".path")
    }


def copy_disk(source, destination, expected):
    """Copy and verify in one pass, preserving holes without platform tools."""
    digest = hashlib.sha256()
    size = 0
    with source.open("rb") as reader, destination.open("wb") as writer:
        while chunk := reader.read(len(BLOCK)):
            digest.update(chunk)
            size += len(chunk)
            if chunk == BLOCK[:len(chunk)]:
                writer.seek(len(chunk), os.SEEK_CUR)
            else:
                writer.write(chunk)
        writer.truncate(size)
    if size != expected["size"] or digest.hexdigest() != expected["sha256"]:
        raise ValueError(f"State checkpoint disk is corrupt: {source.name}")


class Checkpoint:
    def __init__(self, path):
        path = path.resolve()
        self.path = path if (path / "manifest.json").is_file() else path / "state"
        try:
            self.manifest = json.loads((self.path / "manifest.json").read_text())
        except (OSError, ValueError) as error:
            raise ValueError(f"Cannot read a complete state checkpoint at {path}: {error}") from error
        manifest = self.manifest
        if (
            not isinstance(manifest, dict)
            or type(manifest.get("version")) is not int
            or manifest["version"] != 1
        ):
            raise ValueError("Unsupported state checkpoint version")
        if (
            manifest.get("format") != "android-cold-raw"
            or not isinstance(manifest.get("identity"), dict)
            or not isinstance(manifest.get("configuration"), dict)
            or not isinstance(manifest.get("webview"), str)
            or "dimensions" not in manifest
            or not isinstance(manifest.get("files"), dict)
            or not set(DISKS[:3]).issubset(manifest["files"])
        ):
            raise ValueError("Invalid state checkpoint manifest")
        dimensions = manifest.get("dimensions")
        if dimensions is not None and (
            not isinstance(dimensions, dict)
            or set(dimensions) != {"width", "height", "density"}
            or any(type(value) is not int or value <= 0 for value in dimensions.values())
        ):
            raise ValueError("Invalid state checkpoint dimensions")
        for name, entry in manifest["files"].items():
            if (
                name not in DISKS
                or not isinstance(entry, dict)
                or type(entry.get("size")) is not int
                or entry["size"] <= 0
                or not isinstance(entry.get("sha256"), str)
                or not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"])
            ):
                raise ValueError("Invalid state checkpoint disk entry")
            disk = self.path / name
            if disk.is_symlink() or not disk.is_file() or disk.stat().st_size != entry["size"]:
                raise ValueError(f"State checkpoint disk is missing or incomplete: {name}")

    def validate(self, identity, dimensions):
        if self.manifest["identity"] != identity:
            mismatched = sorted(
                key for key in identity if self.manifest["identity"].get(key) != identity[key]
            )
            raise ValueError(
                "Incompatible state checkpoint: " + ", ".join(mismatched)
                + ". Use the same APK and pinned emulator/system image on the same host architecture."
            )
        if dimensions is not None and dimensions != self.manifest["dimensions"]:
            raise ValueError("Incompatible state checkpoint: display dimensions differ")

    def restore(self, directory):
        if avd_configuration(directory) != self.manifest["configuration"]:
            raise ValueError("Incompatible state checkpoint: AVD hardware configuration differs")
        required = sum(entry["size"] for entry in self.manifest["files"].values())
        if shutil.disk_usage(directory).free < required + 1024**3:
            raise RuntimeError("Insufficient temporary storage to restore state checkpoint")
        for name, entry in self.manifest["files"].items():
            copy_disk(self.path / name, directory / name, entry)


def save_checkpoint(directory, session, identity, dimensions, webview):
    """Caller must have powered off the guest and waited for a clean exit."""
    destination = session / "state"
    if destination.exists():
        raise ValueError(f"Refusing to replace an existing checkpoint: {destination}")
    tool = image_tool()
    with tempfile.TemporaryDirectory(prefix=".state-", dir=session) as temporary:
        staged = Path(temporary) / "state"
        staged.mkdir(mode=0o700)
        files = {}
        for name in DISKS:
            base = directory / name
            overlay = directory / f"{name}.qcow2"
            source = overlay if overlay.is_file() else base
            if not source.is_file():
                continue
            if source.is_symlink():
                raise ValueError(f"Refusing to checkpoint a linked disk: {source}")
            # Explicit formats avoid probing restored raw files as image metadata.
            with source.open("rb") as image:
                image_format = "qcow2" if image.read(4) == b"QFI\xfb" else "raw"
            target = staged / name
            run(
                [str(tool), "convert", "-f", image_format, "-O", "raw", str(source), str(target)],
                timeout=600,
            )
            target.chmod(0o600)
            files[name] = {"size": target.stat().st_size, "sha256": file_digest(target)}
        missing = set(DISKS[:3]) - files.keys()
        if missing:
            raise RuntimeError("Missing checkpoint disks: " + ", ".join(sorted(missing)))
        manifest = {
            "version": 1,
            "format": "android-cold-raw",
            "created": datetime.now(UTC).isoformat(),
            "source_run": session.name,
            "identity": identity,
            "dimensions": dimensions,
            "configuration": avd_configuration(directory),
            "webview": webview,
            "files": files,
        }
        manifest_file = staged / "manifest.json"
        manifest_file.write_text(json.dumps(manifest, indent=2) + "\n")
        manifest_file.chmod(0o600)
        # A failed conversion must never look like a usable checkpoint.
        Checkpoint(staged)
        staged.rename(destination)
    return destination
