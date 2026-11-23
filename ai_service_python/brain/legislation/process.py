"""Process lifetime and JSON transport; no pickle crosses the boundary."""
from __future__ import annotations

import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import uuid

from .worker import MAX_MESSAGE


class WorkerError(RuntimeError):
    pass


class WorkerClient:
    def __init__(self, source: Path, profile: str, *, mode="docker", image="", timeout=5.0):
        self.timeout, self.checkpoint = timeout, None
        self._lock = threading.Lock()
        self._lines = queue.Queue(maxsize=2)
        self.container = None
        entry = "import sys,runpy;sys.path.insert(0,sys.argv[1]);runpy.run_module('brain.legislation.worker',run_name='__main__')"
        if mode == "docker":
            if not image or "@sha256:" not in image:
                raise WorkerError("worker_image_requires_pinned_digest")
            self.container = "aoe2-cabinet-" + uuid.uuid4().hex
            command = ["docker", "run", "--rm", "-i", "--name", self.container,
                       "--network=none", "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges",
                       "--pids-limit=64", "--memory=512m", "--cpus=1", "--user=65534:65534",
                       "--tmpfs=/tmp:rw,noexec,nosuid,size=32m", "--mount",
                       f"type=bind,source={source.resolve()},target=/service,readonly",
                       "--workdir=/service", image, "python", "-I", "-B", "-u", "-c", entry, "/service"]
        elif mode == "local-development":
            command = [sys.executable, "-I", "-B", "-u", "-c", entry, str(source.resolve())]
        else:
            raise WorkerError("unknown_worker_mode")
        # Explicit allowlist: no provider secrets, config paths or proxy settings.
        env = {key: value for key, value in os.environ.items()
               if key.upper() in {"SYSTEMROOT", "WINDIR", "PATH", "TEMP", "TMP"}}
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, env=env,
                                        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        threading.Thread(target=self._read, daemon=True).start()
        try:
            result = self.call("init", profile)
            expected = Path("/service") if mode == "docker" else source.resolve()
            for name, path in result["modules"].items():
                if Path(path) != expected / "brain" / "cabinet" / "departments" / (name + ".py"):
                    raise WorkerError("incorrect_loaded_module")
        except BaseException:
            self.close()
            raise

    def _read(self):
        while True:
            raw = self.process.stdout.readline(MAX_MESSAGE + 1)
            try:
                self._lines.put_nowait(raw)
            except queue.Full:
                self.process.kill()
                return
            if not raw or len(raw) > MAX_MESSAGE:
                return

    def call(self, method, *args):
        with self._lock:
            raw = json.dumps({"method": method, "args": args}, allow_nan=False, separators=(",", ":")).encode() + b"\n"
            if len(raw) > MAX_MESSAGE:
                raise WorkerError("worker_request_too_large")
            # A worker that stops consuming stdin must not block the caller.
            def write():
                try:
                    self.process.stdin.write(raw)
                    self.process.stdin.flush()
                except (OSError, ValueError):
                    pass
            writer = threading.Thread(target=write, daemon=True)
            writer.start()
            try:
                response = self._lines.get(timeout=self.timeout)
                if not response or len(response) > MAX_MESSAGE:
                    raise WorkerError("worker_closed_or_oversized")
                decoded = json.loads(response)
                if decoded.get("ok") is not True:
                    raise WorkerError(decoded.get("error", "worker_failed"))
                self.checkpoint = decoded["checkpoint"]
                return decoded["result"]
            except (queue.Empty, ValueError, KeyError) as exc:
                self.close()
                raise WorkerError("worker_timeout_or_invalid_response") from exc

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=5)
        if self.container:
            subprocess.run(["docker", "rm", "-f", self.container], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=10,
                           creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
