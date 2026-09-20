#!/usr/bin/env python3
"""Export AoE2 HD SLP sprites to PNG sheets + JSON metadata."""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

from PIL import Image

from drs import extract
from palette import load_pal
from slp import decode_with_meta

ROOT = Path(__file__).resolve().parents[2]  # aoe2/
TOOLS_DIR = Path(__file__).resolve().parent
DEFAULT_CONFIG = TOOLS_DIR / "config.json"
EXAMPLE_CONFIG = TOOLS_DIR / "config.example.json"

# Priority demo assets (IDs from openage aoc-slp-list / HD graphics folder).
# Classic AoE unit SLPs author 5 facing directions; mirror (flip X) for the other 3.
PRIORITY: List[Dict[str, Any]] = [
    {"key": "villager_walk", "category": "units", "id": 1484, "directions": 5, "note": "Male villager moving"},
    {"key": "villager_idle", "category": "units", "id": 1479, "directions": 5, "note": "Male villager standing"},
    {"key": "villager_gather_food", "category": "units", "id": 2589, "directions": 5, "note": "Male villager kneeling picking berries"},
    {"key": "villager_chop", "category": "units", "id": 1535, "directions": 5, "note": "Male villager woodcutter chopping"},
    {"key": "villager_mine", "category": "units", "id": 1560, "directions": 5, "note": "Male villager miner mining"},
    {"key": "villager_build", "category": "units", "id": 1496, "directions": 5, "note": "Male villager builder kneeling"},
    {"key": "militia_walk", "category": "units", "id": 997, "directions": 5, "note": "Militia / swordsman tier moving"},
    {"key": "swordsman_walk", "category": "units", "id": 604, "directions": 5, "note": "ROR swordsman moving"},
    {"key": "archer_walk", "category": "units", "id": 12, "directions": 5, "note": "Archer moving"},
    {"key": "chu_ko_nu_walk", "category": "units", "id": 225, "directions": 5, "note": "Chu-Ko-Nu moving"},
    {"key": "teutonic_knight_walk", "category": "units", "id": 1198, "directions": 5, "note": "Teutonic knight moving"},
    {"key": "tc_dark_main", "category": "buildings", "id": 891, "directions": 1, "note": "Dark Age TC main top (single layer)"},
    {"key": "house_dark", "category": "buildings", "id": 2223, "directions": 1, "note": "Dark Age houses"},
    {"key": "house_asian_feudal", "category": "buildings", "id": 2233, "directions": 1, "note": "Asian feudal houses"},
    {"key": "barracks_asian_feudal", "category": "buildings", "id": 131, "directions": 1, "note": "Asian barracks feudal"},
    {"key": "archery_asian_feudal", "category": "buildings", "id": 22, "directions": 1, "note": "Asian archery feudal"},
    {"key": "stable_asian_feudal", "category": "buildings", "id": 1007, "directions": 1, "note": "Asian stable feudal"},
    {"key": "stable_ne_feudal", "category": "buildings", "id": 1006, "directions": 1, "note": "North European stable feudal (Teutons)"},
    {"key": "tree_oak", "category": "resources", "id": 1251, "directions": 1, "palette": "pal_2", "note": "Oak tree (pal_2)"},
    {"key": "gold_mine", "category": "resources", "id": 4479, "directions": 1, "note": "Gold mine"},
    {"key": "berry_bush", "category": "resources", "id": 2560, "directions": 1, "note": "Berry bush / food"},
    {"key": "water_shallow", "category": "terrain", "id": 1885, "directions": 1, "note": "Water shallows tiles"},
    {"key": "cliff_main", "category": "terrain", "id": 226, "directions": 1, "note": "Cliffs"},
    {"key": "cliff_section", "category": "terrain", "id": 229, "directions": 1, "note": "Cliff section"},
    {"key": "cliff_section_b", "category": "terrain", "id": 230, "directions": 1, "note": "Cliff section B"},
]

