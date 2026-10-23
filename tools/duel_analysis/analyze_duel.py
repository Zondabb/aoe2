"""Behaviour counts per duel service from its multi_agent.jsonl tick log."""
import json
import sys
from collections import Counter
from pathlib import Path

root = Path(sys.argv[1])
for service in sorted(p for p in root.iterdir() if p.is_dir() and p.name.startswith("m")):
    log = service / "logs" / "multi_agent.jsonl"
    if not log.exists():
        continue
    retreats = blocked = ticks = 0
    previous_phase = None
    ops, trained, reasons = Counter(), Counter(), Counter()
    for line in log.read_text(encoding="utf-8").splitlines():
        event = json.loads(line)
        if event.get("event") != "tick":
            continue
        ticks += 1
        phase = event.get("goals", {}).get("phase")
        if phase == "retreat" and previous_phase != "retreat":
            retreats += 1
        previous_phase = phase
        combat = event.get("agent_status", {}).get("combat", {})
        reasons[combat.get("reason")] += 1
        if combat.get("reason") == "observed_defenders_require_reinforcements":
            blocked += 1
        for command in event.get("commands", []):
            ops[command.get("op")] += 1
            if command.get("op") == "train":
                trained[command.get("unit_def_id")] += 1
    print(f"{service.name}: ticks={ticks} retreat_entries={retreats} unsafe_blocked_ticks={blocked} "
          f"attack={ops['attack']} move={ops['move']} trained={dict(trained.most_common(6))}")
