"""Villager losses and raid responses per duel service (from multi_agent.jsonl).

Usage: python tools/duel_analysis/raid_losses.py LABEL=DUEL_DIR [LABEL=DUEL_DIR ...]

Villager deaths are counted as drops in the villager count between ticks, so
a death and a finished villager in the same tick hide each other; the count is
a lower bound. Fight orders are villager attack commands; shelter orders are
villager moves issued while the commander reported a raid or base threat.
"""
import json
import sys
from pathlib import Path


def ticks(log: Path):
    for line in log.read_text(encoding="utf-8").splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get("event") == "tick":
            yield event


def role_status(event: dict, role: str) -> dict:
    """A field role's status from a tick event of either runtime: the seven
    roles report at the top level, the cabinet under the department that drives the role."""
    statuses = event.get("agent_status", {})
    for entry in statuses.values():
        if isinstance(entry, dict) and role in entry.get("roles", {}):
            return entry["roles"][role]
    return statuses.get(role, {})


def analyze(service: Path) -> dict:
    log = service / "logs" / "multi_agent.jsonl"
    villagers_ids, previous, drops, low, final = set(), None, 0, None, None
    first_drop = None
    fight = shelter = raid_ticks = 0
    events = list(ticks(log)) if log.exists() else []
    for event in events:
        for command in event.get("commands", []):
            if command.get("op") in ("gather", "build", "place_building", "place_wall"):
                villagers_ids.add(command.get("unit_id", command.get("builder_id")))
    for event in events:
        count = event.get("observation_summary", {}).get("own_entities", {}).get("villager", 0)
        if previous is not None and count < previous:
            drops += previous - count
            first_drop = first_drop if first_drop is not None else event.get("sim_time")
        previous, final = count, count
        low = count if low is None else min(low, count)
        reason = role_status(event, "commander").get("reason")
        raid_ticks += reason == "visible_economy_raid"
        for command in event.get("commands", []):
            if command.get("unit_id") not in villagers_ids:
                continue
            if command.get("op") == "attack":
                fight += 1
            elif command.get("op") == "move" and reason in ("visible_economy_raid", "visible_base_threat"):
                shelter += 1
    return {"villagers_lost": drops, "first_loss_at": first_drop, "min_villagers": low, "final_villagers": final,
            "fight_orders": fight, "shelter_moves": shelter, "raid_ticks": raid_ticks}


def main() -> None:
    for spec in sys.argv[1:]:
        label, _, folder = spec.partition("=")
        root = Path(folder)
        summary = json.loads((root / "summary.json").read_text(encoding="utf-8"))
        civs = {}
        for match in summary.get("matches", []):
            for arm, side in match["sides"].items():
                civs[(match["match"], side["team"])] = (arm, side["civ"])
        for service in sorted(p for p in root.iterdir() if p.is_dir() and p.name.startswith("m") and "-team" in p.name):
            match = int(service.name[1:service.name.index("-")])
            team = int(service.name.split("-team")[1][0])
            arm, civ = civs.get((match, team), ("?", "?"))
            row = analyze(service)
            print(f"{label:6} m{match} team{team} {civ:8} {arm:3} " + " ".join(f"{k}={v}" for k, v in row.items()))


if __name__ == "__main__":
    main()
