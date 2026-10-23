"""Classify re-targets: away from a target still alive (wasteful) vs a dead one."""
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
limit = float(sys.argv[2]) if len(sys.argv) > 2 else float("inf")   # same game-time window across batches
for service in sorted(p for p in root.iterdir() if p.is_dir() and p.name.startswith("m")):
    log = service / "logs" / "multi_agent.jsonl"
    if not log.exists():
        continue
    orders = []                      # (time, unit, target)
    last_seen_target: dict[int, float] = {}
    for line in log.read_text(encoding="utf-8").splitlines():
        event = json.loads(line)
        if event.get("event") != "tick":
            continue
        now = float(event.get("sim_time", 0))
        if now > limit:
            break
        for command in event.get("commands", []):
            if command.get("op") == "attack":
                orders.append((now, command["unit_id"], command["target_id"]))
                last_seen_target[command["target_id"]] = now
    history: dict[int, list] = {}
    alive_switch = dead_switch = oscillation = 0
    for now, uid, target in orders:
        previous = history.setdefault(uid, [])
        if previous and previous[-1][1] != target and now - previous[-1][0] <= 6:
            old = previous[-1][1]
            # The old target was attacked again later by someone: it was alive.
            if last_seen_target.get(old, -1) > now:
                alive_switch += 1
            else:
                dead_switch += 1
            if len(previous) >= 2 and previous[-2][1] == target and now - previous[-2][0] <= 12:
                oscillation += 1
        previous.append((now, target))
    print(f"{service.name}: attacks={len(orders)} switch_from_alive={alive_switch} "
          f"switch_after_target_gone={dead_switch} A-B-A_oscillations={oscillation}")
