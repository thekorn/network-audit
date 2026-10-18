"""Discover, browse, and explicitly delete saved audit runs."""

import argparse
import curses
import json
import os
import shutil
import stat
import sys
import textwrap
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path


def display(value):
    # Paths and stored metadata are untrusted terminal input, not ANSI markup.
    return "".join(char if char.isprintable() else "?" for char in str(value))


def size(value):
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if value < 1024 or unit == "TiB":
            return f"{value:.0f} B" if unit == "B" else f"{value:.1f} {unit}"
        value /= 1024


@dataclass
class Run:
    path: Path
    metadata: dict = field(default_factory=dict)
    files: dict = field(default_factory=dict)
    warnings: list = field(default_factory=list)
    disk_bytes: int = 0
    logical_bytes: int = 0
    inodes: set = field(default_factory=set, repr=False)
    identity: tuple[int, int] | None = None

    def artifact(self, names, *, partial=(), recorded=None, requested=None, failure=None):
        if all(name in self.files for name in names):
            return "saved"
        if partial and any(name.startswith(partial) for name in self.files):
            return "partial"
        if failure and self.metadata.get(failure):
            return "failed"
        if recorded and self.metadata.get(recorded):
            return "missing"
        if requested and self.metadata.get(requested):
            return "missing" if self.metadata.get("ended") else "requested"
        return "-"

    def features(self):
        return {
            "HAR": self.artifact(
                ("session.har",), partial=("session.har.partial",),
                recorded="har", failure="har_failure",
            ),
            "State": self.artifact(
                ("state/manifest.json",), partial=("state/", ".state-"),
                recorded="state_checkpoint", requested="save_state", failure="state_failure",
            ),
            "Video": self.artifact(
                ("recording.mp4",), partial=("recording.partial.mp4",),
                recorded="recording", failure="recording_failure",
            ),
            "HTML": self.artifact(("report.html",)),
            "Text": self.artifact(("report.txt",)),
            "Flows": self.artifact(("flows.mitm",)),
            "Events": self.artifact(("events.jsonl",)),
            "Ads": self.artifact(("ad-events.jsonl",)),
            "Scenario": "yes" if self.metadata.get("scenario") else "-",
            "Restored": "yes" if self.metadata.get("restored_from") else "-",
        }


def scan(root: Path):
    """One walk; nested runs own their files, links never escape the root."""
    if not root.is_dir():
        raise ValueError(f"Audit directory not found or not a directory: {root}")
    runs = []
    warnings = []
    owners: dict[Path, Run | None] = {root: None}

    def unreadable(error):
        warnings.append(f"Cannot scan {error.filename}: {error.strerror}; sizes may be incomplete")

    for directory, directories, filenames in os.walk(root, onerror=unreadable):
        path = Path(directory)
        owner = owners.pop(path, None)
        entries = {}
        for name in filenames:
            try:
                info = (path / name).lstat()
                if stat.S_ISREG(info.st_mode):
                    entries[name] = info
            except OSError as error:
                unreadable(error)
        if "session.json" in entries:
            try:
                info = path.stat(follow_symlinks=False)
            except OSError as error:
                unreadable(error)
                continue
            owner = Run(path, identity=(info.st_dev, info.st_ino))
            runs.append(owner)
            try:
                metadata = json.loads((path / "session.json").read_text())
                if not isinstance(metadata, dict):
                    raise ValueError("expected a JSON object")
                owner.metadata = metadata
            except (OSError, ValueError) as error:
                owner.warnings.append(f"Cannot read session.json: {error}")
        if owner is not None:
            for name, info in entries.items():
                relative = (path / name).relative_to(owner.path).as_posix()
                inode = (info.st_dev, info.st_ino)
                disk = info.st_blocks * 512
                owner.files[relative] = (disk, info.st_size)
                if inode not in owner.inodes:
                    owner.inodes.add(inode)
                    owner.disk_bytes += disk
                    owner.logical_bytes += info.st_size
        # os.walk does not follow links; prune them here also to avoid retaining owners.
        directories[:] = sorted(name for name in directories if not (path / name).is_symlink())
        owners.update((path / name, owner) for name in directories)
    return sorted(runs, key=lambda run: run.path.as_posix(), reverse=True), warnings


def delete_run(root, run):
    """Recheck a confirmed selection; never follow links out of the run."""
    path = run.path
    if not path.is_relative_to(root) or path.resolve() != path:
        raise ValueError("Run path changed or is outside the audit directory; refresh first")
    info = path.stat(follow_symlinks=False)
    if not stat.S_ISDIR(info.st_mode) or (info.st_dev, info.st_ino) != run.identity:
        raise ValueError("Run directory was replaced; refresh first")
    current, warnings = scan(path)
    if warnings:
        raise ValueError("Cannot inspect the entire run; check permissions and refresh first")
    if len(current) > 1:
        raise ValueError("Contains nested runs; delete those first")
    if not current or current[0].path != path:
        raise ValueError("Run metadata is missing; refresh first")
    metadata = current[0].metadata
    if metadata.get("state") in ("starting", "capturing") and not metadata.get("ended"):
        raise ValueError("Run is marked active; stop the capture before deleting it")
    if not shutil.rmtree.avoids_symlink_attacks:
        raise ValueError("Safe directory deletion is unavailable on this platform")
    # Pin the parent so a renamed/relinked ancestor cannot redirect rmtree.
    parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        if not stat.S_ISDIR(info.st_mode) or (info.st_dev, info.st_ino) != run.identity:
            raise ValueError("Run directory was replaced; refresh first")
        shutil.rmtree(path.name, dir_fd=parent)
    finally:
        os.close(parent)


