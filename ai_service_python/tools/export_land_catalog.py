"""Export the gameplay-only subset used by a standalone AI service image."""
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


if __name__ == "__main__":
    service = Path(__file__).resolve().parents[1]
    source = json.loads((service.parent / "data/civilization_catalog.json").read_text(encoding="utf-8"))
    output = service / "data/land_catalog.json"
    output.write_text(json.dumps(project_catalog(source), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(output)
