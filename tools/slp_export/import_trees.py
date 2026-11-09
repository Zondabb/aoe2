#!/usr/bin/env python3
"""Decode original HD forest SLPs, retaining every static shape and hotspot."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from export_sprites import ROOT, export_one, load_config

# Original forest atlases, not the chopped stumps / separate canopy layers.
# Frame counts verified against the local HD installation and aoc-slp-list.md.
FORESTS = (("tree_deciduous", 4652, 14), ("tree_palm", 4653, 13),
           ("tree_pine", 4654, 9), ("tree_bamboo", 2293, 4))


def import_trees(resources: Path, out: Path) -> None:
    records = []
    for key, slp_id, count in FORESTS:
        meta = export_one(resources=resources, out_dir=out, file_id=slp_id,
                          key=key, category="resources", directions=1,
                          note="Original static tree shapes; select one frame, never animate")
        if meta["frame_count"] != count:
            raise ValueError(f"{key}: expected {count} HD shapes, got {meta['frame_count']}")
        source = Path(meta["source"])
        meta["source"] = source.relative_to(resources).as_posix()
        meta["palette"] = Path(meta["palette"]).relative_to(resources).as_posix()
        meta["source_sha256"] = hashlib.sha256(source.read_bytes()).hexdigest()
        (out / "resources" / f"{key}.json").write_text(
            json.dumps(meta, indent=2) + "\n", encoding="utf-8")
        records.append({"key": key, "slp_id": slp_id, "frame_count": count,
                        "source": meta["source"], "sha256": meta["source_sha256"]})
    (out / "resources" / "tree_sources.json").write_text(
        json.dumps({"edition": "Age of Empires II HD", "trees": records}, indent=2) + "\n",
        encoding="utf-8")
    print(f"Imported {len(records)} forest atlases / {sum(r['frame_count'] for r in records)} static shapes")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=Path)
    parser.add_argument("--out", type=Path, default=ROOT / "assets/sprites")
    args = parser.parse_args()
    import_trees(args.resources or Path(load_config(None)["aoe2_resources"]), args.out)


if __name__ == "__main__":
    main()