def details(run):
    metadata = run.metadata
    lines = [
        f"Path: {run.path}",
        f"App: {metadata.get('app', '?')} | Backend: {metadata.get('backend', '?')}",
        f"Result: {metadata.get('state', '?')}",
        f"Started: {metadata.get('started', '?')} | Ended: {metadata.get('ended', '-')}",
        f"Disk: {size(run.disk_bytes)} ({run.disk_bytes} bytes) | "
        f"Logical: {size(run.logical_bytes)} ({run.logical_bytes} bytes)",
        "  ".join(f"{name}: {status}" for name, status in run.features().items()),
        f"Scenario: {metadata.get('scenario', '-')}",
        f"Restored from: {metadata.get('restored_from', '-')}",
    ]
    lines.extend(f"Warning: {warning}" for warning in run.warnings)
    lines.extend(
        f"{key}: {metadata[key]}"
        for key in ("failure", "har_failure", "state_failure", "recording_failure")
        if metadata.get(key)
    )
    lines.append("Files (disk / logical; hard links counted once in run totals):")
    lines.extend(
        f"  {size(disk):>10} / {size(logical):>10}  {name}"
        for name, (disk, logical) in sorted(run.files.items())
    )
    return [display(line) for line in lines]


def summary(root, runs, warnings):
    return [
        f"Network audit | {len(runs)} runs | {size(sum(run.disk_bytes for run in runs))} on disk",
        display(root),
        "Disk = allocated file blocks; logical = file lengths. Symlinks ignored.",
        "saved = artifact present, not validated; - = no evidence (older runs may not record options).",
        *(f"Warning: {display(warning)}" for warning in warnings),
    ]


def plain(root, runs, warnings):
    print("\n".join(summary(root, runs, warnings)))
    if not runs:
        print("No audit runs found (looking recursively for session.json).")
    for run in runs:
        print(f"\nRun: {display(run.path.relative_to(root))}")
        print("\n".join(details(run)))


def clipped(text, width):
    result = ""
    used = 0
    for char in display(text):
        cells = 0 if unicodedata.combining(char) else 2 if unicodedata.east_asian_width(char) in "WF" else 1
        if used + cells > width:
            break
        result += char
        used += cells
    return result


