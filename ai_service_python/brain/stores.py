from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

# Mirrors scripts/core/enums.gd ResourceType order.
FOOD = 0
WOOD = 1
GOLD = 2

ORDER_NONE = "NONE"
ORDER_GATHER = "GATHER"
ORDER_BUILD = "BUILD"
ORDER_ATTACK = "ATTACK"
ORDER_MOVE = "MOVE"

PHASE_ECO = 0
PHASE_BOOM = 1
PHASE_ATTACK = 2
PHASE_DEFEND = 3

STUCK_GATHER_FRAMES = 12
BASE_RESOURCE_RADIUS = 36.0


@dataclass
class Blackboard:
    match_time: float = 0.0
    ai_team: int = 0
    enemy_team: int = 1
    food: int = 0
    wood: int = 0
    gold: int = 0
    pop_used: int = 0
    pop_cap: int = 0
    villager_count: int = 0
    military_count: int = 0
    incomplete_buildings: int = 0
    threat_near_base: bool = False
    own_tc_pos: tuple[float, float] = (0.0, 0.0)
    enemy_tc_pos: tuple[float, float] = (0.0, 0.0)
    team_units: list[dict[str, Any]] = field(default_factory=list)
    team_villagers: list[dict[str, Any]] = field(default_factory=list)
    team_buildings: list[dict[str, Any]] = field(default_factory=list)
    resource_nodes: list[dict[str, Any]] = field(default_factory=list)
    all_buildings: list[dict[str, Any]] = field(default_factory=list)
    all_entities: list[dict[str, Any]] = field(default_factory=list)
    entity_by_id: dict[int, dict[str, Any]] = field(default_factory=dict)


class EventStore:
    """Tracks recent events for optional director logic."""

    def __init__(self) -> None:
        self.events: list[dict[str, Any]] = []

    def clear(self) -> None:
        self.events.clear()

    def apply(self, events: list[dict[str, Any]]) -> None:
        for event in events:
            self.events.append(event)


class ObservationStore:
    """Python port of scripts/ai_gateway/observation_store.gd."""

    def __init__(self) -> None:
        self.economy: dict[str, Any] = {}
        self.derived: dict[str, Any] = {}
        self.entities: list[dict[str, Any]] = []

    def load_from_dict(self, observation: dict[str, Any]) -> None:
        self.economy = observation.get("economy", {})
        self.derived = observation.get("derived", {})
        self.entities = observation.get("entities", [])

    def apply_to_blackboard(
        self, blackboard: Blackboard, team: int, enemy_team: int
    ) -> None:
        blackboard.match_time = float(self.derived.get("match_time_sec", 0.0))
        blackboard.ai_team = team
        blackboard.enemy_team = enemy_team
        blackboard.food = int(self.economy.get("food", 0))
        blackboard.wood = int(self.economy.get("wood", 0))
        blackboard.gold = int(self.economy.get("gold", 0))
        blackboard.pop_used = int(self.economy.get("pop_used", 0))
        blackboard.pop_cap = int(self.economy.get("pop_cap", 0))
        blackboard.villager_count = int(self.derived.get("villager_count", 0))
        blackboard.military_count = int(self.derived.get("military_count", 0))
        blackboard.incomplete_buildings = int(
            self.derived.get("incomplete_buildings", 0)
        )
        blackboard.threat_near_base = bool(self.derived.get("threat_near_base", False))
        blackboard.own_tc_pos = _vec2(self.derived.get("own_tc_pos"))
        blackboard.enemy_tc_pos = _vec2(self.derived.get("enemy_tc_pos"))

        blackboard.team_units.clear()
        blackboard.team_villagers.clear()
        blackboard.team_buildings.clear()
        blackboard.resource_nodes.clear()
        blackboard.all_buildings.clear()
        blackboard.all_entities.clear()
        blackboard.entity_by_id.clear()

        entity_by_id = {int(entity.get("id", -1)): entity for entity in self.entities}
        blackboard.entity_by_id = entity_by_id

        for snapshot in self.entities:
            blackboard.all_entities.append(snapshot)
            kind = str(snapshot.get("kind", ""))
            if kind == "resource":
                blackboard.resource_nodes.append(snapshot)
                continue
            if kind == "building":
                blackboard.all_buildings.append(snapshot)
                if int(snapshot.get("team", -1)) == team:
                    blackboard.team_buildings.append(snapshot)
                continue
            if kind == "unit":
                if int(snapshot.get("team", -1)) != team:
                    continue
                blackboard.team_units.append(snapshot)
                if str(snapshot.get("def_id", "")) == "villager":
                    blackboard.team_villagers.append(snapshot)

        for villager in blackboard.team_villagers:
            last_id = villager.get("last_resource_id")
            if last_id is not None and int(last_id) in entity_by_id:
                villager["_last_resource"] = entity_by_id[int(last_id)]
            else:
                villager["_last_resource"] = None


def _vec2(value: Any) -> tuple[float, float]:
    if isinstance(value, (list, tuple)) and len(value) >= 2:
        return float(value[0]), float(value[1])
    return 0.0, 0.0


def resource_type_from_name(name: str) -> int:
    match name.upper():
        case "FOOD":
            return FOOD
        case "WOOD":
            return WOOD
        case "GOLD":
            return GOLD
        case _:
            return FOOD


def resource_name(resource_type: int) -> str:
    match resource_type:
        case 0:
            return "food"
        case 1:
            return "wood"
        case 2:
            return "gold"
        case _:
            return "resource"
