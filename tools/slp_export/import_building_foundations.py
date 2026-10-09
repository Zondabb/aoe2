#!/usr/bin/env python3
"""Import original HD construction foundations for the playable land buildings.

Keep the first construction stage throughout construction. Ordinary buildings
and walls use their DAT construction_graphic_id, with source hotspots and
indexed player colors intact. A gate uses four original one-tile foundations
because its DAT construction graphic already includes raised gate pillars.
Farms use original terrain 29 (Farm Cnst1), before sowing or completed crops.
"""
from __future__ import annotations

import argparse
from functools import lru_cache
import hashlib
import json
from pathlib import Path

from PIL import Image

from export_sprites import _read_slp, composite_hotspot_images, load_config, pack_sheet
from import_civilizations import AGE_KEYS, CIVS, read_dat
from player_color import composite_player_masks, pack_masks, save_player_mask


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OPENAGE = Path("D:/Users/jiangzw/workspace/openage_workspace/openage")
# CNST8_NN is the historical graphic name; wonder's DAT footprint is 5 x 5.
DEFAULT_GRAPHICS = {"1": 118, "2": 119, "3": 120, "4": 121, "5": 123}


class FoundationExporter:
    def __init__(self, dat, resources, out):
        self.graphics = {g.graphic_id: g for g in dat.graphics}
        self.resources, self.out = resources, out.resolve()
        self.out.mkdir(parents=True, exist_ok=True)
        self.cache, self.report = {}, []

    @lru_cache(maxsize=24)
    def slp(self, slp_id):
        return _read_slp(self.resources, slp_id, 1)

    def save(self, key, image, mask, hotspot, **details):
        if not image.getchannel("A").getbbox():
            raise ValueError(f"Empty foundation: {key}")
        atlas, cols, rows, fw, fh, pads = pack_sheet([image])
        atlas.save(self.out / f"{key}.png")
        mask_atlas = pack_masks([mask], atlas.size, cols, fw, fh, pads)
        color = save_player_mask(mask_atlas, self.out, key, 1)
        meta = dict(
            key=key, cols=cols, rows=rows, frame_w=fw, frame_h=fh,
            frame_count=1, source_frame_count=1, directions=1,
            frames_per_direction=1, construction_stage=0,
            hotspots=[{"x": hotspot[0] + pads[0]["x"], "y": hotspot[1] + pads[0]["y"]}],
            player_color=color, **details,
        )
        (self.out / f"{key}.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
        base = "res://" + (self.out / key).relative_to(ROOT).as_posix()
        self.report.append(dict(key=key, path=base, width=fw, height=fh,
                                alpha_pixels=sum(image.getchannel("A").histogram()[1:])))
        return base

    def graphic(self, graphic_id):
        if graphic_id in self.cache:
            return self.cache[graphic_id]
        graphic = self.graphics[graphic_id]
        refs = [(graphic, 0, 0)] + [
            (self.graphics[d.graphic_id], d.offset_x, d.offset_y)
            for d in graphic.graphic_deltas if d.graphic_id in self.graphics
        ]
        priority = {"TERRAIN": 0, "SHADOW": 1, "UNIT_LOW": 2}
        refs.sort(key=lambda x: priority.get(x[0].layer, 3))
        parts, masks, sources, empty = [], [], [], []
        for part, x, y in refs:
            frames, metas, player_masks, source, palette = self.slp(part.slp_id)
            # Wall stage zero shadows contain a transparent 1 x 1 placeholder
            # with a large dummy hotspot. Exclude it before compositing so it
            # cannot needlessly inflate the otherwise small foundation atlas.
            if not frames[0].getchannel("A").getbbox():
                empty.append(part.graphic_id)
                continue
            parts.append((frames[0], metas[0].hotspot_x, metas[0].hotspot_y, x, y))
            masks.append(player_masks[0])
            sources.append(dict(graphic_id=part.graphic_id, slp_id=part.slp_id,
                                frame=0, x=x, y=y, layer=part.layer,
                                source=Path(source).relative_to(self.resources).as_posix(),
                                palette=Path(palette).relative_to(self.resources).as_posix()))
        image, hx, hy = composite_hotspot_images(parts)
        mask = composite_player_masks(parts, masks, image, hx, hy)
        base = self.save(f"g{graphic_id}_static", image, mask, (hx, hy),
                         graphic_id=graphic_id, slp_id=graphic.slp_id,
                         source="AoE2 HD DAT construction graphic, first SLP stage",
                         includes_shadow=any(s["layer"] == "SHADOW" for s in sources),
                         layers=sources, skipped_empty_graphics=empty,
                         missing_slp_ids=[])
        self.cache[graphic_id] = base
        return base

    def gate(self):
        frames, metas, masks, source, palette = self.slp(self.graphics[118].slp_id)
        # DAT gate 487 occupies 4 x 1 original tiles. Tile centers project onto
        # the 96 x 48 original isometric grid, centered on the gate hotspot.
        parts = [(frames[0], metas[0].hotspot_x, metas[0].hotspot_y,
                  round((i - 1.5) * 48), round((i - 1.5) * 24)) for i in range(4)]
        image, hx, hy = composite_hotspot_images(parts)
        mask = composite_player_masks(parts, [masks[0]] * 4, image, hx, hy)
        return self.save("gate_ground", image, mask, (hx, hy), includes_shadow=False,
                         source="AoE2 HD construction graphic 118 / SLP 236",
                         derived_composite=True, footprint=[4, 1],
                         notes="Four unmodified first-stage one-tile foundations; excludes raised gate pillars.",
                         layers=[dict(graphic_id=118, slp_id=236, frame=0, x=p[3], y=p[4]) for p in parts])

    def farm(self):
        source = self.resources / "_common/terrain/textures/g_fc1_00_color.png"
        # Match the existing farm_ground atlas projection and hotspot so the
        # ground texture does not jump or resize when construction completes.
        texture = Image.open(source).convert("RGBA").resize((192, 192), Image.Resampling.NEAREST)
        image = texture.transform((384, 192), Image.Transform.AFFINE,
                                  (0.5, 1, -96, -0.5, 1, 96), Image.Resampling.NEAREST)
        mask = Image.new("RGBA", image.size, (0, 0, 0, 0))
        return self.save("farm_construction_ground", image, mask, (192, 96),
                         includes_shadow=False, terrain_source_id=29,
                         source=source.relative_to(self.resources).as_posix(),
                         derived_composite=True, footprint=[3, 3],
                         notes="Original Farm Cnst1 terrain; same affine projection as the completed farm atlas.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=Path)
    parser.add_argument("--openage", type=Path, default=DEFAULT_OPENAGE)
    parser.add_argument("--buildings", type=Path, default=ROOT / "data/civilization_catalog.json")
    parser.add_argument("--out", type=Path, default=ROOT / "assets/sprites/foundations")
    parser.add_argument("--catalog", type=Path, default=ROOT / "data/building_foundations.json")
    args = parser.parse_args()
    resources = (args.resources or Path(load_config(None)["aoe2_resources"])).resolve()
    dat_path = resources / "_common/dat/empires2_x1_p1.dat"
    dat, _length = read_dat(dat_path, args.openage)
    units_by_civ = {civ: {u.id0: u for rows in dat.civs[cid].units.values() for u in rows}
                    for civ, cid in CIVS.items()}
    buildings = json.loads(args.buildings.read_text(encoding="utf-8"))["buildings"]
    age_changes = {a: {e.attr_a: e.attr_b for e in dat.effect_bundles[tid].effects if e.type_id == "UNIT_UPGRADE"}
                   for a, tid in enumerate([104, 101, 102, 103])}
    exporter = FoundationExporter(dat, resources, args.out)
    defaults = {size: exporter.graphic(gid) for size, gid in DEFAULT_GRAPHICS.items()}
    gate, farm = exporter.gate(), exporter.farm()
    records = {}
    for key, original in buildings.items():
        uid = 621 if original["source_id"] == 109 else original["source_id"]
        record = dict(source_id=original["source_id"], construction_source_id=uid,
                      footprint=original["footprint"], sprites={}, construction_graphics={})
        for civ in original["civilizations"]:
            record["sprites"][civ], record["construction_graphics"][civ] = {}, {}
            for age, _name in enumerate(AGE_KEYS):
                variant_id = age_changes[age].get(uid, uid)
                unit = units_by_civ[civ][variant_id]
                gid = unit.construction_graphic_id
                if key == "farm":
                    base = farm
                elif key == "gate":
                    base = gate
                else:
                    if gid < 0:
                        raise ValueError(f"Missing construction graphic: {key}/{civ}/{age}")
                    base = exporter.graphic(gid)
                record["sprites"][civ][str(age)] = base
                record["construction_graphics"][civ][str(age)] = gid
        records[key] = record
    catalog = dict(schema_version=1, source=dict(
        edition="Age of Empires II HD / The Conquerors base data",
        dat="resources/_common/dat/empires2_x1_p1.dat", dat_version=dat.versionstr,
        sha256=hashlib.sha256(dat_path.read_bytes()).hexdigest(),
        stage="First construction stage, retained until construction completes",
        footprint_units="Original DAT footprint tiles, matching the existing building definitions",
        notes=["Gate ground uses four original one-tile foundations to keep all raised structures hidden until completion.",
               "Farm uses original terrain 29 Farm Cnst1 before completed crops.",
               "Graphic CNST8_NN (123) is used by the 5 x 5 wonder; its name is not its footprint size.",
               "Transparent wall-shadow placeholders are omitted; source hotspots remain intact."]),
        defaults=defaults, buildings=records)
    args.catalog.parent.mkdir(parents=True, exist_ok=True)
    args.catalog.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (exporter.out / "import_report.json").write_text(json.dumps(exporter.report, indent=2) + "\n", encoding="utf-8")
    print(f"Exported {len(exporter.report)} foundation sheets for {len(records)} building types")


if __name__ == "__main__":
    main()
