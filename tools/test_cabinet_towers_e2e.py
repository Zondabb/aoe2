"""Run a complete Godot duel with a cabinet order for four towers and a deterministic premier reply."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    args = parser.parse_args()
    sys.path.insert(0, str(ROOT / "ai_service_python"))
    from brain.cabinet.orders import TOWER_LINE
    from brain.cabinet.runtime import CabinetRuntime
    from brain.multi_agent.runtime import MultiAgentRuntime
    from protocol.models import ChatCompletionRequest

    (ROOT / ".godot").mkdir(exist_ok=True)
    logs = Path(tempfile.mkdtemp(prefix="cabinet-towers-", dir=ROOT / ".godot"))
    observation_file, report = logs / "observation.json", logs / "match.json"
    env = {**os.environ, "APPDATA": str(logs), "XDG_DATA_HOME": str(logs)}
    command = [args.godot, "--headless", "--fixed-fps", "60", "--path", str(ROOT), "--log-file", str(logs / "game.log"),
               "--script", "res://tests/run_cabinet_towers_match.gd", "--", str(observation_file), str(observation_file),
               "2400", str(report), "chinese", "teutons"]
    cabinet = CabinetRuntime("chinese")
    teams = [cabinet, MultiAgentRuntime("teutons")]
    order = "造 4 座箭塔"
    completed_at = None
    completed_count = 0
    dispatched, accepted, rejected = set(), set(), set()

    print(f"Cabinet tower duel: {logs}", flush=True)
    with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          encoding="utf-8", errors="replace", env=env,
                          creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)) as game:
        watchdog = threading.Timer(1800, game.kill)
        watchdog.start()
        try:
            for line in game.stdout:
                if line.strip() != "CABINET TOWER TICK":
                    print(line, end="", flush=True)
                    continue
                req = ChatCompletionRequest.model_validate_json(observation_file.read_bytes())
                team = req.metadata.team
                if team == 0:
                    req.observation.player_instructions = [order]
                    for event in req.events:
                        feedback = event.model_extra or {}
                        cid = feedback.get("command_id")
                        if event.type == "command_result" and cid in dispatched:
                            (accepted if feedback.get("ok") is True else rejected).add(cid)
                result = teams[team].tick(req)
                if team == 0:
                    if cabinet.planning_brief("premier_orders"):
                        if not cabinet.apply_plan("premier_orders", {
                            "grasp": "exact", "thinking": "元首要求加强防守。", "decision": "建造四座箭塔。",
                            "mandates": [{"kind": "towers", "subject": "", "amount": 4, "urgency": "normal"}],
                        }):
                            raise RuntimeError("Cabinet refused the four-tower order")
                    if completed_at is None and cabinet.ledger.orders[0].status == "done":
                        completed_at = req.metadata.time_sec
                        completed_count = sum(1 for b in req.observation.entities if b.get("team") == team
                                              and b.get("def_id") in TOWER_LINE and b.get("is_complete") and b.get("hp", 1) > 0)
                        print(f"{completed_count} towers complete at {completed_at:g}s", flush=True)
                    cabinet.take_journal()
                for cmd in result["commands"]:
                    cmd["session_epoch"] = req.metadata.session_epoch
                    if team == 0 and cmd["op"] == "place_building" and cmd["building_def_id"] in TOWER_LINE:
                        if completed_at is not None:
                            raise RuntimeError("Cabinet ordered another tower after completing the order")
                        dispatched.add(cmd["command_id"])
                game.stdin.write(json.dumps({"commands": result["commands"]}) + "\n")
                game.stdin.flush()
            exit_code = game.wait()
        except BaseException:
            game.kill()
            raise
        finally:
            watchdog.cancel()
        if exit_code != 0 or not report.exists():
            return 1
    match = json.loads(report.read_text(encoding="utf-8"))
    result = {"target": 4, "complete": completed_count, "completed_at": completed_at, "dispatched": len(dispatched),
              "accepted": len(accepted), "rejected": len(rejected), "missing_receipts": len(dispatched - accepted - rejected)}
    match["tower_order"] = result
    report.write_text(json.dumps(match, indent=2) + "\n", encoding="utf-8")
    print(f"Tower order {result}", flush=True)
    return 0 if completed_count == 4 and not result["missing_receipts"] and len(accepted) >= 4 and match["winner"] in (0, 1) else 1


if __name__ == "__main__":
    raise SystemExit(main())

