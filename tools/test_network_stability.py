"""Run a sustained real relay and Godot peers with test-only timing wrappers."""
from __future__ import annotations
import argparse
import json
import math
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
from urllib.request import urlopen


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--duration", type=float, default=45.0, help="real seconds after both players start")
    parser.add_argument("--speed", type=float, default=2.0)
    parser.add_argument("--spectator", action="store_true")
    parser.add_argument("--extra-units", type=int, default=0, help="additional host militia for snapshot/load stress")
    parser.add_argument("--baseline", action="store_true", help="use locally saved pre-fix network scripts in .godot")
    args = parser.parse_args()
    if not math.isfinite(args.duration) or args.duration <= 0:
        parser.error("--duration must be positive and finite")
    if not math.isfinite(args.speed) or not 0.1 <= args.speed <= 8:
        parser.error("--speed must be between 0.1 and 8")
    if not 0 <= args.extra_units <= 500:
        parser.error("--extra-units must be between 0 and 500")
    root = Path(__file__).resolve().parents[1]
    log_root = root / ".godot"
    log_root.mkdir(exist_ok=True)
    logs = Path(tempfile.mkdtemp(prefix="network-stability-", dir=log_root))
    probe_dir = ""
    if args.baseline:
        originals = {"session": "network-session-before-lag-fix.gd", "runtime": "network_match_before_lag_fix.gd"}
        for kind, saved in originals.items():
            baseline = log_root / saved
            if not baseline.is_file(): parser.error(f"--baseline needs the local diagnostic snapshot: {baseline}")
            source = (root / "tests" / f"network_stability_{kind}.gd").read_text(encoding="utf-8")
            lines = source.splitlines(keepends=True)
            lines[0] = f'extends "res://.godot/{saved}"\n'
            (logs / f"{kind}_probe.gd").write_text("".join(lines), encoding="utf-8")
        probe_dir = "res://" + logs.relative_to(root).as_posix()
    finish = logs / "finish.txt"
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    endpoint = f"ws://127.0.0.1:{port}/ws"
    env = dict(os.environ, AOE2_MP_HOST="127.0.0.1", AOE2_MP_PORT=str(port),
               AOE2_MP_LEADERBOARD_DB=str(logs / "leaderboard.sqlite3"))
    handles = []
    processes = []
    flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0

    def launch(command, label):
        output = (logs / (label + ".txt")).open("w", encoding="utf-8")
        handles.append(output)
        child = subprocess.Popen(command, cwd=root, env=env, stdout=output,
                                 stderr=subprocess.STDOUT, creationflags=flags)
        processes.append((label, child))
        return child

    def godot(role, label):
        return launch([args.godot, "--headless", "--path", str(root), "--log-file",
                       str(logs / (label + ".log")), "--script", "res://tests/run_network_stability.gd",
                       "--", endpoint, role, label, str(finish), str(logs / (label + ".json")),
                       str(args.speed), str(args.extra_units), probe_dir], label)

    def rooms():
        with urlopen(f"http://127.0.0.1:{port}/api/matches", timeout=1) as response:
            return json.load(response)["matches"]

    try:
        server = launch([sys.executable, "-m", "multiplayer_service_python.main"], "server")
        deadline = time.monotonic() + 15
        while True:
            if server.poll() is not None: raise RuntimeError("relay exited during startup")
            try:
                with urlopen(f"http://127.0.0.1:{port}/healthz", timeout=.5): break
            except OSError:
                if time.monotonic() > deadline: raise RuntimeError("relay startup timeout")
                time.sleep(.1)
        players = [godot("player", "Player-" + str(side)) for side in range(2)]
        deadline = time.monotonic() + 30
        while not rooms():
            if any(peer.poll() is not None for peer in players): raise RuntimeError("peer exited before match started")
            if time.monotonic() > deadline: raise RuntimeError("match startup timeout")
            time.sleep(.1)
        active = list(players)
        if args.spectator: active.append(godot("watch", "Observer"))
        start = time.monotonic()
        while time.monotonic() - start < args.duration:
            if any(peer.poll() is not None for peer in active): raise RuntimeError("peer ended before requested wall duration")
            time.sleep(.2)
        finish.write_text("finish\n", encoding="utf-8")
        deadline = time.monotonic() + 15
        while any(peer.poll() is None for peer in active) and time.monotonic() < deadline: time.sleep(.1)
        for peer in active:
            if peer.poll() != 0: raise RuntimeError(f"peer exit was {peer.poll()}")
        reports = {p.stem: json.loads(p.read_text(encoding="utf-8")) for p in logs.glob("*.json")}
        expected = {"Player-0", "Player-1"} | ({"Observer"} if args.spectator else set())
        if set(reports) != expected:
            raise RuntimeError("a peer did not produce its timing report")
        for label, report in reports.items():
            output = (logs / (label + ".txt")).read_text(encoding="utf-8", errors="replace")
            errors = [line for line in output.splitlines()
                      if line.startswith("SCRIPT ERROR:") or (line.startswith("ERROR:") and "resources still in use at exit" not in line)]
            if errors: raise RuntimeError(f"{label} emitted engine/script errors: {errors[:3]}")
            if report.get("transport_failure") or report.get("server_error_code"):
                raise RuntimeError(f"{label} reported a transport failure")
        host = reports["Player-0"] if reports["Player-0"]["captures"] else reports["Player-1"]
        if not args.baseline and host["snapshot_hz"] > 10.5:
            raise RuntimeError("snapshot frequency grew beyond the real-time budget")
        print(json.dumps(reports, ensure_ascii=False, indent=2))
        print(f"NETWORK STABILITY PASSED ({args.duration}s speed {args.speed}); logs: {logs}")
        return 0
    except (OSError, RuntimeError) as error:
        print(f"NETWORK STABILITY FAILED: {error}; logs: {logs}", file=sys.stderr)
        for report in logs.glob("*.json"):
            print(report.name, report.read_text(encoding="utf-8"))
        for label, child in processes:
            if label != "server" and child.poll() is not None:
                output = (logs / (label + ".txt")).read_text(encoding="utf-8", errors="replace")
                print(label, output[-8000:])
        return 1
    finally:
        for _, child in reversed(processes):
            if child.poll() is None:
                child.terminate()
                try: child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
        for handle in handles: handle.close()


if __name__ == "__main__":
    raise SystemExit(main())
