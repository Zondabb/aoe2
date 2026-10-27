"""Exercise the real relay, two Godot players and late-joining Godot spectators.

Only a temporary loopback service is used. No AI/model or public service calls.
"""
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

from websockets.sync.client import connect


def receive_type(peer, kind: str, timeout: float = 4.0) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        packet = json.loads(peer.recv(timeout=max(0.05, deadline - time.monotonic())))
        if packet.get("type") == kind:
            return packet
        if packet.get("type") == "match_ended":
            raise RuntimeError("The player match ended before spectator checks finished")
    raise RuntimeError(f"No {kind} response from relay")


def live_matches(url: str) -> list[dict]:
    with connect(url, open_timeout=2, max_size=1024 * 1024) as peer:
        peer.send(json.dumps({"type": "list_matches"}))
        return receive_type(peer, "matches")["matches"]


def check_server_permissions(url: str, match_id: str) -> None:
    """Bypass the game's own guards to prove the relay rejects spectator writes."""
    with connect(url, open_timeout=2, max_size=1024 * 1024) as peer:
        peer.send(json.dumps({"type": "watch_match", "match_id": match_id}))
        joined = receive_type(peer, "spectate_started")
        if joined.get("role") != "spectator":
            raise RuntimeError("Relay did not assign a spectator role")
        initial = receive_type(peer, "snapshot")
        if not initial.get("state", {}).get("entities"):
            raise RuntimeError("Late spectator did not receive the cached full snapshot")
        peer.send(json.dumps({"type": "watch_ready"}))
        resumed = receive_type(peer, "snapshot")
        if resumed["seq"] < initial["seq"]:
            raise RuntimeError("Ready spectator resumed from an older snapshot")
        attacks = [
            {"type": "ready"},
            {"type": "command", "seq": 1, "command": {"op": "stop", "unit_id": 1}},
            {"type": "snapshot", "seq": 1, "state": {"entities": []}},
            {"type": "finish_match", "winner": 0},
            {"type": "join_queue", "protocol_version": 1, "name": "Observer-attack", "civ": "chinese"},
        ]
        for attack in attacks:
            peer.send(json.dumps(attack))
            error = receive_type(peer, "error")
            if error.get("code") != "forbidden":
                raise RuntimeError(f"Spectator {attack['type']} was not explicitly forbidden: {error}")
        # A spectator leave must release only that observer's membership.
        peer.send(json.dumps({"type": "leave"}))
        peer.send(json.dumps({"type": "list_matches"}))
        if match_id not in {room["match_id"] for room in receive_type(peer, "matches")["matches"]}:
            raise RuntimeError("Malicious spectator leave ended the players' match")
    print("SPECTATOR RELAY PERMISSIONS PASSED: all five write paths rejected")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True, help="Godot 4 console executable")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    log_root = root / ".godot"
    log_root.mkdir(exist_ok=True)
    logs = Path(tempfile.mkdtemp(prefix="spectator-e2e-", dir=log_root))
    finish_file = logs / "finish-match.txt"
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    endpoint = f"ws://127.0.0.1:{port}/ws"
    env = dict(os.environ, AOE2_MP_HOST="127.0.0.1", AOE2_MP_PORT=str(port),
               AOE2_MP_LEADERBOARD_DB=str(logs / "leaderboard.sqlite3"))
    processes = []
    handles = []
    flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0

    def launch(command: list[str], label: str):
        output = (logs / f"{label}.txt").open("w", encoding="utf-8")
        handles.append(output)
        process = subprocess.Popen(command, cwd=root, env=env, stdout=output,
                                   stderr=subprocess.STDOUT, creationflags=flags)
        processes.append(process)
        return process

    def godot(role: str, label: str):
        return launch([args.godot, "--headless", "--path", str(root),
                       "--log-file", (logs / f"{label}.log").as_posix(),
                       "--script", "res://tests/run_spectator_peer.gd", "--",
                       endpoint, role, label, str(finish_file), str(logs / f"{label}-ready.txt")], label)

    def wait_finished(process, label: str, timeout: float = 25.0):
        deadline = time.monotonic() + timeout
        while process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.1)
        if process.poll() is None:
            raise RuntimeError(f"Godot {label} timed out")
        output = (logs / f"{label}.txt").read_text(encoding="utf-8", errors="replace")
        engine_errors = [line for line in output.splitlines()
                         if line.startswith("ERROR:") and "resources still in use at exit" not in line]
        if process.returncode or "SPECTATOR E2E PEER PASSED" not in output or "SCRIPT ERROR:" in output or "PEER FAILED" in output or engine_errors:
            raise RuntimeError(f"Godot {label} failed ({process.returncode}):\n{output[-14000:]}")
        print(next(line for line in output.splitlines() if "SPECTATOR E2E PEER PASSED" in line))

    try:
        server = launch([sys.executable, "-m", "multiplayer_service_python.main"], "server")
        deadline = time.monotonic() + 15
        while True:
            if server.poll() is not None:
                raise RuntimeError("Python relay failed to start")
            try:
                with urlopen(f"http://127.0.0.1:{port}/healthz", timeout=0.5) as response:
                    if response.status == 200:
                        break
            except OSError:
                pass
            if time.monotonic() >= deadline:
                raise RuntimeError("Relay startup timed out")
            time.sleep(0.1)
        players = [godot("player", f"SpectatorPlayer-{side}") for side in range(2)]
        deadline = time.monotonic() + 20
        matches = []
        while not matches:
            if any(player.poll() is not None for player in players):
                raise RuntimeError("A player exited before the live match was discoverable")
            matches = live_matches(endpoint)
            if time.monotonic() >= deadline:
                raise RuntimeError("Running match never appeared in the live list")
            time.sleep(0.1)
        room = matches[0]
        if {player["name"] for player in room["players"]} != {"SpectatorPlayer-0", "SpectatorPlayer-1"}:
            raise RuntimeError(f"Live list roster is wrong: {room}")
        check_server_permissions(endpoint, room["match_id"])
        first = godot("watch-leave", "Observer-leave")
        wait_finished(first, "Observer-leave")
        if any(player.poll() is not None for player in players):
            raise RuntimeError("A spectator leaving disrupted a player")
        if room["match_id"] not in {match["match_id"] for match in live_matches(endpoint)}:
            raise RuntimeError("Spectator leaving removed the running match")
        second = godot("watch-end", "Observer-end")
        ready = logs / "Observer-end-ready.txt"
        deadline = time.monotonic() + 20
        while not ready.exists():
            if second.poll() is not None:
                wait_finished(second, "Observer-end")
                raise RuntimeError("Spectator exited before the match finish check")
            if time.monotonic() >= deadline:
                raise RuntimeError("Second spectator never completed its read-only/view checks")
            time.sleep(0.1)
        finish_file.write_text("finish\n", encoding="utf-8")
        wait_finished(second, "Observer-end")
        for side, player in enumerate(players):
            wait_finished(player, f"SpectatorPlayer-{side}")
        if live_matches(endpoint):
            raise RuntimeError("Finished match remained in the watch list")
        with urlopen(f"http://127.0.0.1:{port}/api/leaderboard", timeout=3) as response:
            board = json.load(response)
        if board["completed_matches"] != 1 or {row["name"] for row in board["players"]} != {"SpectatorPlayer-0", "SpectatorPlayer-1"}:
            raise RuntimeError(f"Spectators changed the player standings: {board}")
        print(f"SPECTATOR E2E PASSED; logs: {logs}")
        return 0
    except (OSError, RuntimeError, TimeoutError) as error:
        print(f"SPECTATOR E2E FAILED: {error}; logs: {logs}", file=sys.stderr)
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
