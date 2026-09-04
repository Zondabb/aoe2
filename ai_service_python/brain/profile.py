from __future__ import annotations

from dataclasses import dataclass

from brain.stores import FOOD, GOLD, PHASE_BOOM, PHASE_ECO, WOOD


@dataclass(frozen=True)
class CivAiProfile:
    civ_id: str
    villager_target: int = 8
    high_food_stockpile: int = 400
    military_attack_count: int = 6
    attack_time_seconds: float = 180.0
    defend_radius: float = 20.0

    def ratios_for_phase(self, phase: int) -> dict[int, float]:
        if phase == PHASE_ECO:
            return {FOOD: 0.6, WOOD: 0.3, GOLD: 0.1}
        if phase == PHASE_BOOM:
            return {FOOD: 0.4, WOOD: 0.35, GOLD: 0.25}
        return {FOOD: 0.3, WOOD: 0.3, GOLD: 0.4}


DEFAULT_PROFILE = CivAiProfile(civ_id="default")

PROFILES: dict[str, CivAiProfile] = {
    "default": DEFAULT_PROFILE,
    "chinese": CivAiProfile(civ_id="chinese"),
    "teutons": CivAiProfile(civ_id="teutons"),
}


def profile_for_id(profile_id: str) -> CivAiProfile:
    return PROFILES.get(profile_id, DEFAULT_PROFILE)
