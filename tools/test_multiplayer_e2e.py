"""Launch the real Python relay and two headless Godot clients; no public service needed."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
from urllib.request import urlopen
from urllib.parse import urlsplit, urlunsplit


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True, help="Path to Godot 4 executable (console variant on Windows)")
    parser.add_argument("--server-url", help="Existing relay WebSocket URL; omit to launch a temporary Python service")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    log_root = root / ".godot"
    log_root.mkdir(exist_ok=True)
    logs = Path(tempfile.mkdtemp(prefix="multiplayer-e2e-", dir=log_root))
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    env = dict(os.environ, AOE2_MP_HOST="127.0.0.1", AOE2_MP_PORT=str(port),
               AOE2_MP_LEADERBOARD_DB=str(logs / "leaderboard.sqlite3"))
    processes: list[subprocess.Popen] = []
    handles = []
    flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0

    def launch(command: list[str], label: str) -> subprocess.Popen:
        output = (logs / f"{label}.txt").open("w", encoding="utf-8")
        handles.append(output)
        process = subprocess.Popen(command, cwd=root, env=env, stdout=output,
                                   stderr=subprocess.STDOUT, creationflags=flags)
        processes.append(process)
        return process

    try:
        server = None
        endpoint = args.server_url or f"ws://127.0.0.1:{port}/ws"
        parsed = urlsplit(endpoint)
        if parsed.scheme not in ("ws", "wss") or not parsed.hostname:
            raise RuntimeError("--server-url must be a ws:// or wss:// endpoint")
        health_url = urlunsplit(("https" if parsed.scheme == "wss" else "http", parsed.netloc, "/healthz", "", ""))
        if not args.server_url:
            server = launch([sys.executable, "-m", "multiplayer_service_python.main"], "server")
        deadline = time.monotonic() + 15
        while True:
            if server is not None and server.poll() is not None:
                raise RuntimeError("Python relay failed to start")
            try:
                with urlopen(health_url, timeout=0.5) as response:
                    if response.status == 200:
                        break
            except OSError:
                pass
            if time.monotonic() > deadline:
                raise RuntimeError("Python relay startup timed out")
            time.sleep(0.1)
        clients = []
        for side in range(2):
            clients.append(launch([
                args.godot, "--headless", "--path", str(root),
                "--log-file", (logs / f"godot-{side}.log").as_posix(),
                "--script", "res://tests/run_multiplayer_peer.gd", "--",
                endpoint, f"Integration-{side}",
            ], f"peer-{side}"))
        deadline = time.monotonic() + 55
        while any(client.poll() is None for client in clients):
            if time.monotonic() > deadline:
                raise RuntimeError("Godot multiplayer clients timed out")
            time.sleep(0.1)
        for side, client in enumerate(clients):
            output = (logs / f"peer-{side}.txt").read_text(encoding="utf-8", errors="replace")
            if client.returncode != 0 or "MULTIPLAYER PEER PASSED" not in output or "SCRIPT ERROR:" in output or "PEER FAILED" in output:
                print(output[-14000:])
                raise RuntimeError(f"Godot peer {side} failed ({client.returncode})")
            print(next(line for line in output.splitlines() if "MULTIPLAYER PEER PASSED" in line))
        if not args.server_url:
            base = urlunsplit(("http", parsed.netloc, "", "", ""))
            with urlopen(base + "/api/leaderboard", timeout=3) as response:
                board = json.load(response)
            rows = board["players"]
            if (board["completed_matches"] != 1 or {row["name"] for row in rows} != {"Integration-0", "Integration-1"}
                    or sorted((row["wins"], row["games"], row["win_rate"]) for row in rows) != [(0, 1, 0), (1, 1, 100)]):
                raise RuntimeError(f"Leaderboard did not record the real game exactly once: {board}")
            with urlopen(base + "/", timeout=3) as response:
                if "联机排行榜" not in response.read().decode("utf-8"):
                    raise RuntimeError("Leaderboard web page unavailable")
            print("LEADERBOARD E2E PASSED: both real players have 1 game, exactly one winner")
        print(f"MULTIPLAYER E2E PASSED; logs: {logs}")
        return 0
    except (OSError, RuntimeError) as error:
        print(f"MULTIPLAYER E2E FAILED: {error}; logs: {logs}", file=sys.stderr)
        return 1
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        for handle in handles:
            handle.close()


if __name__ == "__main__":
    raise SystemExit(main())
