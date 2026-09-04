from __future__ import annotations

import math
from typing import Any

from brain.stores import FOOD, GOLD, WOOD, resource_type_from_name


def _pos(entity: dict[str, Any]) -> tuple[float, float]:
    pos = entity.get("pos", [0.0, 0.0])
    return float(pos[0]), float(pos[1])


def _dist_sq(a: tuple[float, float], b: tuple[float, float]) -> float:
    dx = a[0] - b[0]
    dy = a[1] - b[1]
    return dx * dx + dy * dy


def nearest_resource(
    from_unit: dict[str, Any],
    nodes: list[dict[str, Any]],
    resource_type: int,
) -> dict[str, Any] | None:
    unit_pos = _pos(from_unit)
    nearest: dict[str, Any] | None = None
    nearest_distance = math.inf
    for node in nodes:
        if node.get("kind") != "resource":
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
        if node.get("kind") != "resource":
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
        if node.get("kind") != "resource":
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
        if node.get("kind") != "resource":
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
