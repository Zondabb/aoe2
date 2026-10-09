#!/usr/bin/env python3
"""Read original HD siege projectiles and export their unmodified SLP art.

Distances/speeds in the generated profile are original DAT tile units. Runtime
conversion belongs to GameCatalog, alongside the existing map distance scale.
Projectile ground shadows are separate assets so they do not float with the arc.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from export_sprites import _read_slp, load_config, pack_sheet
from import_civilizations import read_dat


ROOT = Path(__file__).resolve().parents[2]
UNIT_IDS = {"mangonel": 280, "onager": 550, "siege_onager": 588, "trebuchet": 42}
DEFAULT_OPENAGE = Path("D:/Users/jiangzw/workspace/openage_workspace/openage")


def number(value):
    """Remove binary32 storage noise without changing source precision."""
    return round(float(value), 6)


def export_graphic(graphic, resources, out_dir, key):
    """Projectile graphics use one direction and an independent ground shadow."""
    if graphic.angle_count != 1:
        raise ValueError(f"Expected one projectile direction: {graphic.graphic_id}")
    frames, frame_meta, masks, source, palette = _read_slp(resources, graphic.slp_id, 1)
    count = max(1, int(graphic.frame_count))
    if len(frames) < count:
        raise ValueError(f"Graphic {graphic.graphic_id} has incomplete frames")
    frames, frame_meta, masks = frames[:count], frame_meta[:count], masks[:count]
    if any(mask.getchannel("R").getbbox() for mask in masks):
        raise ValueError(f"Unexpected player colors in projectile {graphic.graphic_id}")
    if not all(frame.getbbox() for frame in frames):
        raise ValueError(f"Empty projectile frame: {graphic.graphic_id}")
    atlas, cols, rows, frame_w, frame_h, pads = pack_sheet(frames)
    out_dir.mkdir(parents=True, exist_ok=True)
    atlas.save(out_dir / f"{key}.png")
    metadata = {
        "key": key,
        "graphic_id": graphic.graphic_id,
        "slp_id": graphic.slp_id,
        "source": Path(source).relative_to(resources).as_posix(),
        "palette": Path(palette).relative_to(resources).as_posix(),
        "cols": cols,
        "rows": rows,
        "frame_w": frame_w,
        "frame_h": frame_h,
        "frame_count": count,
        "directions": 1,
        "frames_per_direction": count,
        "frame_duration": number(graphic.frame_rate),
        "hotspots": [
            {"x": meta.hotspot_x + pad["x"], "y": meta.hotspot_y + pad["y"]}
            for meta, pad in zip(frame_meta, pads)
        ],
        "player_color": {"mode": "none"},
        "includes_shadow": False,
    }
    (out_dir / f"{key}.json").write_text(
        json.dumps(metadata, indent=2) + "\n", encoding="utf-8"
    )
    return "res://" + (out_dir / key).relative_to(ROOT).as_posix()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=Path)
    parser.add_argument("--openage", type=Path, default=DEFAULT_OPENAGE)
    parser.add_argument("--out", type=Path, default=ROOT / "assets/sprites/projectiles")
    parser.add_argument("--catalog", type=Path, default=ROOT / "data/siege_projectiles.json")
    args = parser.parse_args()
    resources = args.resources or Path(load_config(None)["aoe2_resources"])
    dat_path = resources / "_common/dat/empires2_x1_p1.dat"
    dat, _length = read_dat(dat_path, args.openage)
    units = {unit.id0: unit for rows in dat.civs[6].units.values() for unit in rows}
    graphics = {graphic.graphic_id: graphic for graphic in dat.graphics}
    exported = {}

    def sheet(graphic_id, key):
        if graphic_id not in exported:
            exported[graphic_id] = export_graphic(graphics[graphic_id], resources, args.out, key)
        return exported[graphic_id]

    records = {}
    for key, unit_id in UNIT_IDS.items():
        unit = units[unit_id]
        projectile = units[unit.projectile_id0]
        attack_graphic = graphics[unit.attack_sprite_id]
        flight_graphic = graphics[projectile.idle_graphic0]
        impact_graphic = graphics[projectile.dying_graphic]
        projectile_name = "trebuchet_stone" if key == "trebuchet" else "mangonel_stone"
        impact_name = "trebuchet_impact" if key == "trebuchet" else "mangonel_impact"
        record = {
            "source_id": unit_id,
            "projectile_source_id": projectile.id0,
            "projectile_kind": "stone",
            "attack_range": number(unit.weapon_range_max),
            "min_range": number(unit.weapon_range_min),
            "cooldown": number(unit.attack_speed),
            "speed": number(projectile.speed),
            "splash_radius": number(unit.blast_range),
            "arc": number(projectile.projectile_arc),
            "release_delay": number(unit.frame_delay * attack_graphic.frame_rate),
            "attack_frame_delay": unit.frame_delay,
            "attack_frame_duration": number(attack_graphic.frame_rate),
            "attack_animation_duration": number(attack_graphic.frame_count * attack_graphic.frame_rate),
            "launch_height": number(unit.weapon_offset[2]),
            "friendly_fire": key != "trebuchet",
            "attack_uses_melee_armor": key != "trebuchet",
            "flight_sheet": sheet(projectile.idle_graphic0, projectile_name),
            "flight_frame_duration": number(flight_graphic.frame_rate),
            "impact_sheet": sheet(projectile.dying_graphic, impact_name),
            "impact_frame_duration": number(impact_graphic.frame_rate),
            "impact_duration": number(impact_graphic.frame_count * impact_graphic.frame_rate),
            "accuracy": unit.accuracy,
            "accuracy_dispersion": number(unit.accuracy_dispersion),
            "smart_mode": projectile.smart_mode,
            "blast_level_offence": unit.blast_level_offence,
        }
        for delta in flight_graphic.graphic_deltas:
            if delta.graphic_id >= 0:
                record["shadow_sheet"] = sheet(delta.graphic_id, projectile_name + "_shadow")
        if unit.projectile_id1 >= 0:
            secondary = units[unit.projectile_id1]
            record["scatter_sheet"] = sheet(secondary.idle_graphic0, "mangonel_scatter")
            record["scatter_count"] = int(unit.projectile_min_count)
            record["extra_projectile"] = {
                "source_id": secondary.id0,
                # DAT min/max include the primary projectile.
                "count": int(unit.projectile_min_count) - 1,
                "total_count": int(unit.projectile_min_count),
                "flight_sheet": record["scatter_sheet"],
                "flight_frame_duration": number(graphics[secondary.idle_graphic0].frame_rate),
                "spread_width": number(unit.projectile_spawning_area_width),
                "spread_length": number(unit.projectile_spawning_area_length),
                "randomness": number(unit.projectile_spawning_area_randomness),
            }
        records[key] = record
    catalog = {
        "schema_version": 1,
        "source": {
            "edition": "Age of Empires II HD / The Conquerors base data",
            "dat": "resources/_common/dat/empires2_x1_p1.dat",
            "dat_version": dat.versionstr,
            "sha256": hashlib.sha256(dat_path.read_bytes()).hexdigest(),
            "distance_units": "original DAT tiles, before the runtime x4 conversion",
            "time_units": "simulation seconds",
            "arc_units": "radians",
            "friendly_fire_reference": "openage/doc/reverse_engineering/game_mechanics/accuracy.md#friendly-fire",
            "release_delay_reference": "openage/openage/convert/processor/conversion/aoc/ability_subprocessor.py: frame_rate * frame_delay",
            "notes": [
                "Trebuchet combat profile uses unpacked unit 42; production uses packed unit 331.",
                "Mangonel damage uses melee armor although its delivery is a ranged projectile.",
                "DAT blast_range describes the radius; no distance falloff formula is stored in this file.",
                "Secondary stones supply the visual cluster; the game runtime resolves one splash per volley.",
                "scatter_count retains DAT total count (including the primary); extra_projectile.count excludes it.",
                "Flight art excludes DAT shadow deltas, which must remain on the ground.",
            ],
        },
        "units": records,
    }
    args.catalog.parent.mkdir(parents=True, exist_ok=True)
    args.catalog.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Exported {len(exported)} projectile sheets and {len(records)} siege profiles")


if __name__ == "__main__":
    main()
