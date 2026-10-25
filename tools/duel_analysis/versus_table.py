"""Win/loss table across several duel batches, by arm and by team position.

Usage: python tools/duel_analysis/versus_table.py LABEL=DUEL_DIR [LABEL=DUEL_DIR ...]

Each batch is one tools/ai_duel_ab.py run (summary.json). For a version duel
"on" is the candidate code and "off" the baseline. Team position is printed
because a map position advantage would otherwise look like a code effect.
"""
import json
import sys
from collections import Counter
from pathlib import Path


def main() -> None:
    arms, teams, rows = Counter(), Counter(), []
    trades = Counter()
    for spec in sys.argv[1:]:
        label, _, folder = spec.partition("=")
        summary = json.loads((Path(folder) / "summary.json").read_text(encoding="utf-8"))
        for match in summary["matches"]:
            on, off = match["sides"]["on"], match["sides"]["off"]
            winner = match["winner_arm"]
            team = match["sides"][winner]["team"] if winner else None
            arms[winner or "draw"] += 1
            teams[f"team{team}" if team is not None else "draw"] += 1
            for arm, side in (("on", on), ("off", off)):
                trades[f"{arm}_killed"] += side["killed_military_value"]
                trades[f"{arm}_final_army"] += side["final_military_value"]
            rows.append(f"{label:8} seed={summary.get('map_seed')} m{match['match']} on={on['civ']}/team{on['team']} "
                        f"winner={winner or 'draw'} at={match['finished_at']:.0f} "
                        f"villagers on/off={on['villagers']}/{off['villagers']} army on/off={on['final_military_value']}/{off['final_military_value']}")
    print("\n".join(rows))
    print(f"by arm: on {arms['on']} - off {arms['off']} - draw {arms['draw']}")
    print(f"by team: team0 {teams['team0']} - team1 {teams['team1']} - draw {teams['draw']}")
    print("military value killed on/off: %d/%d; final army on/off: %d/%d" % (
        trades["on_killed"], trades["off_killed"], trades["on_final_army"], trades["off_final_army"]))


if __name__ == "__main__":
    main()
