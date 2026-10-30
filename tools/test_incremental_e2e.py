"""Real relay + two independently simulating games + a late observer."""
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


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--default-map", action="store_true")
    parser.add_argument("--host-team", type=int, choices=(0, 1))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    logs = Path(tempfile.mkdtemp(prefix="incremental-e2e-", dir=root / ".godot"))
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    env = dict(os.environ, AOE2_MP_HOST="127.0.0.1", AOE2_MP_PORT=str(port),
               AOE2_MP_LEADERBOARD_DB=str(logs / "leaderboard.sqlite3"))
    processes, handles = {}, []
    finish = logs / "finish.txt"

    def launch(label: str, command: list[str]) -> None:
        handle = (logs / f"{label}.txt").open("w", encoding="utf-8")
        handles.append(handle)
        processes[label] = subprocess.Popen(command, cwd=root, env=env, stdout=handle,
            stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)

    def peer(role: str) -> None:
        launch(role, [args.godot, "--headless", "--path", str(root), "--log-file", str(logs / f"{role}.log"),
                      "--script", "res://tests/run_incremental_peer.gd", "--",
                      f"ws://127.0.0.1:{port}/ws", role, str(logs / f"{role}.json"), str(finish), "default" if args.default_map else "fixture"])

    print(f"Logs: {logs}", flush=True)
    try:
        server_command = [sys.executable, "-m", "multiplayer_service_python.main"]
        if args.host_team is not None:
            # Test-only selection proves both random-host branches without
            # adding a host override to the production server.
            code = ("from unittest.mock import patch; import runpy,secrets; original=secrets.randbelow; "
                    f"p=patch('multiplayer_service_python.matchmaking.secrets.randbelow',side_effect=lambda n:{args.host_team} if n==2 else original(n)); "
                    "p.start(); runpy.run_module('multiplayer_service_python.main',run_name='__main__')")
            server_command = [sys.executable, "-c", code]
        launch("server", server_command)
        deadline = time.monotonic() + 15
        while True:
            try:
                with urlopen(f"http://127.0.0.1:{port}/healthz", timeout=1): break
            except Exception:
                if time.monotonic() > deadline: raise RuntimeError("relay did not start")
                time.sleep(.1)
        peer("player-a")
        peer("player-b")
        start = time.monotonic()
        while time.monotonic() - start < 60:
            for label, proc in processes.items():
                if proc.poll() is not None and label != "server":
                    time.sleep(.5)
                    raise RuntimeError("\n".join(f"{f.name}: {f.read_text(encoding='utf-8', errors='replace')[-7000:]}" for f in logs.glob("*.txt")))
            if "spectator" not in processes and time.monotonic() - start > 5:
                peer("spectator")
            if all((logs / f"{role}.json").exists() for role in ["player-a", "player-b", "spectator"]): break
            time.sleep(.15)
        else:
            raise RuntimeError("peers did not reach450 deterministic ticks")
        finish.write_text("finish", encoding="utf-8")
        for role in ["player-a", "player-b", "spectator"]:
            proc = processes[role]
            proc.wait(timeout=10)
            log = (logs / f"{role}.txt").read_text(encoding="utf-8", errors="replace")
            if proc.returncode or "INCREMENTAL E2E PASSED" not in log or "SCRIPT ERROR:" in log:
                raise RuntimeError(f"{role} failed:\n{log[-9000:]}")
        reports = [json.loads((logs / f"{role}.json").read_text()) for role in ["player-a", "player-b", "spectator"]]
        for report in reports:
            if report["role"] == "spectator":
                assert report["first_keyframe_tick"] > 0 and report["keyframes"] == 1 and report["desyncs"] == 0, report
            elif report["team"] != report["host_team"]:
                assert report["corrupted"] and report["desyncs"] == 1 and report["keyframes"] == 2, report
            if report["frames"]:
                assert report["frame_bytes"] / report["frames"] < 4096, report
                assert report["commands"] > 0, report
        assert len({(r["tick"], r["checksum"]) for r in reports}) == 1, reports
        print(json.dumps(reports, indent=2))
        print("INCREMENTAL E2E PASSED: equal final checksums, late join, forced resync, compact frames")
    finally:
        for proc in processes.values():
            if proc.poll() is None: proc.terminate()
        for proc in processes.values():
            try: proc.wait(timeout=5)
            except subprocess.TimeoutExpired: proc.kill()
        for handle in handles: handle.close()


if __name__ == "__main__":
    main()
