from __future__ import annotations

from typing import Any
import math

from brain.game_data import BUILDINGS

# Match AiEntityQueries settlement planning, not the player's legal footprint.
SETTLEMENT_FOOTPRINT_SCALE = 4.0
FARM_PLANNING_SIDE = 8.0
SETTLEMENT_LANE_WIDTH = 4.0
SETTLEMENT_EDGE_MARGIN = 4.0
SETTLEMENT_SLOT_STEP = 8
SETTLEMENT_MAX_RADIUS = 96


def planning_size(name, footprint):
    # The farm ground texture covers just under 8 x 8 simulation units.
    return (FARM_PLANNING_SIDE,) * 2 if name == "farm" else tuple(side * SETTLEMENT_FOOTPRINT_SCALE for side in footprint)


def can_place(
    building_def_id: str,
    center: tuple[float, float],
    existing_buildings: list[dict[str, Any]],
    definitions: dict[str, dict] = BUILDINGS,
) -> bool:
    building = definitions.get(building_def_id)
    if building is None:
        return False
    footprint = building["footprint"]
    candidate_half = (footprint[0] * 0.5, footprint[1] * 0.5)
    for existing in existing_buildings:
        existing_def = str(existing.get("def_id", ""))
        existing_fp = definitions.get(existing_def, {}).get("footprint", (1.0, 1.0))
        existing_half = (existing_fp[0] * 0.5, existing_fp[1] * 0.5)
        pos = existing.get("pos", [0.0, 0.0])
        offset = (
            abs(center[0] - float(pos[0])),
            abs(center[1] - float(pos[1])),
        )
        if (
            offset[0] < candidate_half[0] + existing_half[0]
            and offset[1] < candidate_half[1] + existing_half[1]
        ):
            return False
    return True


def can_plan_settlement(
    building_def_id: str,
    center: tuple[float, float],
    existing_buildings: list[dict[str, Any]],
    definitions: dict[str, dict] = BUILDINGS,
    resources: list[dict[str, Any]] | None = None,
    map_bounds: tuple[float, float, float, float] | None = None,
) -> bool:
    """Leave visual clearance and worker lanes without changing build legality.

    ``map_bounds`` is (minimum_x, minimum_y, maximum_x, maximum_y).
    Only resources present in the team's observation are supplied by callers.
    """
    if not can_place(building_def_id, center, existing_buildings, definitions):
        return False
    footprint = definitions[building_def_id]["footprint"]
    half = tuple(side * 0.5 for side in planning_size(building_def_id, footprint))
    if map_bounds is not None:
        minimum_x, minimum_y, maximum_x, maximum_y = map_bounds
        if (
            center[0] - half[0] - SETTLEMENT_EDGE_MARGIN < minimum_x
            or center[1] - half[1] - SETTLEMENT_EDGE_MARGIN < minimum_y
            or center[0] + half[0] + SETTLEMENT_EDGE_MARGIN > maximum_x
            or center[1] + half[1] + SETTLEMENT_EDGE_MARGIN > maximum_y
        ):
            return False
    for existing in existing_buildings:
        name = str(existing.get("def_id", ""))
        other_fp = definitions.get(name, {}).get("footprint", (1.0, 1.0))
        other_half = tuple(side * 0.5 for side in planning_size(name, other_fp))
        if _boxes_overlap(center, half, existing.get("pos", (0.0, 0.0)), other_half):
            return False
    resource_footprints = {"FOOD": 0.8, "WOOD": 1.2, "GOLD": 2.0, "STONE": 2.0}
    for resource in resources or []:
        if float(resource.get("amount", 0)) <= 0 or resource.get("kind") == "building":
            continue
        side = resource_footprints.get(str(resource.get("resource_type", "")).upper(), 0.0)
        other_half = (side * SETTLEMENT_FOOTPRINT_SCALE * 0.5,) * 2
        if _boxes_overlap(center, half, resource.get("pos", (0.0, 0.0)), other_half):
            return False
    return True


def _boxes_overlap(center: tuple, half: tuple, other_center: tuple | list, other_half: tuple) -> bool:
    return all(
        abs(float(center[axis]) - float(other_center[axis]))
        < half[axis] + other_half[axis] + SETTLEMENT_LANE_WIDTH
        for axis in (0, 1)
    )


def build_side_sign(origin: tuple[float, float]) -> tuple[float, float]:
    sx = 1.0
    sy = 1.0
    if origin[0] < -0.01:
        sx = 1.0
    elif origin[0] > 0.01:
        sx = -1.0
    if origin[1] < -0.01:
        sy = 1.0
    elif origin[1] > 0.01:
        sy = -1.0
    return sx, sy


