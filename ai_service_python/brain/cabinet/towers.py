"""Pick a visible building site inside the home wall, leaving its gate approaches clear."""
from __future__ import annotations

import math

from brain.build_placement import can_plan_settlement, footprint_visible
from brain.land_progression import CATALOG

from .orders import TOWER_LINE


def tower_type(f) -> str:
    researched = f.obs.progression.researched_technologies if f.obs.progression else {}
    return next((name for name in reversed(TOWER_LINE[1:]) if researched.get(name)), TOWER_LINE[0])


def perimeter_sites(bounds):
    """Each gate is centered on a side. Try its flanks, stepping inward to find visible clear land."""
    if not isinstance(bounds, (list, tuple)) or len(bounds) != 4 or not all(
            isinstance(v, (int, float)) and math.isfinite(v) for v in bounds):
        return
    x, y, width, height = bounds
    if min(width, height) < 12:
        return
    for dx, dy, side, depth in ((1, 0, height, width), (-1, 0, height, width),
                                (0, 1, width, height), (0, -1, width, height)):
        for inset in (6, 8, 12, 16):
            if inset >= depth / 2:
                continue
            for offset in (6, -6, 12, -12, 18, -18):
                if abs(offset) + 2 >= side / 2:
                    continue
                yield (round(x + width / 2 + dx * (depth / 2 - inset) + dy * offset),
                       round(y + height / 2 + dy * (depth / 2 - inset) + dx * offset))


def site_options(f, engine, name: str, towers: list[dict]) -> list[dict]:
    workers = [u for u in f.units if u.get("def_id") == "villager" and u.get("order", "NONE") in ("NONE", "GATHER")
               and not u.get("build_queue_ids") and u.get("gather_state") != "to_drop_off" and u.get("carry_amount", 0) <= .001
               and u["id"] not in f.actors and not engine.kernel.benched(u["id"])]
    if not workers:
        return []
    # A terrain rejection applies to the site even when a different worker is free next tick.
    rejected = {tuple(t["command"]["pos"]) for t in engine.tasks.values()
                if t["command"].get("op") == "place_building" and t["command"].get("building_def_id") in TOWER_LINE
                and t["status"] == "failed" and engine.now - t["issued_at"] < 60}
    catalog = {**CATALOG["buildings"], **f.building_defs}
    buildings = [e for e in f.obs.entities if e.get("kind") == "building" and e.get("hp", 1) > 0]
    resources = [e for e in f.obs.entities if e.get("kind") == "resource"]
    box = (*f.obs.map_bounds["min"], *f.obs.map_bounds["max"]) if f.obs.map_bounds else None
    positions = perimeter_sites(f.context.get("defense_plan", {}).get("bounds"))
    candidates = []
    for point in positions:
        if point in rejected or not footprint_visible(point, catalog[name]["footprint"], f.obs.placement_visibility):
            continue
        # Perimeter towers flank the gates. Keep a two-unit lane beyond the
        # visual footprint of each building instead of the town's wider lanes.
        if not can_plan_settlement(name, point, buildings, catalog, resources, box, lane_width=2) or engine._in_raid_zone(f, point):
            continue
        nearest = min(math.dist(point, u["pos"]) for u in workers)
        spacing = min((math.dist(point, t["pos"]) for t in towers), default=0)
        candidates.append((min(spacing, 32) - nearest * .25, point))
    if not candidates:
        return []
    _, point = max(candidates, key=lambda pair: pair[0])
    return [{"builder_id": u["id"], "building_def_id": name, "pos": list(point)}
            for u in sorted(workers, key=lambda u: math.dist(u["pos"], point))]
