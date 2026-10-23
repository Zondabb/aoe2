"""Compact view of finished duel reports (works before summary.json exists)."""
import json
import sys
from pathlib import Path

for batch in sys.argv[1:]:
    root = Path(batch)
    print(f"== {root.name}")
    for index in range(4):
        report = root / f"m{index}-report.json"
        if not report.exists():
            print(f"  m{index}: running")
            continue
        data = json.loads(report.read_text(encoding="utf-8"))
        arms = ("on", "off") if index % 2 == 0 else ("off", "on")
        winner = data["winner"]
        line = [f"  m{index}: winner={arms[winner] + '(team' + str(winner) + ')' if winner in (0, 1) else 'none'} at {data['finished_at']:.0f}s"]
        for team, side in enumerate(data["teams"]):
            final = side["final"]
            line.append(f"[team{team} {arms[team]} {side['civ']}: tc={final['tc_hp']:.0f} vil={final['villagers']} "
                        f"army={final['military']}({final['military_value']}) age={final['age']} "
                        f"lost={side['lost_military_value']} produced={side['produced_military_value']} "
                        f"rejects={sum(side['rejects'].values())}]")
        print(" ".join(line))
