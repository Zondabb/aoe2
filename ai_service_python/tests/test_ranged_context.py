"""LLM planners receive the same firing distances used by the game authority."""
from __future__ import annotations

import pytest

from brain.multi_agent.runtime import MultiAgentRuntime
from test_llm_commander import building, unit
from test_multi_agent_runtime import frame


@pytest.mark.parametrize("role", ["commander", "combat", "scout", "defense"])
def test_visible_defenses_keep_simulation_range_and_blind_spot(role):
    tc_combat = {"attack": 5, "range": 24.0, "minimum_range": 0.0, "cooldown": 2.0, "is_ranged": True}
    tower_combat = {**tc_combat, "range": 32.0, "minimum_range": 4.0}
    enemies = [building(200, "town_center", [40, 40], team=1, combat=tc_combat),
               building(201, "watch_tower", [35, 40], team=1, combat=tower_combat)]
    req = frame(entities=[building(1, "town_center"), unit(10), *enemies])
    runtime = MultiAgentRuntime()
    runtime.tick(req)

    visible = {item["id"]: item for item in runtime.planning_context(role)["visible_enemies"]}
    assert visible[200]["combat"] == tc_combat
    assert visible[201]["combat"] == tower_combat
    # The context is a snapshot, not an alias that can alter the observation.
    visible[200]["combat"]["range"] = 999
    assert req.observation.entities[-2]["combat"]["range"] == 24.0


def test_own_archer_and_unit_catalog_are_not_scaled_twice():
    combat = {"attack": 4, "range": 16.0, "minimum_range": 0.0, "cooldown": 2.0, "is_ranged": True}
    req = frame(entities=[building(1, "town_center"), unit(10), unit(30, "archer", combat=combat)])
    req.observation.decision_context["catalog"]["units"].append(
        {"id": "archer", "attack": 4, "attack_range": 16.0, "minimum_range": 0.0,
         "cooldown": 2.0, "is_ranged": True, "unlocked": True, "train_at": "archery_range"})
    runtime = MultiAgentRuntime()
    runtime.tick(req)

    context = runtime.planning_context("combat")
    assert next(item for item in context["units"] if item["id"] == 30)["combat"] == combat
    definition = next(item for item in context["unit_catalog"] if item["id"] == "archer")
    assert definition["attack_range"] == 16.0
    assert definition["minimum_range"] == 0.0
    assert definition["cooldown"] == 2.0


def test_building_catalog_and_noncombat_entities_remain_compatible():
    req = frame(entities=[building(1, "town_center"), building(2, "house"), unit(10)])
    req.observation.decision_context["catalog"]["buildings"].append(
        {"id": "town_center", "available": True, "attack": 5, "attack_range": 24.0,
         "minimum_range": 0.0, "cooldown": 2.0, "is_ranged": True})
    runtime = MultiAgentRuntime()
    runtime.tick(req)

    context = runtime.planning_context("construction")
    tc = next(item for item in context["catalog"]["buildings"] if item["id"] == "town_center")
    assert tc["attack_range"] == 24.0 and tc["minimum_range"] == 0.0
    assert tc["cooldown"] == 2.0 and tc["is_ranged"]
    house = next(item for item in context["buildings"] if item["id"] == 2)
    assert "combat" not in house