# Asian feudal Town Center: decode these SLPs and bake one standing PNG (back → front).
# Original HD DAT composite graphic 3347: main -48px, base/shadow 0px,
# middle supports +24px, roofs +48px. Normalize around the main hotspot:
# 0/48/72/96px. Do not add the former 0.1-tile bias: it opens a 5px seam.
# See tc_layout.md for the graphic-delta records read with openage.
AOE2_TILE_W = 96
AOE2_TILE_H = 48
TC_WING_TILE = (2.0, 2.0)
TC_ASIAN_FEUDAL_LAYERS: List[Dict[str, Any]] = [
    {"key": "shadow", "id": 893, "tile": (1.0, 1.0)},
    {"key": "left_support", "id": 3606, "tile": (1.0, 1.0)},
    {"key": "far_right_support", "id": 4622, "tile": (1.0, 1.0)},
    {"key": "top", "id": 901, "tile": (0.0, 0.0)},
    {"key": "left_roof_supports", "id": 3602, "tile": (1.5, 1.5)},
    {"key": "right_roof_supports", "id": 4618, "tile": (1.5, 1.5)},
    {"key": "left_roof", "id": 3598, "tile": TC_WING_TILE},
    {"key": "right_roof", "id": 4614, "tile": TC_WING_TILE},
]

COMBAT_PRIORITY: List[Dict[str, Any]] = [
    {"key": "archer_attack", "category": "units", "id": 2, "directions": 5, "note": "Archer firing"},
    {"key": "archer_die", "category": "units", "id": 5, "directions": 5, "note": "Archer dying"},
    {"key": "swordsman_attack", "category": "units", "id": 594, "directions": 5, "note": "ROR swordsman fighting"},
    {"key": "swordsman_die", "category": "units", "id": 597, "directions": 5, "note": "ROR swordsman dying"},
    {"key": "chu_ko_nu_attack", "category": "units", "id": 215, "directions": 5, "note": "Chu-Ko-Nu attacking"},
    {"key": "chu_ko_nu_die", "category": "units", "id": 218, "directions": 5, "note": "Chu-Ko-Nu dying"},
    {"key": "teutonic_knight_attack", "category": "units", "id": 1188, "directions": 5, "note": "Teutonic knight fighting"},
    {"key": "teutonic_knight_die", "category": "units", "id": 1191, "directions": 5, "note": "Teutonic knight dying"},
    {"key": "villager_die", "category": "units", "id": 3683, "directions": 5, "note": "Male villager dying"},
    {"key": "arrow", "category": "units", "id": 3799, "directions": 1, "note": "Arrow projectile"},
]

UI_PRIORITY: List[Dict[str, Any]] = [
    {"key": "panel_game", "category": "ui", "id": 51141, "directions": 1, "note": "Large game panel strip"},
    {"key": "icons_units", "category": "ui", "id": 50730, "directions": 1, "note": "Unit icons"},
    {"key": "icons_buildings", "category": "ui", "id": 50705, "directions": 1, "note": "Building icons"},
    {"key": "icons_commands", "category": "ui", "id": 50721, "directions": 1, "note": "Command icons"},
]


def load_config(path: Optional[Path]) -> Dict[str, Any]:
    cfg_path = path or (DEFAULT_CONFIG if DEFAULT_CONFIG.is_file() else EXAMPLE_CONFIG)
    return json.loads(cfg_path.read_text(encoding="utf-8"))


def resolve_palette(resources: Path, name: str = "interface") -> Path:
    if name == "interface":
        return resources / "_common" / "drs" / "interface" / "50500.bina"
    if name.startswith("pal_"):
        return resources / "_common" / "dat" / f"{name}.pal"
    if name == "clf_pal":
        return resources / "_common" / "dat" / "clf_pal.pal"
    candidate = Path(name)
    if candidate.is_file():
        return candidate
    raise FileNotFoundError(f"unknown palette {name}")


