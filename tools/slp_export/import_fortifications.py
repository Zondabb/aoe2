#!/usr/bin/env python3
"""Import unmodified HD wall shapes and four closed/open gate composites.

Walls have five adjacency shapes, not five animation directions. Gate previews
contain both pillars plus a closed centre; replace only the centre's DAT layers
with its open-unit layers. Never rotate or paint the original pixels.
"""
from __future__ import annotations

import argparse
from functools import lru_cache
import hashlib
import json
from pathlib import Path

from export_sprites import _read_slp, composite_hotspot_images, load_config, pack_sheet
from import_civilizations import CIVS, read_dat
from player_color import composite_player_masks, pack_masks, save_player_mask

ROOT = Path(__file__).resolve().parents[2]
WALLS = {"palisade_wall": 72, "stone_wall": 117, "fortified_wall": 155}
# Simulation axes: +X, +X+Y, +Y, -X+Y. Source shapes: /, \, post, horizontal, vertical.
WALL_FRAMES = [1, 4, 0, 3]
# Preview unit, closed centre, open centre, indexed by the same four axes.
GATES = [(490, 88, 91), (673, 667, 669), (487, 64, 78), (665, 659, 661)]
# Absent overlay/container SLPs verified against this HD base DAT. Do not hide
# missing real N1 artwork (e.g. the palisade's timber layer is itself N1).
EMPTY_OVERLAYS = {2219, 2220, 1922, 1923, 2351, 2352, 2423, 2424, 2459, 2460,
                  3995, 3996, 4019, 4020, 4083, 4084, 4107, 4108}


