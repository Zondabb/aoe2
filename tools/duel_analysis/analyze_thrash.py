"""Target thrash per duel service: re-targeting a unit within 6 game-seconds."""
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
for service in sorted(p for p in root.iterdir() if p.is_dir() and p.name.startswith("m")):
    log = service / "logs" / "multi_agent.jsonl"
    if not log.exists():
        continue
    last: dict[int, tuple[float, int]] = {}
    attacks = quick_switch = same_target = 0
    for line in log.read_text(encoding="utf-8").splitlines():
        event = json.loads(line)
        if event.get("event") != "tick":
            continue
        now = float(event.get("sim_time", 0))
        for command in event.get("commands", []):
            if command.get("op") != "attack":
                continue
            attacks += 1
            uid, target = command.get("unit_id"), command.get("target_id")
            previous = last.get(uid)
            if previous and now - previous[0] <= 6:
                if previous[1] != target:
                    quick_switch += 1
                else:
                    same_target += 1
            last[uid] = (now, target)
    rate = quick_switch / attacks if attacks else 0
    print(f"{service.name}: attacks={attacks} switched_within_6s={quick_switch} ({rate:.0%}) reissued_same={same_target}")