def pack_sheet(
    frames: Sequence[Image.Image],
) -> tuple[Image.Image, int, int, int, int, List[Dict[str, int]]]:
    """Pack frames into a grid. Each cell is max(w)×max(h); content is centered X, bottom-aligned Y.

    Returns pad offsets per frame (relative to cell top-left) so hotspots can be remapped
    from original-frame space into cell space.
    """
    if not frames:
        raise ValueError("no frames")
    frame_w = max(im.width for im in frames)
    frame_h = max(im.height for im in frames)
    n = len(frames)
    cols = int(math.ceil(math.sqrt(n)))
    rows = int(math.ceil(n / cols))
    sheet = Image.new("RGBA", (cols * frame_w, rows * frame_h), (0, 0, 0, 0))
    pads: List[Dict[str, int]] = []
    for i, im in enumerate(frames):
        c, r = i % cols, i // cols
        pad_x = (frame_w - im.width) // 2
        pad_y = frame_h - im.height
        ox = c * frame_w + pad_x
        oy = r * frame_h + pad_y
        sheet.paste(im, (ox, oy))
        pads.append({"x": pad_x, "y": pad_y})
    return sheet, cols, rows, frame_w, frame_h, pads


def _read_slp(resources: Path, file_id: int, player: int, palette_name: str = "interface"):
    graphics = resources / "_common" / "drs" / "graphics"
    interface = resources / "_common" / "drs" / "interface"
    loose_slp = resources / "_common" / "slp"
    pal_path = resolve_palette(resources, palette_name)
    palette = load_pal(pal_path)
    data: Optional[bytes] = None
    source = ""
    for base in (graphics, interface, loose_slp):
        try:
            data = extract(base, file_id, ext="slp")
            source = str(base / f"{file_id}.slp")
            break
        except (FileNotFoundError, KeyError):
            continue
    if data is None:
        raise FileNotFoundError(f"SLP {file_id} not found under graphics/interface/slp")
    frames, metas = decode_with_meta(data, palette, player=player)
    if not frames:
        raise ValueError(f"SLP {file_id} has no frames")
    return frames, metas, source, pal_path


def tile_to_screen_px(tile_x: float, tile_y: float) -> tuple[int, int]:
    """AoE2 2:1 iso: +X NE, +Y SE; +X/+Y moves down the screen (toward camera)."""
    sx = int(round((tile_x - tile_y) * (AOE2_TILE_W / 2.0)))
    sy = int(round((tile_x + tile_y) * (AOE2_TILE_H / 2.0)))
    return sx, sy


def composite_hotspot_images(
    parts: Sequence[tuple[Image.Image, int, int, int, int]],
) -> tuple[Image.Image, int, int]:
    """Stack images so hotspot + extra pixel offset share one origin. Returns canvas + origin."""
    min_x = min(ox - hx for _im, hx, _hy, ox, _oy in parts)
    min_y = min(oy - hy for _im, _hx, hy, _ox, oy in parts)
    max_x = max(ox - hx + im.width for im, hx, _hy, ox, _oy in parts)
    max_y = max(oy - hy + im.height for im, _hx, hy, _ox, oy in parts)
    origin_x = -min_x
    origin_y = -min_y
    canvas = Image.new("RGBA", (max_x - min_x, max_y - min_y), (0, 0, 0, 0))
    for im, hx, hy, ox, oy in parts:
        canvas.alpha_composite(im, (origin_x - hx + ox, origin_y - hy + oy))
    return canvas, origin_x, origin_y


