from __future__ import annotations

from typing import Any

from brain.game_data import BUILDINGS


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
) -> tuple[float, float] | None:
    if town_center is None:
        return None
    origin = (
        float(town_center["pos"][0]),
        float(town_center["pos"][1]),
    )
    side = build_side_sign(origin)
    offsets = [
        (6.0, 0.0),
        (6.0, 4.0),
        (4.0, 6.0),
        (0.0, 6.0),
        (8.0, 2.0),
        (8.0, 6.0),
        (6.0, 8.0),
        (10.0, 0.0),
        (10.0, 4.0),
        (8.0, 8.0),
        (4.0, 10.0),
        (12.0, 2.0),
    ]
    for radius in range(14, 39, 4):
        for offset in range(0, radius + 1, 4):
            offsets.extend(((float(radius), float(offset)), (float(offset), float(radius))))
    for index in range(len(offsets)):
        slot = (build_slot + index) % len(offsets)
        ox, oy = offsets[slot]
        candidate = (origin[0] + ox * side[0], origin[1] + oy * side[1])
        if can_place(building_def_id, candidate, all_buildings, definitions):
            return candidate
    return None
