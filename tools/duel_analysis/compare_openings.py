"""Compare opening milestones of several duel batches with the same configurations.

Usage: compare_openings.py LABEL=DIR [LABEL=DIR ...]
Prints barracks completion, first soldier and Feudal Age per configuration/team,
plus villagers, soldiers and military value produced at the end of the run.
"""
import json
import sys
from pathlib import Path

batches = [arg.split("=", 1) for arg in sys.argv[1:]]
reports = {label: {int(p.stem[1]): json.loads(p.read_text(encoding="utf-8"))
                   for p in Path(directory).glob("m*-report.json")} for label, directory in batches}
indices = sorted(set.intersection(*(set(r) for r in reports.values())))
print(f"{'config/team':<22}" + "".join(f"{label:>34}" for label, _ in batches))
print(f"{'':<22}" + "".join(f"{'barracks/soldier/age1  vil army':>34}" for _ in batches))
for index in indices:
    for team in (0, 1):
        civ = reports[batches[0][0]][index]["teams"][team]["civ"]
        cells = []
        for label, _ in batches:
            side = reports[label][index]["teams"][team]
            m, final = side["milestones"], side["final"]
            fmt = lambda v: f"{v:.0f}" if isinstance(v, (int, float)) else "-"
            cells.append(f"{fmt(m.get('barracks'))}/{fmt(m.get('first_soldier'))}/{fmt(m.get('age_1'))}  "
                         f"{final['villagers']:>3} {final['military']:>3}({side['produced_military_value']})")
        print(f"m{index} team{team} {civ:<11}" + "".join(f"{c:>34}" for c in cells))
