"""Intelligence: scouting, and the picture of the enemy the other layers work from."""
from __future__ import annotations

from brain.llm_commander import _distance

from ..models import IntelBrief
from .base import Department

APPROACH_RANGE = 48.0
FORECASTS = {"own": "ahead", "enemy": "behind", "none": "even"}
KEY_BUILDINGS = ("town_center", "castle", "siege_workshop", "stone_wall", "palisade_wall")


class IntelDept(Department):
    name = "intel"
    role = "scout"
    field_roles = ("commander", "scout")

    def update(self, f, mandates, brief=None) -> IntelBrief:
        engine = self.field
        engine._scout(f)
        commander = engine.roles["commander"].memory
        army = engine.intel.estimated_army()
        soldiers = [e for e in f.obs.entities if f.enemy(e) and e.get("kind") == "unit" and e.get("def_id") != "villager"]
        approaching = any(_distance(e["pos"], f.base) <= APPROACH_RANGE for e in soldiers)
        if commander.get("threat_ids"):
            level = 3
        elif commander.get("raid_ids") or approaching:
            level = 2
        else:
            level = 1 if army or soldiers else 0
        report = engine.intel.report()
        seen = {known["def_id"] for known in engine.enemy_knowledge.values() if known["kind"] == "building"}
        forecast = engine.battle_forecast
        return IntelBrief(
            threat_level=level, enemy_army=dict(army.most_common(8)),
            forecast=FORECASTS.get(forecast["winner"], "even") if forecast else "unknown",
            counters=[item["unit"] for item in engine.counter_ranking[:3]],
            enemy_progress={"age_at_least": report["enemy_age_at_least"], "civilization_guess": report["enemy_civilization_guess"],
                            "style": report["enemy_style"], "buildings_seen": [name for name in KEY_BUILDINGS if name in seen]},
            alerts=[entry["message"][len("intel: "):] for entry in engine.debug if entry["message"].startswith("intel: ")])