def export_composited_asian_feudal_tc(
    resources: Path, out_dir: Path, player: int = 1
) -> Dict[str, Any]:
    parts: List[tuple[Image.Image, int, int, int, int]] = []
    layer_info: List[Dict[str, Any]] = []
    pal_path = resolve_palette(resources, "interface")
    for item in TC_ASIAN_FEUDAL_LAYERS:
        frames, metas, source, pal_path = _read_slp(resources, int(item["id"]), player)
        frame = frames[0]
        meta = metas[0]
        tile = item.get("tile", (0.0, 0.0))
        ox, oy = tile_to_screen_px(float(tile[0]), float(tile[1]))
        parts.append((frame, int(meta.hotspot_x), int(meta.hotspot_y), ox, oy))
        layer_info.append(
            {
                "key": item["key"],
                "slp_id": item["id"],
                "source": source,
                "frame_w": frame.width,
                "frame_h": frame.height,
                "hotspot": {"x": meta.hotspot_x, "y": meta.hotspot_y},
                "tile": [tile[0], tile[1]],
                "pixel_offset": {"x": ox, "y": oy},
            }
        )
    canvas, origin_x, origin_y = composite_hotspot_images(parts)
    cat_dir = out_dir / "buildings"
    cat_dir.mkdir(parents=True, exist_ok=True)
    key = "tc_asian_feudal"
    png_path = cat_dir / f"{key}.png"
    json_path = cat_dir / f"{key}.json"
    canvas.save(png_path)
    # Flatten the exported RGBA on green so shadow coverage is easy to inspect.
    debug_path = cat_dir / f"{key}_green.jpg"
    debug_background = Image.new("RGBA", canvas.size, (90, 140, 50, 255))
    debug_background.alpha_composite(canvas)
    debug_background.convert("RGB").save(debug_path, quality=100, subsampling=0)
    print(f"DEBUG green background: {debug_path}")
    out_meta = {
        "key": key,
        "slp_id": 901,
        "source": "composite",
        "palette": str(pal_path),
        "note": "Asian feudal Town Center; offsets from HD DAT composite graphic 3347, normalized to main hotspot",
        "cols": 1,
        "rows": 1,
        "frame_w": canvas.width,
        "frame_h": canvas.height,
        "frame_count": 1,
        "directions": 1,
        "frames_per_direction": 1,
        "includes_shadow": True,
        "hotspots": [{"x": origin_x, "y": origin_y}],
        "layers": layer_info,
    }
    json_path.write_text(json.dumps(out_meta, indent=2), encoding="utf-8")
    print(f"OK  {key} composite {canvas.width}x{canvas.height} hotspot=({origin_x},{origin_y})")
    return out_meta


