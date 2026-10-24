"""A/B duels: strategic intelligence ON vs OFF, each side on its own AI service.

Both services run the deterministic executor (backend rules_compat): no model
is called, so the only difference between the sides is AOE2_AI_INTELLIGENCE.
Matches alternate which team (and civilization) gets the layer. Each match is
a real headless Godot simulation with fog, economy, combat and TC victory.
Logs and reports stay under .godot/ai-duel-*/.
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


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def score(report: dict, team: int) -> dict:
    me, them = report["teams"][team], report["teams"][1 - team]
    return {"won": report["winner"] == team, "lost": report["winner"] == 1 - team,
            "enemy_tc_hp_left": them["final"]["tc_hp"],
            "own_tc_hp": me["final"]["tc_hp"], "lost_military_value": me["lost_military_value"],
            "killed_military_value": them["lost_military_value"], "final_military_value": me["final"]["military_value"],
            "villagers": me["final"]["villagers"], "age": me["final"]["age"], "rejects": sum(me["rejects"].values())}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--matches", type=int, default=2, help="even numbers balance sides")
    parser.add_argument("--duration", type=float, default=2400)
    parser.add_argument("--timeout", type=float, default=3600, help="wall seconds for the whole batch")
    parser.add_argument("--civs", nargs=2, default=["chinese", "teutons"])
    parser.add_argument("--llm-config", default="",
                        help="Service TOML with a real model (e.g. ai_service_python/config.toml); both sides then "
                             "plan with that model. Default: model-free deterministic executor")
    parser.add_argument("--parallel", type=int, default=0, help="matches running at once (default: all)")
    parser.add_argument("--calls-per-minute", type=int, default=6, help="LLM mode: model calls per team per minute")
    parser.add_argument("--service-dir", default="", help="AI service directory to run (default: ai_service_python), "
                        "e.g. an isolated copy with a candidate change; Godot always uses this repository")
    parser.add_argument("--indices", default="", help="comma-separated match configurations to run, e.g. 0,2")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    (root / ".godot").mkdir(exist_ok=True)
    logs = Path(tempfile.mkdtemp(prefix="ai-duel-", dir=root / ".godot"))
    base_env = {k: v for k, v in os.environ.items() if not k.startswith(("AOE2_AI_", "AOE2_LLM_"))}
    service_dir = Path(args.service_dir).resolve() if args.service_dir else root / "ai_service_python"
    indices = [int(i) for i in args.indices.split(",") if i.strip()] if args.indices else list(range(args.matches))
    flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
    processes, handles, matches = [], [], []

    def launch(command, label, cwd, env):
        handle = (logs / f"{label}.txt").open("w", encoding="utf-8")
        handles.append(handle)
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=handle, stderr=subprocess.STDOUT, creationflags=flags)
        processes.append(process)
        return process

    def start_match(index):
        arms = ("on", "off") if index % 2 == 0 else ("off", "on")
        # Deterministic sim + deterministic AI: repeating a pairing replays
        # the same game. Alternate sides, then civilizations, per match.
        civs = list(args.civs) if (index // 2) % 2 == 0 else list(reversed(args.civs))
        urls, services = [], []
        for team, arm in enumerate(arms):
            port = free_port()
            directory = logs / f"m{index}-team{team}-{arm}"
            directory.mkdir()
            env = {**base_env, "AOE2_AI_INTELLIGENCE": arm, "AOE2_AI_STRATEGY_MEMORY": "off", "PYTHONUTF8": "1"}
            if args.llm_config:
                # Both sides plan with the same real model; only the switch differs.
                # Use the operator's file in place (keys stay there, never copied).
                # One local GPU model serves every service: mirror start_qwen3_proxy.ps1.
                env.update(AOE2_AI_MODEL_CONCURRENCY="1", AOE2_AI_MODEL_CONCURRENCY_PER_MATCH="1",
                           AOE2_AI_MODEL_CALLS_PER_MINUTE=str(args.calls_per_minute))
                command = [sys.executable, "main.py", "--config", str(Path(args.llm_config).resolve()),
                           "--port", str(port), "--log-dir", str(directory / "logs")]
            else:
                config = directory / "config.toml"
                config.write_text('[service]\nhost = "127.0.0.1"\n'
                                  f'port = {port}\napi_token = ""\nlog_dir = {json.dumps(str(directory / "logs"))}\n\n'
                                  '[llm]\nbackend = "rules_compat"\n', encoding="utf-8")
                command = [sys.executable, "main.py", "--config", str(config)]
            service = launch(command, f"m{index}-service{team}", service_dir, env)
            services.append(service)
            deadline = time.monotonic() + 30
            while True:
                if service.poll() is not None:
                    raise RuntimeError(f"service m{index} team{team} exited")
                try:
                    with urlopen(f"http://127.0.0.1:{port}/health", timeout=.5) as response:
                        if response.status == 200:
                            break
                except OSError:
                    if time.monotonic() > deadline:
                        raise RuntimeError("service startup timed out")
                    time.sleep(.1)
            urls.append(f"http://127.0.0.1:{port}")
        report = logs / f"m{index}-report.json"
        game_env = {**base_env, "APPDATA": str(logs / f"profile-m{index}")}
        Path(game_env["APPDATA"]).mkdir()
        game = launch([args.godot, "--headless", "--path", str(root), "--log-file", str(logs / f"m{index}-game.log"),
                       "--script", "res://tests/run_ai_duel_match.gd", "--", *urls, str(args.duration), str(report), *civs],
                      f"m{index}-game", root, game_env)
        print(f"match {index} started: team0={arms[0]} {civs[0]} vs team1={arms[1]} {civs[1]}", flush=True)
        return {"index": index, "arms": arms, "game": game, "report": report, "services": services, "stopped": False}

    try:
        pending = list(indices)
        limit = args.parallel if args.parallel > 0 else len(indices)
        deadline = time.monotonic() + args.timeout
        while pending or any(m["game"].poll() is None for m in matches):
            running = [m for m in matches if m["game"].poll() is None]
            while pending and len(running) < limit:
                started = start_match(pending.pop(0))
                matches.append(started)
                running.append(started)
            for m in matches:
                if m["game"].poll() is None:
                    output = (logs / f"m{m['index']}-game.txt").read_text(encoding="utf-8", errors="replace")
                    if "SCRIPT ERROR:" in output:
                        raise RuntimeError(f"match {m['index']} script error:\n{output[-6000:]}")
                elif not m["stopped"]:
                    # Free the model/GPU and ports as soon as a match ends.
                    m["stopped"] = True
                    for service in m["services"]:
                        if service.poll() is None:
                            service.terminate()
                    print(f"match {m['index']} finished", flush=True)
            if time.monotonic() > deadline:
                raise RuntimeError("duel batch timed out")
            time.sleep(1)
        totals = {arm: {"matches": 0, "wins": 0, "losses": 0, "enemy_tc_hp_left": 0, "lost_military_value": 0,
                        "killed_military_value": 0, "final_military_value": 0, "rejects": 0} for arm in ("on", "off")}
        results = []
        for m in matches:
            if not m["report"].exists():
                raise RuntimeError(f"match {m['index']} produced no report")
            report = json.loads(m["report"].read_text(encoding="utf-8"))
            if report.get("failed"):
                raise RuntimeError(f"match {m['index']} failed: {report['failed']}")
            row = {"match": m["index"], "winner_arm": m["arms"][report["winner"]] if report["winner"] in (0, 1) else None,
                   "finished_at": report["finished_at"], "sides": {}}
            for team, arm in enumerate(m["arms"]):
                side = score(report, team)
                row["sides"][arm] = {**side, "team": team, "civ": report["teams"][team]["civ"],
                                     "produced": report["teams"][team]["produced"], "milestones": report["teams"][team]["milestones"]}
                total = totals[arm]
                total["matches"] += 1
                total["wins"] += side["won"]
                total["losses"] += side["lost"]
                for key in ("enemy_tc_hp_left", "lost_military_value", "killed_military_value", "final_military_value", "rejects"):
                    total[key] += side[key]
            results.append(row)
        summary = {"mode": "llm:" + Path(args.llm_config).name if args.llm_config else "deterministic",
                   "service_dir": str(service_dir),
                   "duration": args.duration, "civs": args.civs, "totals": totals, "matches": results}
        (logs / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1), encoding="utf-8")
        print(json.dumps(summary, ensure_ascii=False, indent=1))
        print(f"AI DUEL A/B COMPLETE; logs: {logs}")
        return 0
    except (OSError, RuntimeError, ValueError, KeyError) as error:
        print(f"AI DUEL A/B FAILED: {error}; logs: {logs}", file=sys.stderr)
        return 1
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
        for handle in handles:
            handle.close()


if __name__ == "__main__":
    raise SystemExit(main())
