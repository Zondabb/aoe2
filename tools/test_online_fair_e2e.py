"""Real fair-lockstep peers: fixed 100ms input delay and authoritative movement.

Each player's TCP proxy adds --delay-ms and 0..--jitter-ms per direction. The
peer-to-peer round trip therefore crosses four delayed legs. Use both zero
to measure local/LAN scheduling overhead, with --max-input-ms 200 to enforce
the steady-state movement latency target. Run once with each --host-team.
"""
from __future__ import annotations
import argparse
import math
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
    parser.add_argument("--traffic-report", action="store_true",
                        help="record relay JSON bytes by message type, separately from keyframe bursts")
    parser.add_argument("--delay-ms", type=float, default=25)
    parser.add_argument("--jitter-ms", type=float, default=10)
    parser.add_argument("--max-input-ms", type=float, default=0,
                        help="optional ceiling for the isolated move's actual input-to-motion delay")
    parser.add_argument("--max-final-window-ms", type=float, default=0,
                        help="optional ceiling for the final shared input window, including on the default map")
    parser.add_argument("--max-retreat-px", type=float, default=1.0,
                        help="maximum accepted straight-move visual retreat after confirmation")
    parser.add_argument("--min-speed-ratio", type=float, default=0.9,
                        help="minimum steady simulation throughput / configured speed")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    logs = Path(tempfile.mkdtemp(prefix="online-fair-e2e-", dir=root / ".godot"))
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    proxy_ports = {}
    for role in ["player-a", "player-b"]:
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            proxy_ports[role] = sock.getsockname()[1]
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
                      "--script", "res://tests/run_online_fair_peer.gd", "--",
                      f"ws://127.0.0.1:{proxy_ports.get(role, port)}/ws", role, str(logs / f"{role}.json"), str(finish), "default" if args.default_map else "fixture"])

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
        if args.traffic_report:
            server_command = [sys.executable, "-m", "tools.trace_multiplayer_traffic", "serve",
                              str(logs / "traffic.jsonl")]
            if args.host_team is not None:
                server_command += ["--host-team", str(args.host_team)]
        launch("server", server_command)
        deadline = time.monotonic() + 15
        while True:
            try:
                with urlopen(f"http://127.0.0.1:{port}/healthz", timeout=1): break
            except Exception:
                if time.monotonic() > deadline: raise RuntimeError("relay did not start")
                time.sleep(.1)
        for role, proxy_port in proxy_ports.items():
            launch("proxy-" + role, [sys.executable, "tools/network_latency_proxy.py", "--listen-port", str(proxy_port), "--upstream-port", str(port), "--delay-ms", str(args.delay_ms), "--jitter-ms", str(args.jitter_ms)])
        time.sleep(0.5)
        peer("player-a")
        peer("player-b")
        start = time.monotonic()
        while time.monotonic() - start < 60:
            for label, proc in processes.items():
                if proc.poll() is not None and label != "server" and not label.startswith("proxy-"):
                    time.sleep(.5)
                    raise RuntimeError("\n".join(f"{f.name}: {f.read_text(encoding='utf-8', errors='replace')[-7000:]}" for f in logs.glob("*.txt")))
            # A cold map load can exceed five seconds. Join after the host has
            # actually simulated a second so the observer exercises late entry.
            if "spectator" not in processes and (logs / "finish.txt.watch-ready").exists():
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
        if args.traffic_report:
            from trace_multiplayer_traffic import summarize
            traffic = summarize(logs / "traffic.jsonl")
            (logs / "traffic-summary.json").write_text(json.dumps(traffic, indent=2), encoding="utf-8")
            assert any(r["type"] == "input_step" for r in traffic["steady"]), traffic
            assert not any(r["type"] in ("input_frame", "input_commit", "input_ack") for r in traffic["steady"]), traffic
            assert not any(traffic["steady_duplicate_preparations"].values()), traffic
            assert traffic["steady_timing_updates"] == 0, traffic
            assert traffic["guest_repeated_game_commands"] == 0, traffic
            assert all(r["codec"] == "zlib" and r["bytes"] < r["raw_size"] for r in traffic["keyframes"]), traffic
            if not args.default_map:
                assert traffic["batches"] and all(r["commands"] >= 2 for r in traffic["batches"]), traffic
            print(f"TRAFFIC REPORT: {logs / 'traffic-summary.json'}")
        players = [r for r in reports if r["team"] in (0, 1)]
        for report in players:
            if args.max_final_window_ms:
                assert report["input_delay_ticks"] * 1000 / (30 * report["match_speed"]) <= args.max_final_window_ms, (
                    "loading/recovery inflated the final input window", report["role"], report["input_delay_ticks"])
            assert report["submission_invariants"] >= 8, report
            assert report["early_motion_frames"] == 0, report
            expected_delay = max(3, math.ceil(report["match_speed"] - 1e-9) * 3)
            assert report["input_delay_ticks"] == expected_delay, report
            steady = [(tick, ms) for tick, ms in report["timeline"] if 300 <= tick <= 435]
            assert len(steady) >= 30, report
            elapsed = (steady[-1][1] - steady[0][1]) / 1000
            rate = (steady[-1][0] - steady[0][0]) / elapsed
            report["steady_ticks_per_second"] = rate
            report["speed_ratio"] = rate / (30 * report["match_speed"])
            assert report["speed_ratio"] >= args.min_speed_ratio, (
                "network buffering slowed the match", report["role"], report["speed_ratio"], rate)
            assert any(not r["accepted"] for r in report["resolved"]), report
            submitted = {r["seq"]: r for r in report["submitted"]}
            assert set(submitted) == {r["seq"] for r in report["resolved"]}, report
            assert all(submitted[r["seq"]]["target"] <= r["tick"] <= submitted[r["seq"]]["source"] + 180 for r in report["resolved"] if r["accepted"]), report
            accepted = [r for r in report["resolved"] if r["accepted"]]
            assert [r["seq"] for r in accepted] == sorted(r["seq"] for r in accepted), report
            if not args.default_map:
                motion = report["movement_probe"]
                assert motion["accepted"] and motion["resolved"] and motion["samples"] >= 10, motion
                assert 0 <= motion["authority_ms"] <= motion["visual_ms"], motion
                assert motion["delay_ticks"] == expected_delay, motion
                assert motion["maximum_projection"] > 5, motion
                assert motion["max_retreat_after_confirmation_px"] <= args.max_retreat_px, (
                    "accepted movement visibly retreated after confirmation", report["role"], motion)
                if args.max_input_ms:
                    assert motion["authority_ms"] <= args.max_input_ms, (
                        "input-to-authoritative movement exceeds target", report["role"], motion)
        host = next(r for r in players if r["team"] == r["host_team"])
        guest = next(r for r in players if r["team"] != r["host_team"])
        if not args.default_map:
            host_motion, guest_motion = host["movement_probe"], guest["movement_probe"]
            # Both commands are sampled at tick 120 in this fixture. If a
            # scheduling pause crosses a frame, compare each source against
            # both peers' recorded policy rather than assuming equal ticks.
            for motion in (host_motion, guest_motion):
                source = int(motion["source_tick"])
                selected = []
                for schedule in (host_motion["delay_schedule"], guest_motion["delay_schedule"]):
                    applicable = [p for p in schedule if int(p["from_tick"]) <= source]
                    assert applicable, ("missing historical input rule", source, schedule)
                    selected.append(int(applicable[-1]["ticks"]))
                assert selected[0] == selected[1] == motion["delay_ticks"], ("input window differs by peer", selected, motion)
        htimes = {int(t): ms for t, ms in host["timeline"]}
        gtimes = {int(t): ms for t, ms in guest["timeline"]}
        gaps = sorted(abs(htimes[t] - gtimes[t]) for t in htimes.keys() & gtimes.keys() if 40 < t < 190 or 300 < t < 440)
        assert len(gaps) >= 30, gaps
        p95 = gaps[int(len(gaps) * .95)]
        assert p95 < 85, ("timeline skew p95 exceeds 85ms", p95)
        for report in reports:
            report.pop("timeline", None)
            report.pop("timing_samples", None)
            report.pop("submitted", None)
            report.pop("resolved", None)
            report.pop("movement_samples", None)
        print(json.dumps(reports, indent=2))
        print(f"FAIR TIMELINE: p95 absolute skew {p95:.1f} ms over {len(gaps)} shared frames")
        for report in players:
            print(f"SIMULATION SPEED {report['role']}: {report['steady_ticks_per_second']:.2f} ticks/s, {report['speed_ratio']:.1%} of configured speed")
            if report.get("movement_probe"):
                motion = report["movement_probe"]
                print(f"INPUT LATENCY {'host' if report['team'] == report['host_team'] else 'guest'}: "
                      f"visual {motion['visual_ms']:.1f} ms, actual motion {motion['authority_ms']:.1f} ms, "
                      f"confirmation {motion['confirmation_ms']:.1f} ms, "
                      f"retreat {motion['max_retreat_after_confirmation_px']:.3f} px")
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
