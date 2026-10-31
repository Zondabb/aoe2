"""Lockstep performance probe: real relay + two simulating game processes.

Both players load the seeded default map with an extra army per side, march
the armies into each other and send villagers to wood, then sample a fixed
wall-clock window. Reports simulated speed (1.0 = real time), render-frame
hitches and desyncs for each process. Target speed is the host's [game] speed.

    python tools/bench_lockstep_e2e.py --godot "<Godot console executable>" [--army 40] [--seconds 20]
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import tempfile
import time
from urllib.request import urlopen


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--army", type=int, default=40, help="extra soldiers per side")
    parser.add_argument("--seconds", type=float, default=20.0, help="sampling window")
    parser.add_argument("--server-cmd", default="", help="override relay command (default: the Python service)")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    logs = Path(tempfile.mkdtemp(prefix="lockstep-perf-", dir=root / ".godot"))
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    env = dict(os.environ, AOE2_MP_HOST="127.0.0.1", AOE2_MP_PORT=str(port),
               AOE2_MP_LEADERBOARD_DB=str(logs / "leaderboard.sqlite3"))
    processes, handles = {}, []

    def launch(label: str, command: list[str]) -> None:
        handle = (logs / f"{label}.txt").open("w", encoding="utf-8")
        handles.append(handle)
        processes[label] = subprocess.Popen(command, cwd=root, env=env, stdout=handle, stderr=subprocess.STDOUT,
                                            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)

    print(f"Logs: {logs}", flush=True)
    try:
        server = shlex.split(args.server_cmd) if args.server_cmd else [sys.executable, "-m", "multiplayer_service_python.main"]
        launch("server", server)
        deadline = time.monotonic() + 15
        while True:
            try:
                with urlopen(f"http://127.0.0.1:{port}/healthz", timeout=1): break
            except Exception:
                if time.monotonic() > deadline: raise RuntimeError("relay did not start")
                time.sleep(.1)
        for role in ["player-a", "player-b"]:
            launch(role, [args.godot, "--headless", "--path", str(root), "--script", "res://tests/run_lockstep_perf_peer.gd", "--",
                          f"ws://127.0.0.1:{port}/ws", role, str(logs / f"{role}.json"), str(args.army), str(int(args.seconds * 1000))])
        limit = time.monotonic() + args.seconds + 120
        while not all((logs / f"{role}.json").exists() for role in ["player-a", "player-b"]):
            for label, proc in processes.items():
                if label != "server" and proc.poll() is not None and not (logs / f"{label}.json").exists():
                    raise RuntimeError((logs / f"{label}.txt").read_text(encoding="utf-8", errors="replace")[-6000:])
            if time.monotonic() > limit: raise RuntimeError("perf peers did not report")
            time.sleep(.2)
        time.sleep(.3)
        reports = [json.loads((logs / f"{role}.json").read_text()) for role in ["player-a", "player-b"]]
        print(json.dumps(reports, indent=2, ensure_ascii=False))
        for report in reports:
            print("{:5} speed {:.2f}x (target {:.2f}x)  frame p50 {:.1f} ms  p99 {:.1f} ms  max {:.1f} ms  >50ms {}  >100ms {}  idle ticks {:.0%}  desyncs {}".format(
                "host" if report["host"] else "guest", report["sim_speed"], report["match_speed"], report["frame_ms_p50"], report["frame_ms_p99"],
                report["frame_ms_max"], report["frames_over_50ms"], report["frames_over_100ms"], report["idle_tick_ratio"], report["desyncs"]))
    finally:
        for proc in processes.values():
            if proc.poll() is None: proc.terminate()
        for proc in processes.values():
            try: proc.wait(timeout=5)
            except subprocess.TimeoutExpired: proc.kill()
        for handle in handles: handle.close()


if __name__ == "__main__":
    main()
