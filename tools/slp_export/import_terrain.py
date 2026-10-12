#!/usr/bin/env python3
"""Import original HD ground water, rock, and an opaque original cliff face.

The water and rock PNG files are copied unchanged. The face is a rectangular
opaque excerpt from SLP 226, frame 1; runtime repeats it along vertical walls.
No painted substitute or enlarged animated shallows sprite is involved.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path

from export_sprites import _read_slp, load_config

ROOT = Path(__file__).resolve().parents[2]
FACE_RECT = (95, 57, 191, 97)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=Path)
    parser.add_argument("--out", type=Path, default=ROOT / "assets/terrain")
    args = parser.parse_args()
    resources = args.resources or Path(load_config(None)["aoe2_resources"])
    args.out.mkdir(parents=True, exist_ok=True)
    source_dir = resources / "_common/terrain/textures"
    records = {}
    for key, filename in [("water", "g_wtr_00_color.png"), ("rock", "g_rck_00_COLOR.png")]:
        source = source_dir / filename
        shutil.copyfile(source, args.out / (key + ".png"))
        records[key] = {
            "source": source.relative_to(resources).as_posix(),
            "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
            "pixels": "unmodified original texture",
        }
    frames, _meta, _masks, source, palette = _read_slp(resources, 226, 1)
    face = frames[1].crop(FACE_RECT)
    if face.getchannel("A").getextrema() != (255, 255):
        raise ValueError("Cliff wall texture must be fully opaque")
    face.save(args.out / "cliff_face.png")
    records["cliff_face"] = {
        "source": Path(source).relative_to(resources).as_posix(),
        "palette": Path(palette).relative_to(resources).as_posix(),
        "slp_id": 226,
        "frame_index": 1,
        "crop_xyxy": list(FACE_RECT),
        "pixels": "opaque unchanged excerpt of original rock face",
    }
    (args.out / "terrain_sources.json").write_text(
        json.dumps({"edition": "Age of Empires II HD", "textures": records}, indent=2) + "\n",
        encoding="utf-8",
    )
    print("Imported 2 original terrain textures and 1 original cliff face")


if __name__ == "__main__":
    main()
