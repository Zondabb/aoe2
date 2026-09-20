#!/usr/bin/env python3
"""Rebuild project SLP assets, including existing derived archer previews."""

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image

from export_sprites import (
    ROOT, export_combat, export_one,
    export_priority, export_ui, load_config,
)


def scale2x(image):
    """Edge-aware 2x pixel-art scaling; compare complete RGBA pixels."""
    e = np.asarray(image.convert('RGBA'))
    p = np.pad(e, ((1, 1), (1, 1), (0, 0)), mode='edge')
    b, d, f, h = p[:-2, 1:-1], p[1:-1, :-2], p[1:-1, 2:], p[2:, 1:-1]
    same = lambda a, b: np.all(a == b, axis=2)
    edge = ~same(b, h) & ~same(d, f)
    out = np.empty((e.shape[0] * 2, e.shape[1] * 2, 4), dtype=np.uint8)
    for y, x, first, second in ((0, 0, d, b), (0, 1, b, f),
                                (1, 0, d, h), (1, 1, h, f)):
        out[y::2, x::2] = np.where((edge & same(first, second))[..., None], first, e)
    return Image.fromarray(out)


def rebuild_archer_previews(out, original):
    units = out / 'units'
    old_units = original / 'units'
    generated = []
    with Image.open(units / 'archer_walk.png') as source:
        sheet = source.convert('RGBA')
    meta = json.loads((units / 'archer_walk.json').read_text())
    if (old_units / 'archer_walk_transparent_1x.png').exists():
        sheet.save(units / 'archer_walk_transparent_1x.png')
        generated.append('units/archer_walk_transparent_1x.png')
    if (old_units / 'archer_walk_HD_4x.json').exists():
        hd = scale2x(scale2x(sheet))
        hd.save(units / 'archer_walk_HD_4x.png')
        hd_meta = dict(meta, key='archer_walk_HD_4x',
                       note=meta['note'] + ' | 4x Scale2x upscale, transparent bg',
                       frame_w=meta['frame_w'] * 4, frame_h=meta['frame_h'] * 4,
                       hotspots=[{k: v * 4 for k, v in h.items()} for h in meta['hotspots']],
                       source_png='archer_walk_HD_4x.png')
        (units / 'archer_walk_HD_4x.json').write_text(json.dumps(hd_meta, indent=2))
        generated.append('units/archer_walk_HD_4x.png')
    frame_manifest = old_units / 'archer_walk_frames_4x/frames.json'
    if frame_manifest.exists():
        manifest = json.loads(frame_manifest.read_text())
        target = units / 'archer_walk_frames_4x'
        target.mkdir(parents=True, exist_ok=True)
        for i, entry in enumerate(manifest['frames']):
            x = (i % meta['cols']) * meta['frame_w']
            y = (i // meta['cols']) * meta['frame_h']
            frame = sheet.crop((x, y, x + meta['frame_w'], y + meta['frame_h']))
            enlarged = scale2x(scale2x(frame))
            filename = Path(entry['file']).name
            enlarged.save(target / filename)
            entry['size'] = list(enlarged.size)
            entry['hotspot'] = [meta['hotspots'][i][k] * 4 for k in ('x', 'y')]
            generated.append('units/archer_walk_frames_4x/' + filename)
        manifest['source'] = str((original / 'units/archer_walk.png').resolve())
        manifest['frame_size_1x'] = [meta['frame_w'], meta['frame_h']]
        manifest['frame_size_4x'] = [meta['frame_w'] * 4, meta['frame_h'] * 4]
        (target / 'frames.json').write_text(json.dumps(manifest, indent=2))
    return generated


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path)
    parser.add_argument('--out', type=Path, default=ROOT / 'assets/sprites')
    parser.add_argument('--player', type=int, choices=range(1, 9))
    args = parser.parse_args()
    cfg = load_config(args.config)
    resources = Path(cfg['aoe2_resources'])
    player = args.player if args.player is not None else int(cfg.get('player_color', 1))
    original = ROOT / 'assets/sprites'
    # Read extra source manifests before any output overwrites them.
    extras = []
    known = {'tc_asian_feudal', 'archer_walk_HD_4x'}
    from export_sprites import PRIORITY, COMBAT_PRIORITY, UI_PRIORITY
    known.update(item['key'] for item in PRIORITY + COMBAT_PRIORITY + UI_PRIORITY)
    for path in sorted(original.glob('*/*.json')):
        meta = json.loads(path.read_text())
        if 'slp_id' in meta and meta['key'] not in known:
            extras.append((path.parent.name, meta))
    args.out.mkdir(parents=True, exist_ok=True)
    reports = [export_priority(resources, args.out, player),
               export_combat(resources, args.out, player),
               export_ui(resources, args.out, player)]
    exported = [item for report in reports for item in report['exported']]
    failures = [item for report in reports for item in report['missing']]
    for category, meta in extras:
        palette_file = Path(meta['palette']).name
        palette = 'interface' if palette_file == '50500.bina' else Path(palette_file).stem
        try:
            item = export_one(resources=resources, out_dir=args.out,
                              file_id=meta['slp_id'], key=meta['key'], category=category,
                              directions=meta['directions'], palette_name=palette,
                              player=player, note=meta.get('note', ''),
                              max_frames=meta.get('frame_count'))
            exported.append({k: item[k] for k in ('key', 'slp_id', 'frame_count')})
            print('OK extra', meta['key'])
        except Exception as exc:
            failures.append({'key': meta['key'], 'error': str(exc)})
    derived = []
    if not failures:
        derived = rebuild_archer_previews(args.out, original)
    report = dict(player_color=player, exported=exported, missing=failures,
                  derived_images=derived, debug_preview='buildings/tc_asian_feudal_green.jpg')
    (args.out / 'regenerate_report.json').write_text(json.dumps(report, indent=2))
    print(f'TOTAL: {len(exported)} sprite sheets, {len(derived)} derived images, {len(failures)} failures')
    return int(bool(failures))


if __name__ == '__main__':
    raise SystemExit(main())
