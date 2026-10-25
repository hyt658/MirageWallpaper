#
#  Mirage Wallpaper
#
#  Copyright © 2026 王孝慈. All rights reserved.
#

"""Exercise real shared AVFoundation playback using temporary video fixtures.

Multiple endpoints can target one attached display, so this also runs on a
single-display Mac. Physical multi-display/HDR verification remains separate.
"""

import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time


class Host:
    def __init__(self, executable, directory):
        self.log = (directory / "renderer.log").open("w")
        self.process = subprocess.Popen(
            [executable, str(directory), "--shared-host", "--control-stdin"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
            text=True, bufsize=1)
        self.events = queue.Queue()
        self.errors = []
        self.history = []
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in self.process.stdout:
            self.events.put(json.loads(line))

    def send(self, endpoint, command, **values):
        self.process.stdin.write(json.dumps(dict(cmd=command, endpoint=endpoint, **values)) + "\n")
        self.process.stdin.flush()

    def wait(self, event, endpoint, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                message = self.events.get(timeout=min(0.2, deadline - time.monotonic()))
            except queue.Empty:
                assert self.process.poll() is None, "shared host exited unexpectedly"
                continue
            self.history.append(message)
            assert message["event"] != "video-error", message
            if message["event"] == event and message.get("endpoint") == endpoint:
                return message
        raise AssertionError(f"timeout waiting for {event}/{endpoint}: {self.history[-8:]}")

    def status(self, endpoint):
        self.send(endpoint, "shared-status")
        return self.wait("shared-status", endpoint)

    def settled(self, endpoint, sessions, paused=None):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            message = self.status(endpoint)
            if message["sessions"] == sessions and message["ready"] and not message["pending"] and (
                    paused is None or message["paused"] == paused):
                return message
            time.sleep(0.05)
        raise AssertionError(f"playback did not settle: {message}")

    def assert_synchronized(self, leader, follower):
        # Bracket the follower's sample so IPC latency and a loop boundary do
        # not look like drift. The temporary video lasts exactly two seconds.
        before = self.status(leader)["time"]
        joined = self.status(follower)["time"]
        after = self.status(leader)["time"]
        advanced = (after - before) % 2
        offset = (joined - before) % 2
        tolerance = 1 / 30
        assert offset <= advanced + tolerance or offset >= 2 - tolerance, (
            f"{follower} is out of sync with {leader}: {before}, {joined}, {after}")

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
                raise
        self.log.close()
        assert self.process.returncode == 0, self.process.returncode


def test(executable, ffmpeg, display, directory, memory):
    directory.mkdir()
    subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                    "testsrc2=size=1280x720:rate=30", "-t", "2", "-c:v", "libx264",
                    "-pix_fmt", "yuv420p", str(directory / "video.mp4")], check=True)
    (directory / "project.json").write_text(json.dumps(
        dict(type="video", file="video.mp4", title="Shared playback regression")))
    host = Host(executable, directory)
    try:
        def attach(token, **options):
            host.send(token, "attach", display=display, directory=str(directory), speed=1,
                      paused=options.get("paused", False), volume=0, muted=options.get("muted", True), memory=memory, hdr=False,
                      fill=options.get("fill", "cover"), x=options.get("x", 0.5), y=0.5)
            host.wait("prepared", token)
            # Preparing another screen must not pause existing visible screens.
            host.send(token, "activate")
            host.wait("activated", token)

        attach("first")
        attach("second", fill="contain", x=0)
        first = host.settled("first", 1, False)
        assert first["endpoints"] == 2
        host.wait("video-did-end", "first", timeout=5)
        assert host.status("second")["ready"], "both layers survive looping"
        host.assert_synchronized("first", "second")

        # A hidden candidate must not mute a visible member of the same group.
        for token in ("first", "second"):
            host.send(token, "muted", value=False)
        assert not host.settled("first", 1)["muted"]
        host.send("candidate", "attach", display=display, directory=str(directory), speed=1,
                  paused=False, volume=0, muted=False, memory=memory, hdr=False,
                  fill="cover", x=0.5, y=0.5)
        host.wait("prepared", "candidate")
        assert not host.status("first")["muted"], "hidden candidate changed existing audio"
        host.send("candidate", "detach")
        host.wait("detached", "candidate")
        for token in ("first", "second"):
            host.send(token, "muted", value=True)
        assert host.settled("first", 1)["muted"]

        # Joining an already paused group still prepares its own display layer.
        for token in ("first", "second"):
            host.send(token, "power", state="pause")
        paused = host.settled("first", 1, True)
        attach("paused-join", paused=True)
        joined = host.settled("paused-join", 1, True)
        assert abs(joined["time"] - paused["time"]) < 0.01, "paused late join lost the shared progress"
        assert abs(host.status("first")["time"] - paused["time"]) < 0.01, "late join moved the paused group"
        host.send("paused-join", "detach")
        host.wait("detached", "paused-join")
        for token in ("first", "second"):
            host.send(token, "power", state="run")
        host.settled("first", 1, False)

        host.send("first", "power", state="pause")
        frozen = host.settled("first", 2, True)
        time.sleep(0.2)
        assert abs(host.status("first")["time"] - frozen["time"]) < 0.01
        host.settled("second", 2, False)
        host.send("first", "snapshot", path=str(directory / "paused.heic"), token="paused")
        assert host.wait("snapshot-done", "first")["ok"], "paused display snapshot"
        assert (directory / "paused.heic").stat().st_size > 0

        host.send("first", "power", state="run")
        host.settled("first", 1, False)
        host.assert_synchronized("second", "first")
        host.send("first", "speed", value=0.5)
        host.settled("first", 2, False)
        host.send("first", "speed", value=1)
        host.settled("first", 1, False)
        host.send("first", "muted", value=False)
        host.settled("first", 2)
        host.send("first", "muted", value=True)
        host.settled("first", 1)
        host.send("first", "volume", value=0.25)
        host.settled("first", 2)
        host.send("first", "volume", value=0)
        host.settled("first", 1)
        host.send("first", "hdr", value=True)
        host.send("first", "position", x=1, y=0)
        host.send("first", "fillmode", value="stretch")
        host.settled("first", 1)

        host.send("first", "deactivate")
        host.wait("deactivated", "first")
        host.settled("second", 1, False)
        host.send("first", "activate")
        host.wait("activated", "first")
        host.send("first", "detach")
        host.wait("detached", "first")
        assert host.status("second")["endpoints"] == 1
        host.settled("second", 1, False)
        deadline = time.monotonic() + 5
        while True:
            before_join = host.status("second")["time"]
            if 0.5 <= before_join <= 1:
                break
            assert time.monotonic() < deadline, "existing display stopped advancing"
            time.sleep(0.02)
        started = time.monotonic()
        attach("late")
        assert host.settled("late", 1)["endpoints"] == 2
        after_join = host.status("second")["time"]
        elapsed = time.monotonic() - started
        drift = (after_join - before_join - elapsed + 1) % 2 - 1
        assert abs(drift) < 0.15, "late join reset or interrupted the existing display"
        host.assert_synchronized("second", "late")
        host.send("second", "detach")
        host.wait("detached", "second")
        host.send("late", "detach")
        host.wait("detached", "late")
        # The process remains a reusable transport until the parent sends EOF.
        attach("replacement")
        assert host.settled("replacement", 1)["endpoints"] == 1
        host.send("replacement", "detach")
        host.wait("detached", "replacement")
        print(f"PASS: synchronized progress, independent controls, snapshots, detach, late join continuity; memory={memory}", flush=True)
    finally:
        host.close()


def main():
    executable, ffmpeg = map(os.path.abspath, sys.argv[1:3])
    display = int(subprocess.check_output(
        ["swift", "-e", "import CoreGraphics; print(CGMainDisplayID())"], text=True).strip())
    with tempfile.TemporaryDirectory(prefix="mirage-shared-video-") as temporary:
        root = Path(temporary)
        for memory in (False, True):
            test(executable, ffmpeg, display, root / str(memory), memory)


if __name__ == "__main__":
    main()