def browse(screen, root, runs, warnings):
    try:
        curses.curs_set(0)
    except curses.error:
        pass
    # Keep Escape responsive instead of waiting ncurses' one-second default.
    curses.set_escdelay(25)
    screen.keypad(True)
    selected = offset = 0
    expanded = False
    largest = False
    pending = None
    confirmation = message = ""
    while True:
        height, width = screen.getmaxyx()
        screen.erase()

        def put(row, text, attribute=0):
            if 0 <= row < height:
                try:
                    screen.addstr(row, 0, clipped(text, max(0, width - 1)), attribute)
                except curses.error:
                    # The terminal can resize between measuring and painting.
                    pass

        if height < 16 or width < 76:
            put(0, "Resize terminal to at least 76 x 16.", curses.A_BOLD)
            put(1, "q: quit")
            screen.refresh()
            if screen.get_wch() in ("q", "Q"):
                return
            continue
        selected = max(0, min(selected, len(runs) - 1))
        heading = summary(root, runs, warnings)
        put(0, heading[0], curses.A_BOLD)
        put(1, heading[1], curses.A_DIM)
        if pending is not None:
            path_lines = []
            remaining = display(pending.path)
            while remaining:
                line = clipped(remaining, width - 2)
                path_lines.append(line)
                remaining = remaining[len(line):]
            fits = len(path_lines) <= height - 10
            put(3, "Permanently delete this run?", curses.A_BOLD)
            for row, line in enumerate(path_lines[:height - 10], 5):
                put(row, line)
            put(height - 5, "Deletes ALL files in this run, including checkpoints. No undo.")
            put(height - 4, "Stop any capture first; stored status may be missing or stale.")
            put(height - 3, f"Type DELETE then Enter: {confirmation}" if fits else
                "Resize the terminal to see the full path before confirming.", curses.A_BOLD)
            put(height - 1, "Esc or q: cancel")
            screen.refresh()
            key = screen.get_wch()
            if key in ("\x1b", "q", "Q"):
                pending = None
                confirmation = ""
                message = "Deletion cancelled."
            elif key in ("\n", "\r", curses.KEY_ENTER) and fits and confirmation == "DELETE":
                try:
                    delete_run(root, pending)
                    message = f"Deleted: {pending.path.name}"
                except ValueError as error:
                    message = f"Not deleted: {error}"
                except OSError as error:
                    # A filesystem failure can happen after removing some files.
                    message = f"Delete failed (check remaining files): {error}"
                pending = None
                confirmation = ""
                expanded = False
                offset = 0
                runs, warnings = scan(root) if root.exists() else ([], [])
                runs.sort(key=lambda run: (run.disk_bytes if largest else 0, run.path.as_posix()), reverse=True)
            elif key in (curses.KEY_BACKSPACE, "\x7f", "\b"):
                confirmation = confirmation[:-1]
            elif isinstance(key, str) and key.isprintable() and len(confirmation) < 32:
                confirmation += key
            continue
        page = max(1, height - 12)
        lines = []
        if expanded and runs:
            lines = [part for line in details(runs[selected]) for part in textwrap.wrap(line, max(1, width - 2)) or [""]]
            page = max(1, height - 5 - (2 if message else 0))
            offset = min(offset, max(0, len(lines) - page))
            for row, line in enumerate(lines[offset:offset + page], 3):
                put(row, line)
        else:
            name_width = max(12, width - 42)
            put(3, f"{'RUN':<{name_width}} {'DISK':>10}  {'HAR':8} {'STATE':9} VIDEO", curses.A_BOLD)
            offset = max(0, min(offset, selected))
            if selected >= offset + page:
                offset = selected - page + 1
            for row, run in enumerate(runs[offset:offset + page], 4):
                name = clipped(str(run.path.relative_to(root)), name_width - 1)
                features = run.features()
                put(row, f"{name:<{name_width}} {size(run.disk_bytes):>10}  {features['HAR']:8} {features['State']:9} {features['Video']}",
                    curses.A_REVERSE if row - 4 + offset == selected else 0)
            if runs:
                run = runs[selected]
                features = run.features()
                put(height - 7, f"App: {run.metadata.get('app', '?')} | {run.metadata.get('backend', '?')} | {run.metadata.get('state', '?')}")
                put(height - 6, f"Logical: {size(run.logical_bytes)} | " + "  ".join(f"{key}: {features[key]}" for key in ("HTML", "Text", "Flows", "Ads")))
                put(height - 5, f"Scenario: {features['Scenario']} | Restored: {features['Restored']} | Enter: full path, features & files")
                if run.warnings:
                    put(height - 4, run.warnings[0], curses.A_BOLD)
            else:
                put(4, "No audit runs found (looking recursively for session.json).")
            if warnings:
                put(height - 3, f"Warning: {warnings[0]} ({len(warnings)} scan warnings)", curses.A_BOLD)
            else:
                put(height - 3, "saved = present, not validated; - = no evidence. Sizes exclude symlinks.", curses.A_DIM)
        if message:
            put(height - 4, message, curses.A_BOLD)
        put(height - 2, f"{selected + 1 if runs else 0}/{len(runs)} | Sort: {'largest first' if largest else 'path descending'}", curses.A_DIM)
        put(height - 1, "j/k: move | Enter/Esc: details | d: delete | s: sort | r: refresh | q: quit")
        screen.refresh()
        key = screen.get_wch()
        if key in ("q", "Q"):
            return
        if key == "d" and runs:
            pending = runs[selected]
            confirmation = message = ""
        elif key in ("\n", "\r", curses.KEY_ENTER, "\x1b"):
            expanded = not expanded if key != "\x1b" else False
            offset = 0
            message = ""
        elif key in ("r", "s"):
            current = runs[selected].path if runs else None
            if key == "r":
                put(0, "Scanning audit runs...", curses.A_BOLD)
                screen.refresh()
                runs, warnings = scan(root) if root.exists() else ([], [])
            else:
                largest = not largest
            runs.sort(key=lambda run: (run.disk_bytes if largest else 0, run.path.as_posix()), reverse=True)
            selected = next((index for index, run in enumerate(runs) if run.path == current), 0)
            offset = 0
        else:
            movement = {"j": 1, curses.KEY_DOWN: 1, "k": -1, curses.KEY_UP: -1,
                        curses.KEY_NPAGE: page, curses.KEY_PPAGE: -page}
            position = offset if expanded else selected
            position = max(0, position + movement.get(key, 0))
            if key in ("g", curses.KEY_HOME):
                position = 0
            elif key in ("G", curses.KEY_END):
                position = len(lines) if expanded and runs else len(runs) - 1
            if expanded:
                offset = position
            else:
                selected = position


def list_runs(arguments):
    parser = argparse.ArgumentParser(
        prog="network-audit list", description="Browse saved audit runs recursively without starting a device"
    )
    parser.add_argument("--path", type=Path, default=Path(".network-audit"),
                        help="Audit directory (default: ./.network-audit)")
    args = parser.parse_args(arguments)
    root = args.path.expanduser().resolve()
    runs, warnings = scan(root)
    if not sys.stdin.isatty() or not sys.stdout.isatty() or os.environ.get("TERM") in (None, "", "dumb"):
        plain(root, runs, warnings)
    else:
        try:
            curses.wrapper(browse, root, runs, warnings)
        except curses.error as error:
            raise RuntimeError(f"Cannot open terminal browser: {error}; pipe output for a plain listing") from error
    return 0
