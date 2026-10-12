from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

from brain.game_data import CIVS
from brain.stores import FOOD, GOLD, PHASE_BOOM, PHASE_ECO, WOOD


@dataclass(frozen=True)
class CivAiProfile:
    civ_id: str
    villager_target: int = 8
    high_food_stockpile: int = 400
    military_attack_count: int = 6
    attack_time_seconds: float = 180.0
    retarget_radius: float = 8.0
    rally_radius: float = 6.0
    build_order: tuple[str, ...] = ("house", "barracks", "archery_range")
    army_composition: dict[str, int] = field(default_factory=lambda: {"swordsman": 4, "archer": 2})
    unique_unit_priority: bool = True
    opening_seconds: float = 120.0
    defend_radius: float = 20.0

    def villagers_for_age(self, age: int) -> int:
        return max(8, self.villager_target) + max(0, age) * 4

    def ratios_for_phase(self, phase: int) -> dict[int, float]:
        if phase == PHASE_ECO:
            return {FOOD: 0.6, WOOD: 0.3, GOLD: 0.1}
        if phase == PHASE_BOOM:
            return {FOOD: 0.4, WOOD: 0.35, GOLD: 0.25}
        return {FOOD: 0.3, WOOD: 0.3, GOLD: 0.4}


_DATA_DIR = Path(__file__).resolve().parents[1] / "data" / "ai"
_CACHE: dict[str, CivAiProfile] = {}


def profile_for_id(profile_id: str) -> CivAiProfile:
    key = profile_id or "default"
    if key in _CACHE:
        return _CACHE[key]
    path = _DATA_DIR / f"profile_{key}.json"
    if not path.exists():
        path = _DATA_DIR / "profile_default.json"
    payload = json.loads(path.read_text(encoding="utf-8"))
    profile = CivAiProfile(
        civ_id=str(payload.get("civ_id", key)),
        villager_target=int(payload.get("villager_target", 8)),
        high_food_stockpile=int(payload.get("high_food_stockpile", 400)),
        military_attack_count=int(payload.get("military_attack_count", 6)),
        attack_time_seconds=float(payload.get("attack_time_seconds", 180.0)),
        retarget_radius=float(payload.get("retarget_radius", 8.0)),
        rally_radius=float(payload.get("rally_radius", 6.0)),
        build_order=tuple(payload.get("build_order", [])),
        army_composition=dict(payload.get("army_composition", {})),
        unique_unit_priority=bool(payload.get("unique_unit_priority", True)),
        opening_seconds=float(payload.get("opening_seconds", 120.0)),
        defend_radius=float(payload.get("defend_radius", 20.0)),
    )
    _CACHE[key] = profile
    return profile


def civ_for_profile(profile_id: str) -> dict:
    return CIVS.get(profile_id, CIVS["default"])
