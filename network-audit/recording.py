"""A silent MP4 recording on the audit's owned API 36 emulator."""

import subprocess

from android import wait_for


class ScreenRecording:
    def __init__(self, emulator, session):
        self.emulator = emulator
        self.path = session / "recording.mp4"
        self.log = session / "recording.log"
        # The emulator is disposable and belongs exclusively to this audit.
        self.remote = "/data/local/tmp/network-audit-recording.mp4"
        self.pid_file = "/data/local/tmp/network-audit-recording.pid"
        self.process = None

    def start(self):
        with self.log.open("w") as log:
            self.process = subprocess.Popen(
                [
                    "adb", "-s", self.emulator.serial, "shell",
                    # exec preserves the device-side PID; signalling the host
                    # adb process alone does not reliably finalize an MP4.
                    f"echo $$ > {self.pid_file}; "
                    f"exec screenrecord --time-limit 0 {self.remote}",
                ],
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )

        def ready():
            self.check()
            # screenrecord probes the path with an empty file before starting
            # its encoder. Wait for the muxer to actually write, not just exist.
            size = self.emulator.adb(
                "shell", f"stat -c %s {self.remote} 2>/dev/null || echo 0", timeout=5
            )
            self.check()
            return int(size) > 0

        wait_for(ready, "screen recording; see recording.log", timeout=30)

    def check(self):
        if self.process is not None and self.process.poll() is not None:
            raise RuntimeError("Screen recording stopped unexpectedly; see recording.log")

    def stop(self):
        if self.process is None:
            return None
        unexpected = self.process.poll() is not None
        try:
            if not unexpected:
                self.emulator.adb(
                    "shell", f"kill -INT $(cat {self.pid_file})", timeout=10
                )
            status = self.process.wait(timeout=30)
            # Pull before emulator.close() destroys the only on-device copy.
            # A failed transfer must not masquerade as a completed MP4.
            partial = self.path.with_suffix(".mp4.partial")
            self.emulator.adb("pull", self.remote, str(partial), timeout=120)
            if not partial.is_file() or partial.stat().st_size == 0:
                raise RuntimeError("Screen recording is empty; see recording.log")
            partial.replace(self.path)
            if unexpected or status != 0:
                raise RuntimeError(
                    "Screen recording stopped unexpectedly; video may be partial; "
                    "see recording.log"
                )
            return self.path
        finally:
            # Bound cleanup even when ADB disconnects or the encoder hangs.
            # Emulator cleanup handles any remaining device-side process.
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
