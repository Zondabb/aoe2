from __future__ import annotations

import math
from typing import Any

from brain.stores import resource_type_from_name


def _is_resource(entity: dict[str, Any]) -> bool:
    return entity.get("kind") == "resource" or (
        entity.get("kind") == "building"
        and entity.get("def_id") == "farm"
        and bool(entity.get("is_complete"))
    )


def _pos(entity: dict[str, Any]) -> tuple[float, float]:
    pos = entity.get("pos", [0.0, 0.0])
    return float(pos[0]), float(pos[1])


def _dist_sq(a: tuple[float, float], b: tuple[float, float]) -> float:
    dx = a[0] - b[0]
    dy = a[1] - b[1]
    return dx * dx + dy * dy


def idle_villager(villagers: list[dict[str, Any]]) -> dict[str, Any] | None:
    for villager in villagers:
        if str(villager.get("order", "")) == "NONE":
            return villager
    return None


def any_villager(villagers: list[dict[str, Any]]) -> dict[str, Any] | None:
    return villagers[0] if villagers else None


def nearest_resource(
    from_unit: dict[str, Any],
    nodes: list[dict[str, Any]],
    resource_type: int,
) -> dict[str, Any] | None:
    unit_pos = _pos(from_unit)
    nearest: dict[str, Any] | None = None
    nearest_distance = math.inf
    for node in nodes:
        if not _is_resource(node):
            continue
        if resource_type_from_name(str(node.get("resource_type", ""))) != resource_type:
            continue
        if float(node.get("amount", 0.0)) <= 0.0:
            continue
        distance = _dist_sq(unit_pos, _pos(node))
        if distance < nearest_distance:
            nearest = node
            nearest_distance = distance
    return nearest


def nearest_any_resource(
    from_unit: dict[str, Any], nodes: list[dict[str, Any]]
) -> dict[str, Any] | None:
    unit_pos = _pos(from_unit)
    nearest: dict[str, Any] | None = None
    nearest_distance = math.inf
    for node in nodes:
        if not _is_resource(node):
            continue
        if float(node.get("amount", 0.0)) <= 0.0:
            continue
        distance = _dist_sq(unit_pos, _pos(node))
        if distance < nearest_distance:
            nearest = node
            nearest_distance = distance
    return nearest


def nearest_resource_near_base(
    from_unit: dict[str, Any],
    nodes: list[dict[str, Any]],
    resource_type: int,
    base_pos: tuple[float, float],
    max_radius: float,
) -> dict[str, Any] | None:
    if base_pos == (0.0, 0.0):
        return nearest_resource(from_unit, nodes, resource_type)
    unit_pos = _pos(from_unit)
    nearest: dict[str, Any] | None = None
    nearest_distance = math.inf
    max_sq = max_radius * max_radius
    for node in nodes:
        if not _is_resource(node):
            continue
        if resource_type_from_name(str(node.get("resource_type", ""))) != resource_type:
            continue
        if float(node.get("amount", 0.0)) <= 0.0:
            continue
        node_pos = _pos(node)
        if _dist_sq(base_pos, node_pos) > max_sq:
            continue
        distance = _dist_sq(unit_pos, node_pos)
        if distance < nearest_distance:
            nearest = node
            nearest_distance = distance
    return nearest


def nearest_any_resource_near_base(
    from_unit: dict[str, Any],
    nodes: list[dict[str, Any]],
    base_pos: tuple[float, float],
    max_radius: float,
) -> dict[str, Any] | None:
    if base_pos == (0.0, 0.0):
        return nearest_any_resource(from_unit, nodes)
    unit_pos = _pos(from_unit)
    nearest: dict[str, Any] | None = None
    nearest_distance = math.inf
    max_sq = max_radius * max_radius
    for node in nodes:
        if not _is_resource(node):
            continue
        if float(node.get("amount", 0.0)) <= 0.0:
            continue
        node_pos = _pos(node)
        if _dist_sq(base_pos, node_pos) > max_sq:
            continue
        distance = _dist_sq(unit_pos, node_pos)
        if distance < nearest_distance:
            nearest = node
            nearest_distance = distance
    return nearest


def find_town_center(buildings: list[dict[str, Any]]) -> dict[str, Any] | None:
    for building in buildings:
        if str(building.get("def_id", "")) == "town_center":
            return building
    return None


def has_building(buildings: list[dict[str, Any]], building_id: str) -> bool:
    for building in buildings:
        if str(building.get("def_id", "")) == building_id:
            return True
    return False


def has_incomplete_building(buildings: list[dict[str, Any]], building_id: str) -> bool:
    for building in buildings:
        if str(building.get("def_id", "")) != building_id:
            continue
        if not bool(building.get("is_complete", False)):
            return True
    return False


def find_complete_building(
    buildings: list[dict[str, Any]], building_id: str
) -> dict[str, Any] | None:
    for building in buildings:
        if str(building.get("def_id", "")) != building_id:
            continue
        if bool(building.get("is_complete", False)):
            return building
    return None


def find_enemy_town_center(
    entities: list[dict[str, Any]], enemy_team: int
) -> dict[str, Any] | None:
    for entity in entities:
        if entity.get("kind") != "building":
            continue
        if int(entity.get("team", -1)) != enemy_team:
            continue
        if str(entity.get("def_id", "")) == "town_center":
            return entity
    return None


def nearest_hostile_in_radius(
    unit: dict[str, Any],
    entities: list[dict[str, Any]],
    enemy_team: int,
    radius: float,
) -> dict[str, Any] | None:
    unit_pos = _pos(unit)
    nearest: dict[str, Any] | None = None
    nearest_distance = math.inf
    radius_sq = radius * radius
    for entity in entities:
        if entity.get("kind") not in ("unit", "building"):
            continue
        if int(entity.get("team", -1)) != enemy_team:
            continue
        if float(entity.get("hp", 0.0)) <= 0.0:
            continue
        distance = _dist_sq(unit_pos, _pos(entity))
        if distance <= radius_sq and distance < nearest_distance:
            nearest = entity
            nearest_distance = distance
    return nearest
