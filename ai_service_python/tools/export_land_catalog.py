"""Export the gameplay-only subsets used by a standalone AI service image."""
from __future__ import annotations

import json
from pathlib import Path


def project_catalog(source: dict) -> dict:
    fields = {
        "units": ("cost", "population", "train_at", "attack", "required_age", "civilizations"),
        "buildings": ("cost", "footprint", "required_age", "civilizations", "required_buildings", "required_techs"),
        "technologies": ("cost",),
    }
    result = {"source_sha256": source["source"]["sha256"]}
    for section, keys in fields.items():
        entries = source["techs" if section == "technologies" else section]
        result[section] = {name: {key: value for key, value in record.items() if key in keys} for name, record in entries.items()}
    return result


# Battle-model attributes. Distances stay in source tiles; the AI combat model
# applies the same conversion constants as scripts/data/game_catalog.gd.
COMBAT_UNIT_KEYS = ("cost", "hp", "attack", "attack_range", "min_range", "cooldown", "melee_armor", "pierce_armor",
                    "attack_type", "source_class", "source_armors", "source_attacks", "speed", "train_time",
                    "train_at", "required_age", "population", "civilizations")
COMBAT_BUILDING_KEYS = ("hp", "attack", "attack_range", "min_range", "cooldown", "melee_armor", "pierce_armor",
                        "source_armors", "source_attacks", "footprint")


def project_combat_catalog(source: dict) -> dict:
    return {"source_sha256": source["source"]["sha256"],
            "units": {name: {key: record[key] for key in COMBAT_UNIT_KEYS if key in record}
                      for name, record in source["units"].items()},
            "buildings": {name: {key: record[key] for key in COMBAT_BUILDING_KEYS if key in record}
                          for name, record in source["buildings"].items()}}


if __name__ == "__main__":
    service = Path(__file__).resolve().parents[1]
    source = json.loads((service.parent / "data/civilization_catalog.json").read_text(encoding="utf-8"))
    for name, projected in (("land_catalog.json", project_catalog(source)), ("combat_catalog.json", project_combat_catalog(source))):
        output = service / "data" / name
        output.write_text(json.dumps(projected, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(output)
