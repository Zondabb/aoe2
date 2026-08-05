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
    {"key": "militia_walk", "category": "units", "id": 997, "directions": 5, "note": "Militia / swordsman tier moving"},
    {"key": "swordsman_walk", "category": "units", "id": 604, "directions": 5, "note": "ROR swordsman moving"},
    {"key": "archer_walk", "category": "units", "id": 12, "directions": 5, "note": "Archer moving"},
    {"key": "chu_ko_nu_walk", "category": "units", "id": 225, "directions": 5, "note": "Chu-Ko-Nu moving"},
    {"key": "teutonic_knight_walk", "category": "units", "id": 1198, "directions": 5, "note": "Teutonic knight moving"},
    {"key": "tc_dark_main", "category": "buildings", "id": 891, "directions": 1, "note": "Dark Age TC main top (single layer)"},
    {"key": "tc_asian_feudal_top", "category": "buildings", "id": 901, "directions": 1, "note": "Asian feudal TC top piece"},
    {"key": "house_dark", "category": "buildings", "id": 2223, "directions": 1, "note": "Dark Age houses"},
    {"key": "house_asian_feudal", "category": "buildings", "id": 2233, "directions": 1, "note": "Asian feudal houses"},
    {"key": "barracks_asian_feudal", "category": "buildings", "id": 131, "directions": 1, "note": "Asian barracks feudal"},
    {"key": "archery_asian_feudal", "category": "buildings", "id": 22, "directions": 1, "note": "Asian archery feudal"},
    {"key": "stable_asian_feudal", "category": "buildings", "id": 1007, "directions": 1, "note": "Asian stable feudal"},
    {"key": "stable_ne_feudal", "category": "buildings", "id": 1006, "directions": 1, "note": "North European stable feudal (Teutons)"},
    {"key": "tree_oak", "category": "resources", "id": 1251, "directions": 1, "palette": "pal_2", "note": "Oak tree (pal_2)"},
    {"key": "gold_mine", "category": "resources", "id": 4479, "directions": 1, "note": "Gold mine"},
    {"key": "berry_bush", "category": "resources", "id": 2560, "directions": 1, "note": "Berry bush / food"},
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
        sheet.paste(im, (ox, oy), im)
        pads.append({"x": pad_x, "y": pad_y})
    return sheet, cols, rows, frame_w, frame_h, pads


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

    report = {
        "exported": [{"key": r["key"], "slp_id": r["slp_id"], "frame_count": r["frame_count"]} for r in results],
        "missing": missing,
        "discovered_ids": PRIORITY,
        "placeholders": [
            "Full TC is multi-layer (base + roofs); demo uses single top pieces (891/901).",
            "Unit sheets use 5 authored directions + horizontal flip for the mirrored facings.",
            "Shadow pixels are approximated as checkerboard alpha, not the in-game shadow table.",
        ],
    }
    report_path = out_dir / "export_report.json"
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"Wrote {report_path} ({len(results)} ok, {len(missing)} missing)")
    return report


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Export AoE2 HD SLP sprites to PNG")
    parser.add_argument("--config", type=Path, default=None, help="config.json path")
    parser.add_argument("--smoke", action="store_true", help="export one smoke SLP only")
    parser.add_argument("--priority", action="store_true", help="export priority demo list")
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
    parser.add_argument("--out", type=Path, default=ROOT / "assets" / "sprites")
    args = parser.parse_args(argv)

    cfg = load_config(args.config)
    resources = Path(cfg["aoe2_resources"])
    player = int(cfg.get("player_color", 1))
    if not resources.is_dir():
        print(f"ERROR: aoe2_resources not found: {resources}", file=sys.stderr)
        return 1

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