class FortificationExporter:
    def __init__(self, dat, resources, out):
        self.graphics = {g.graphic_id: g for g in dat.graphics}
        self.resources, self.out = resources, out.resolve()
        self.out.mkdir(parents=True, exist_ok=True)
        self.report = []

    @lru_cache(maxsize=48)
    def slp(self, sid):
        return _read_slp(self.resources, sid, 1)

    def refs(self, gid):
        graphic = self.graphics[gid]
        return [(graphic, 0, 0)] + [(self.graphics[d.graphic_id], d.offset_x, d.offset_y)
                                  for d in graphic.graphic_deltas if d.graphic_id in self.graphics]

    def composite(self, refs, shape=0, stage=0):
        parts, masks, sources, skipped = [], [], [], []
        # Keep the original ordering of solid layers (rear pillar, door, front pillar).
        refs = sorted(refs, key=lambda r: 0 if r[0].layer == 'SHADOW' else 1)
        for graphic, x, y in refs:
            try:
                frames, metas, player_masks, source, _ = self.slp(graphic.slp_id)
            except FileNotFoundError:
                # This edition omits its N1 overlay placeholders and gate-preview
                # containers. A missing actual masonry/timber/door is an error.
                if graphic.slp_id not in EMPTY_OVERLAYS:
                    raise
                skipped.append(dict(graphic_id=graphic.graphic_id, slp_id=graphic.slp_id, reason='absent overlay/container'))
                continue
            index = shape * max(1, graphic.frame_count) + min(stage, max(0, graphic.frame_count - 1))
            if index >= len(frames):
                raise ValueError(f'{graphic.name}: missing shape/stage {index}')
            if not frames[index].getchannel('A').getbbox():
                skipped.append(dict(graphic_id=graphic.graphic_id, slp_id=graphic.slp_id, frame=index, reason='transparent placeholder'))
                continue
            meta = metas[index]
            parts.append((frames[index], meta.hotspot_x, meta.hotspot_y, x, y))
            masks.append(player_masks[index])
            sources.append(dict(graphic_id=graphic.graphic_id, slp_id=graphic.slp_id, frame=index,
                                x=x, y=y, layer=graphic.layer,
                                source=Path(source).relative_to(self.resources).as_posix()))
        if not parts or not any(s['layer'] != 'SHADOW' for s in sources):
            raise ValueError('No visible original layers')
        image, hx, hy = composite_hotspot_images(parts)
        mask = composite_player_masks(parts, masks, image, hx, hy)
        return image, mask, (hx, hy), dict(layers=sources, skipped=skipped)

    def save(self, key, frames, **details):
        images, masks, hotspots, provenance = zip(*frames)
        atlas, cols, rows, fw, fh, pads = pack_sheet(images)
        atlas.save(self.out / f'{key}.png')
        mask_atlas = pack_masks(masks, atlas.size, cols, fw, fh, pads)
        color = save_player_mask(mask_atlas, self.out, key, 1)
        meta = dict(key=key, source='AoE2 HD DAT + original SLP pixels', cols=cols, rows=rows,
                    frame_w=fw, frame_h=fh, frame_count=len(frames), directions=1,
                    frames_per_direction=len(frames), includes_shadow=True, player_color=color,
                    hotspots=[dict(x=h[0]+p['x'], y=h[1]+p['y']) for h,p in zip(hotspots,pads)],
                    content_bounds=[dict(x=im.getbbox()[0]+p['x'], y=im.getbbox()[1]+p['y'],
                                         w=im.getbbox()[2]-im.getbbox()[0], h=im.getbbox()[3]-im.getbbox()[1])
                                    for im,p in zip(images,pads)],
                    frames=provenance, **details)
        (self.out / f'{key}.json').write_text(json.dumps(meta, indent=2)+'\n', encoding='utf-8')
        base = 'res://' + (self.out / key).relative_to(ROOT).as_posix()
        self.report.append(dict(path=base, frames=len(frames)))
        return base

    def wall(self, unit, key):
        complete = self.save(key, [self.composite(self.refs(unit.idle_graphic0), shape) for shape in range(5)],
                             graphic_id=unit.idle_graphic0, orientation_frames=WALL_FRAMES, post_frame=2)
        # One-tile palisade foundation has 3 construction phases, not 5 wall shapes.
        if unit.id0 == 72:
            foundation = self.save(key+'_construction', [self.composite(self.refs(unit.construction_graphic_id))])
            stages = 1
        else:
            stages = 4
            foundation = self.save(key+'_construction', [self.composite(self.refs(unit.construction_graphic_id), shape, stage)
                                                         for shape in range(5) for stage in range(stages)])
        return dict(complete=complete, construction=foundation, construction_stages=stages,
                    construction_shapes=1 if unit.id0 == 72 else 5)

    def gate(self, units, key):
        frames = []
        for preview_id, closed_id, open_id in GATES:
            preview, closed, opened = [units[uid] for uid in (preview_id, closed_id, open_id)]
            refs = self.refs(preview.idle_graphic0)
            frames.append(self.composite(refs))
            # A preview already lists direct layers of the centre. Replace those
            # by identity; do not recurse through damage/snow deltas or repaint it.
            closed_refs = {g.graphic_id for g, _, _ in self.refs(closed.idle_graphic0)}
            open_refs = self.refs(opened.idle_graphic0)
            replacement = {g.name.replace('B2', 'A2', 1): g for g, _, _ in open_refs}
            opened_refs = []
            for g, x, y in refs:
                if g.graphic_id in closed_refs and x == 0 and y == 0:
                    g = replacement[g.name]
                opened_refs.append((g, x, y))
            frames.append(self.composite(opened_refs))
        return self.save(key, frames, orientation_frames=[[i*2, i*2+1] for i in range(4)],
                         gate_units=GATES, states=['closed', 'open'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resources', type=Path)
    parser.add_argument('--openage', type=Path, required=True)
    parser.add_argument('--out', type=Path, default=ROOT/'assets/sprites/fortifications')
    parser.add_argument('--manifest', type=Path, default=ROOT/'data/fortification_sprites.json')
    args = parser.parse_args()
    resources = (args.resources or Path(load_config(None)['aoe2_resources'])).resolve()
    path = resources/'_common/dat/empires2_x1_p1.dat'
    dat, _ = read_dat(path, args.openage)
    exporter = FortificationExporter(dat, resources, args.out)
    civilizations = {}
    palisade = None
    for name, cid in CIVS.items():
        units = {u.id0:u for rows in dat.civs[cid].units.values() for u in rows}
        records = {}
        for key, uid in WALLS.items():
            if uid == 72 and palisade is not None:
                records[key] = palisade
            else:
                records[key] = exporter.wall(units[uid], key if uid == 72 else name+'_'+key)
                if uid == 72: palisade = records[key]
        records['gate'] = dict(complete=exporter.gate(units, name+'_gate'))
        civilizations[name] = records
    # A gate under construction covers four original 1-tile foundation sprites;
    # the runtime positions them on its actual axis with unchanged source pixels.
    foundation = exporter.save('gate_foundation_tile', [exporter.composite(exporter.refs(118))])
    manifest = dict(schema_version=1, source=dict(edition='Age of Empires II HD / The Conquerors',
                    dat='resources/_common/dat/empires2_x1_p1.dat', dat_version=dat.versionstr,
                    sha256=hashlib.sha256(path.read_bytes()).hexdigest()),
                    source_tile_half=[48,24], orientation_frames=WALL_FRAMES, post_frame=2,
                    gate_foundation_tile=foundation, civilizations=civilizations)
    args.manifest.write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(exporter.report,indent=2))


if __name__ == '__main__': main()