def export_one(
    *,
    resources: Path,
    out_dir: Path,
    file_id: int,
    key: str,
    category: str,
    directions: int,
    palette_name: str = "interface",
    player: int = 1,
    max_frames: Optional[int] = None,
    note: str = "",
) -> Dict[str, Any]:
    graphics = resources / "_common" / "drs" / "graphics"
    interface = resources / "_common" / "drs" / "interface"
    loose_slp = resources / "_common" / "slp"

    pal_path = resolve_palette(resources, palette_name)
    palette = load_pal(pal_path)

    data: Optional[bytes] = None
    source = ""
    for base in (graphics, interface, loose_slp):
        try:
            data = extract(base, file_id, ext="slp")
            source = str(base / f"{file_id}.slp")
            break
        except (FileNotFoundError, KeyError):
            continue
    if data is None:
        raise FileNotFoundError(f"SLP {file_id} not found under graphics/interface/slp")

    frames, metas = decode_with_meta(data, palette, player=player, max_frames=max_frames)
    sheet, cols, rows, frame_w, frame_h, pads = pack_sheet(frames)

    cat_dir = out_dir / category
    cat_dir.mkdir(parents=True, exist_ok=True)
    png_path = cat_dir / f"{key}.png"
    json_path = cat_dir / f"{key}.json"
    sheet.save(png_path)

    # SLP hotspots are relative to the original frame top-left; remap into uniform sheet cells.
    hotspots = [
        {"x": m.hotspot_x + pads[i]["x"], "y": m.hotspot_y + pads[i]["y"]}
        for i, m in enumerate(metas)
    ]

    meta = {
        "key": key,
        "slp_id": file_id,
        "source": source,
        "palette": str(pal_path),
        "note": note,
        "cols": cols,
        "rows": rows,
        "frame_w": frame_w,
        "frame_h": frame_h,
        "frame_count": len(frames),
        "directions": directions,
        "frames_per_direction": (len(frames) // directions) if directions > 0 else len(frames),
        "hotspots": hotspots,
    }
    json_path.write_text(json.dumps(meta, indent=2), encoding="utf-8")
    return meta


def export_smoke(resources: Path, sprites_root: Path) -> Dict[str, Any]:
    """Export a small known SLP for pipeline smoke test."""
    last: Exception | None = None
    for file_id, key, directions, max_frames in (
        (50731, "ui_50731", 1, None),
        (8, "archer_stand", 5, 16),
        (12, "archer_walk", 5, 16),
    ):
        try:
            return export_one(
                resources=resources,
                out_dir=sprites_root,
                file_id=file_id,
                key=key,
                category="_smoke",
                directions=directions,
                note="smoke export",
                max_frames=max_frames,
            )
        except Exception as exc:  # noqa: BLE001
            last = exc
    raise RuntimeError(f"smoke export failed: {last}")


def export_priority(resources: Path, out_dir: Path, player: int = 1) -> Dict[str, Any]:
    results = []
    missing = []
    for item in PRIORITY:
        try:
            meta = export_one(
                resources=resources,
                out_dir=out_dir,
                file_id=item["id"],
                key=item["key"],
                category=item["category"],
                directions=item.get("directions", 1),
                palette_name=item.get("palette", "interface"),
                player=player,
                note=item.get("note", ""),
            )
            results.append(meta)
            print(f"OK  {item['key']} id={item['id']} frames={meta['frame_count']}")
        except Exception as exc:  # noqa: BLE001
            missing.append({"key": item["key"], "id": item["id"], "error": str(exc)})
            print(f"MISS {item['key']} id={item['id']}: {exc}", file=sys.stderr)

    try:
        composite_meta = export_composited_asian_feudal_tc(resources, out_dir, player=player)
        results.append(composite_meta)
    except Exception as exc:  # noqa: BLE001
        missing.append({"key": "tc_asian_feudal", "id": 901, "error": str(exc)})
        print(f"MISS tc_asian_feudal composite: {exc}", file=sys.stderr)

    report = {
        "exported": [{"key": r["key"], "slp_id": r["slp_id"], "frame_count": r["frame_count"]} for r in results],
        "missing": missing,
        "discovered_ids": PRIORITY,
        "placeholders": [
            "Asian feudal TC is composited from 893/901/3598/3602/3606/4614/4618/4622 into tc_asian_feudal.png.",
            "Unit sheets use 5 authored directions + horizontal flip for the mirrored facings.",
            "Shadow pixels use black alpha 100, matching openage's SLP export.",
        ],
    }
    report_path = out_dir / "export_report.json"
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"Wrote {report_path} ({len(results)} ok, {len(missing)} missing)")
    return report


def export_combat(resources: Path, out_dir: Path, player: int = 1) -> Dict[str, Any]:
    results = []
    missing = []
    for item in COMBAT_PRIORITY:
        try:
            meta = export_one(
                resources=resources,
                out_dir=out_dir,
                file_id=item["id"],
                key=item["key"],
                category=item["category"],
                directions=item.get("directions", 1),
                palette_name=item.get("palette", "interface"),
                player=player,
                note=item.get("note", ""),
            )
            results.append(meta)
            print(f"OK  {item['key']} id={item['id']} frames={meta['frame_count']}")
        except Exception as exc:  # noqa: BLE001
            missing.append({"key": item["key"], "id": item["id"], "error": str(exc)})
            print(f"MISS {item['key']} id={item['id']}: {exc}", file=sys.stderr)

    report = {
        "exported": [{"key": r["key"], "slp_id": r["slp_id"], "frame_count": r["frame_count"]} for r in results],
        "missing": missing,
        "discovered_ids": COMBAT_PRIORITY,
    }
    report_path = out_dir / "combat_export_report.json"
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"Wrote {report_path} ({len(results)} ok, {len(missing)} missing)")
    return report