def next_build_position(
    building_def_id: str,
    town_center: dict[str, Any] | None,
    all_buildings: list[dict[str, Any]],
    build_slot: int,
    definitions: dict[str, dict] = BUILDINGS,
    resources: list[dict[str, Any]] | None = None,
    map_bounds: tuple[float, float, float, float] | None = None,
    placement_visibility: dict[str, Any] | None = None,
) -> tuple[float, float] | None:
    if town_center is None or building_def_id not in definitions:
        return None
    origin = (
        float(town_center["pos"][0]),
        float(town_center["pos"][1]),
    )
    side = build_side_sign(origin)
    if building_def_id == "farm":
        drop_offs = [b for b in all_buildings if b.get("def_id") in ("town_center", "mill")
                     and b.get("team") == town_center.get("team") and b.get("is_complete", True)
                     and b.get("hp", 1) > 0 and not b.get("is_placement_ghost")]
        for first_ring in range(0, 8, 2):
            for point in _farm_sites(drop_offs, definitions, side, range(first_ring, first_ring + 2)):
                if (footprint_visible(point, definitions["farm"]["footprint"], placement_visibility)
                        and can_plan_settlement("farm", point, all_buildings, definitions, resources, map_bounds)):
                    return point
        return None
    offsets = []
    for radius in range(16, SETTLEMENT_MAX_RADIUS + 1, SETTLEMENT_SLOT_STEP):
        for offset in range(0, radius + 1, SETTLEMENT_SLOT_STEP):
            offsets.append((float(radius), float(offset)))
            if offset != radius:
                offsets.append((float(offset), float(radius)))
    for index in range(len(offsets)):
        slot = (build_slot + index) % len(offsets)
        ox, oy = offsets[slot]
        candidate = (origin[0] + ox * side[0], origin[1] + oy * side[1])
        if not footprint_visible(candidate, definitions[building_def_id]["footprint"], placement_visibility):
            continue
        if can_plan_settlement(building_def_id, candidate, all_buildings, definitions, resources, map_bounds):
            return candidate
    return None


def _farm_sites(drop_offs, definitions, side, rings):
    """Mirror Godot's farm rings and rank plots by distance to the delivery building's edge."""
    distances = {}
    step = math.ceil(FARM_PLANNING_SIDE / 2 + SETTLEMENT_LANE_WIDTH)
    for building in drop_offs:
        cx, cy = building["pos"]
        width, height = definitions[building["def_id"]]["footprint"]
        inner = math.ceil((width * SETTLEMENT_FOOTPRINT_SCALE + FARM_PLANNING_SIDE) / 2 + SETTLEMENT_LANE_WIDTH)
        for ring in rings:
            radius = inner + ring * math.ceil(FARM_PLANNING_SIDE + SETTLEMENT_LANE_WIDTH)
            slots = math.ceil(radius / step)
            for slot in range(-slots, slots + 1):
                shift = max(-radius, min(radius, slot * step))
                for dx, dy in ((1, 0), (0, 1), (-1, 0), (0, -1)):
                    x = cx + side[0] * (dx * radius + dy * shift)
                    y = cy + side[1] * (dy * radius - dx * shift)
                    gap = math.hypot(max(0, abs(x - cx) - width / 2), max(0, abs(y - cy) - height / 2))
                    distances[x, y] = min(gap, distances.get((x, y), math.inf))
    return sorted(distances, key=distances.get)


def footprint_visible(center: tuple[float, float], footprint: list | tuple,
                      visibility: dict[str, Any] | None) -> bool:
    """Mirror Godot's current fog cells using only the team's sight sources."""
    if visibility is None:
        return True  # Older observations and arenas have no fog restriction.
    origin = visibility["origin"]
    size = float(visibility["cell_size"])
    width, height = map(int, visibility["grid_size"])
    low = [math.floor((center[i] - float(footprint[i]) / 2 - origin[i]) / size) for i in (0, 1)]
    high = [math.floor((center[i] + max(0, float(footprint[i]) / 2 - 0.00001) - origin[i]) / size) for i in (0, 1)]
    if low[0] < 0 or low[1] < 0 or high[0] >= width or high[1] >= height:
        return False
    sources = visibility.get("sources", [])
    for y in range(low[1], high[1] + 1):
        for x in range(low[0], high[0] + 1):
            px, py = origin[0] + (x + 0.5) * size, origin[1] + (y + 0.5) * size
            if not any((px - sx) ** 2 + (py - sy) ** 2 <= radius ** 2 for sx, sy, radius in sources):
                return False
    return True
