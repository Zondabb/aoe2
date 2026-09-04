#!/usr/bin/env python3
"""Export data/ai/profile_*.tres fields to ai_service_python/data/ai/*.json."""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "data" / "ai"
DST = ROOT / "ai_service_python" / "data" / "ai"


def parse_tres(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    data: dict = {}
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("civ_id"):
            data["civ_id"] = line.split("=", 1)[1].strip().strip('"&')
        elif line.startswith("villager_target"):
            data["villager_target"] = int(line.split("=", 1)[1].strip())
        elif line.startswith("high_food_stockpile"):
            data["high_food_stockpile"] = int(line.split("=", 1)[1].strip())
        elif line.startswith("military_attack_count"):
            data["military_attack_count"] = int(line.split("=", 1)[1].strip())
        elif line.startswith("attack_time_seconds"):
            data["attack_time_seconds"] = float(line.split("=", 1)[1].strip())
        elif line.startswith("retarget_radius"):
            data["retarget_radius"] = float(line.split("=", 1)[1].strip())
        elif line.startswith("rally_radius"):
            data["rally_radius"] = float(line.split("=", 1)[1].strip())
        elif line.startswith("unique_unit_priority"):
            data["unique_unit_priority"] = line.split("=", 1)[1].strip().lower() == "true"
        elif line.startswith("opening_seconds"):
            data["opening_seconds"] = float(line.split("=", 1)[1].strip())
        elif line.startswith("defend_radius"):
            data["defend_radius"] = float(line.split("=", 1)[1].strip())
        elif line.startswith("build_order"):
            ids = re.findall(r'"([^"]+)"|&"([^"]+)"', line)
            data["build_order"] = [a or b for a, b in ids]
    comp: dict[str, int] = {}
    comp_block = re.search(r"army_composition = \{(.*?)\}", text, re.S)
    if comp_block:
        for unit_id, count in re.findall(r'&"([^"]+)":\s*(\d+)', comp_block.group(1)):
            comp[unit_id] = int(count)
    data["army_composition"] = comp
    return data


def main() -> None:
    DST.mkdir(parents=True, exist_ok=True)
    for src in sorted(SRC.glob("profile_*.tres")):
        payload = parse_tres(src)
        out = DST / f"{src.stem}.json"
        out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        print(f"Wrote {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
