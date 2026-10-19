#!/usr/bin/env python3
"""Import original HD arrow/javelin profiles, flight pixels and ground shadows.

The DAT values stay in their original units. Runtime distance/height conversion
and the approximation of Genie ballistic motion belong to the game runtime.
Flight frames encode direction and pitch, not a time-based animation.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from export_sprites import _read_slp, load_config, pack_sheet
from import_civilizations import read_dat


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OPENAGE = Path("E:/workspace/openage")
FLIGHT_GRAPHICS = {3378: "arrow", 3399: "arrow_javelin"}


def number(value):
    return round(float(value), 6)


def export_graphic(graphic, resources, out_dir, key, *, shadow=False):
    frames, frame_meta, masks, source, palette = _read_slp(resources, graphic.slp_id, 1)
    pitch_count = max(1, int(graphic.frame_count))
    if len(frames) % pitch_count:
        raise ValueError(f"Incomplete direction group for graphic {graphic.graphic_id}")
    if any(mask.getchannel("R").getbbox() for mask in masks):
        raise ValueError(f"Unexpected player color in projectile graphic {graphic.graphic_id}")
    if not all(frame.getbbox() for frame in frames):
        raise ValueError(f"Empty projectile frame in graphic {graphic.graphic_id}")
    atlas, cols, rows, frame_w, frame_h, pads = pack_sheet(frames)
    out_dir.mkdir(parents=True, exist_ok=True)
    atlas.save(out_dir / f"{key}.png")
    source_path = Path(source)
    metadata = {
        "key": key,
        "graphic_id": graphic.graphic_id,
        "slp_id": graphic.slp_id,
        "source": source_path.relative_to(resources).as_posix(),
        "source_sha256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
        "palette": Path(palette).relative_to(resources).as_posix(),
        "cols": cols,
        "rows": rows,
        "frame_w": frame_w,
        "frame_h": frame_h,
        "frame_count": len(frames),
        "directions": len(frames) // pitch_count,
        "stored_direction_count": len(frames) // pitch_count,
        "source_angle_count": int(graphic.angle_count),
        "frames_per_direction": pitch_count,
        "frame_duration": number(graphic.frame_rate),
        "mirroring_mode": int(graphic.mirroring_mode),
        "frame_layout": "direction_pitch" if pitch_count > 1 else "direction",
        "hotspots": [
            {"x": meta.hotspot_x + pad["x"], "y": meta.hotspot_y + pad["y"]}
            for meta, pad in zip(frame_meta, pads)
        ],
        "player_color": {"mode": "none"},
        "includes_shadow": shadow,
        "notes": [
            "All SLP pixels and per-frame hotspots are preserved without recoloring or resizing.",
            "source_angle_count is the DAT heading count; directions is the number of groups actually stored in the SLP.",
            "Pitch poses run from upward to downward; the sequence is not a flight-time animation.",
        ],
    }
    (out_dir / f"{key}.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    return "res://" + (out_dir / key).relative_to(ROOT).as_posix()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=Path)
    parser.add_argument("--openage", type=Path, default=DEFAULT_OPENAGE)
    parser.add_argument("--out", type=Path, default=ROOT / "assets/sprites/projectiles")
    parser.add_argument("--catalog", type=Path, default=ROOT / "data/arrow_projectiles.json")
    args = parser.parse_args()
    resources = args.resources or Path(load_config(None)["aoe2_resources"])
    dat_path = resources / "_common/dat/empires2_x1_p1.dat"
    dat, _length = read_dat(dat_path, args.openage)
    units = {unit.id0: unit for rows in dat.civs[6].units.values() for unit in rows}
    graphics = {graphic.graphic_id: graphic for graphic in dat.graphics}
    current = json.loads((ROOT / "data/civilization_catalog.json").read_text(encoding="utf-8"))
    exported = {}

    def sheet(graphic_id, key, *, shadow=False):
        if graphic_id not in exported:
            exported[graphic_id] = export_graphic(graphics[graphic_id], resources, args.out, key, shadow=shadow)
        return exported[graphic_id]

    result = {
        "schema_version": 1,
        "source": {
            "edition": "Age of Empires II HD / The Conquerors base data",
            "dat": "resources/_common/dat/empires2_x1_p1.dat",
            "dat_version": dat.versionstr,
            "sha256": hashlib.sha256(dat_path.read_bytes()).hexdigest(),
            "distance_units": "original DAT tiles, before runtime conversion",
            "time_units": "simulation seconds",
            "arc_units": "radians, with the original signed DAT value preserved",
            "notes": [
                "Includes arrows and skirmisher javelins; gunpowder, scorpion bolts and siege stones are outside this profile.",
                "Town centers use projectile_id1 because their primary projectile_id0 is -1.",
                "Flight art excludes DAT shadow deltas; ground shadows are exported independently.",
                "DAT does not store the engine ballistic equation or numerical pitch angles for SLP poses.",
                "Archer and javelin arc is -0.06; defensive building arrow arc is +0.05. Runtime must preserve source data and document any trajectory approximation.",
                "Release delay is frame_delay multiplied by the attack graphic frame_rate, following the openage AOC ability converter.",
            ],
        },
        "units": {},
        "buildings": {},
    }
    for category in ("units", "buildings"):
        for key, source_record in current[category].items():
            unit = units.get(source_record["source_id"])
            projectile_id = getattr(unit, "projectile_id0", -1)
            if projectile_id < 0:
                projectile_id = getattr(unit, "projectile_id1", -1)
            projectile = units.get(projectile_id)
            if projectile is None or projectile.idle_graphic0 not in FLIGHT_GRAPHICS:
                continue
            graphic = graphics[projectile.idle_graphic0]
            attack_graphic = graphics.get(unit.attack_sprite_id)
            name = FLIGHT_GRAPHICS[graphic.graphic_id]
            record = {
                "source_id": unit.id0,
                "projectile_source_id": projectile_id,
                "projectile_kind": "arrow",
                "projectile_visual_kind": "javelin" if name.endswith("javelin") else "arrow",
                "flight_graphic_id": graphic.graphic_id,
                "attack_range": number(unit.weapon_range_max),
                "min_range": number(unit.weapon_range_min),
                "cooldown": number(unit.attack_speed),
                "speed": number(projectile.speed),
                "arc": number(projectile.projectile_arc),
                "weapon_offset": [number(value) for value in unit.weapon_offset],
                "launch_height": number(unit.weapon_offset[2]),
                "release_delay": number(unit.frame_delay * attack_graphic.frame_rate) if attack_graphic else 0.0,
                "attack_frame_delay": int(unit.frame_delay),
                "attack_frame_duration": number(attack_graphic.frame_rate) if attack_graphic else 0.0,
                "accuracy": int(unit.accuracy),
                "accuracy_dispersion": number(unit.accuracy_dispersion),
                "smart_mode": int(projectile.smart_mode),
                "drop_animation_mode": int(projectile.drop_animation_mode),
                "flight_sheet": sheet(graphic.graphic_id, name),
            }
            for delta in graphic.graphic_deltas:
                if delta.graphic_id >= 0:
                    record["shadow_sheet"] = sheet(delta.graphic_id, name + "_shadow", shadow=True)
            result[category][key] = record
    args.catalog.parent.mkdir(parents=True, exist_ok=True)
    args.catalog.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"Imported {len(result['units'])} units, {len(result['buildings'])} buildings, {len(exported)} original graphic sheets")


if __name__ == "__main__":
    main()
