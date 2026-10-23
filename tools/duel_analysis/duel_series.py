"""Time series of both teams from a duel game log (every 120 game-seconds)."""
import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
labels = sys.argv[2:4] if len(sys.argv) >= 4 else ["team0", "team1"]
for line in path.read_text(encoding="utf-8").splitlines():
    match = re.match(r"AI DUEL (\d+)s: (.*)", line)
    if not match:
        continue
    cells = []
    for label, team in zip(labels, json.loads(match.group(2))):
        resources = [team["resources"][key] for key in "0123"]
        cells.append(f"{label} vil={team['villagers']:>2} army={team['military']:>2} age={team['age']} "
                     f"res={resources} tc={team['tc_hp']:.0f}")
    print(f"{match.group(1):>5}s  " + " | ".join(cells))