def export_ui(resources: Path, out_dir: Path, player: int = 1) -> Dict[str, Any]:
    results = []
    missing = []
    for item in UI_PRIORITY:
        try:
            meta = export_one(
                resources=resources,
                out_dir=out_dir,
                file_id=item["id"],
                key=item["key"],
                category=item["category"],
                directions=item.get("directions", 1),
                palette_name=item.get("palette", "interface"),
                player=player,
                note=item.get("note", ""),
            )
            results.append(meta)
            print(f"OK  {item['key']} id={item['id']} frames={meta['frame_count']}")
        except Exception as exc:  # noqa: BLE001
            missing.append({"key": item["key"], "id": item["id"], "error": str(exc)})
            print(f"MISS {item['key']} id={item['id']}: {exc}", file=sys.stderr)

    report = {
        "exported": [{"key": r["key"], "slp_id": r["slp_id"], "frame_count": r["frame_count"]} for r in results],
        "missing": missing,
        "discovered_ids": UI_PRIORITY,
    }
    report_path = out_dir / "ui_export_report.json"
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"Wrote {report_path} ({len(results)} ok, {len(missing)} missing)")
    return report


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Export AoE2 HD SLP sprites to PNG")
    parser.add_argument("--config", type=Path, default=None, help="config.json path")
    parser.add_argument("--smoke", action="store_true", help="export one smoke SLP only")
    parser.add_argument("--priority", action="store_true", help="export priority demo list")
    parser.add_argument("--ui", action="store_true", help="export UI panel/icon SLPs")
    parser.add_argument("--combat", action="store_true", help="export combat animation SLPs")
    parser.add_argument("--all-default", action="store_true", help="smoke + priority (default if no mode flag)")
    parser.add_argument("--id", type=int, default=None, help="export a single SLP id")
    parser.add_argument("--key", type=str, default=None, help="output key name for --id")
    parser.add_argument("--category", type=str, default="units")
    parser.add_argument(
        "--directions",
        type=int,
        default=5,
        help="authored facing count (classic units: 5 + flip; buildings: 1)",
    )
    parser.add_argument(
        "--composite-tc",
        action="store_true",
        help="bake Asian feudal Town Center layers into one PNG",
    )
    parser.add_argument("--out", type=Path, default=ROOT / "assets" / "sprites")
    args = parser.parse_args(argv)

    cfg = load_config(args.config)
    resources = Path(cfg["aoe2_resources"])
    player = int(cfg.get("player_color", 1))
    if not resources.is_dir():
        print(f"ERROR: aoe2_resources not found: {resources}", file=sys.stderr)
        return 1

    if args.composite_tc:
        meta = export_composited_asian_feudal_tc(resources, args.out, player=player)
        print(json.dumps({k: meta[k] for k in ("key", "frame_w", "frame_h", "hotspots") if k in meta}, indent=2))
        return 0

    if args.id is not None:
        meta = export_one(
            resources=resources,
            out_dir=args.out,
            file_id=args.id,
            key=args.key or f"slp_{args.id}",
            category=args.category,
            directions=args.directions,
            player=player,
        )
        print(json.dumps(meta, indent=2))
        return 0

    if args.ui:
        report = export_ui(resources, args.out, player=player)
        return 0 if report["exported"] else 1

    if args.combat:
        report = export_combat(resources, args.out, player=player)
        return 0 if report["exported"] else 1

    run_smoke = args.smoke or args.all_default or (not args.priority and not args.smoke)
    run_priority = args.priority or args.all_default or (not args.priority and not args.smoke)

    if args.smoke and not args.priority and not args.all_default:
        run_priority = False
    if args.priority and not args.smoke and not args.all_default:
        run_smoke = False

    if run_smoke:
        meta = export_smoke(resources, args.out)
        print(f"SMOKE {meta['key']} id={meta['slp_id']} frames={meta['frame_count']} -> {args.out / '_smoke'}")

    if run_priority:
        report = export_priority(resources, args.out, player=player)
        return 0 if report["exported"] else 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
