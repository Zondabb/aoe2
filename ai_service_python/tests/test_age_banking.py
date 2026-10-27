"""Saving for the next age does not idle a TC that is still growing the economy."""
from __future__ import annotations

from brain.multi_agent.runtime import MultiAgentRuntime
from test_llm_commander import building, unit
from test_multi_agent_runtime import accept, frame, issued


def age_frame(tick, villagers, food, time, events=()):
    entities = [building(1, "town_center", age_upgrade_reason="resources"), building(3, "mill"), building(4, "lumber_camp")]
    req = frame(tick, entities=entities + [unit(10 + i) for i in range(villagers)], time=time, events=events, construction_options=[])
    req.observation.economy.food = food
    req.observation.economy.pop_cap = 50
    req.observation.decision_context["catalog"]["age_upgrade"] = {"cost": {"food": 500}, "buildings": ["mill", "lumber_camp"], "required_distinct_buildings": 2}
    return req


def villager_orders(result):
    return [c for c in issued(result, "train") if c["unit_def_id"] == "villager"]


def test_the_tc_keeps_training_villagers_below_the_target_instead_of_banking():
    runtime = MultiAgentRuntime()
    first = runtime.tick(age_frame(1, 9, 200, 160))
    assert villager_orders(first)
    second = runtime.tick(age_frame(2, 10, 300, 185, accept(first)))
    assert villager_orders(second)
    assert not runtime.tech_reserve.get("food")
    assert second["agent_status"]["technology"]["reason"] != "reserving_age_budget_and_tc_window"


def test_banking_starts_once_the_villager_target_is_met():
    runtime = MultiAgentRuntime()
    result = runtime.tick(age_frame(1, 16, 300, 300))
    assert runtime.tech_reserve.get("food", 0) > 0
    assert result["agent_status"]["technology"]["reason"] == "reserving_age_budget_and_tc_window"


def test_banking_resumes_when_villager_production_has_stalled():
    runtime = MultiAgentRuntime()
    runtime.roles["economy"].memory["villager_ordered_at"] = 90.0
    req = age_frame(1, 9, 300, 160)
    req.observation.economy.pop_cap = 9
    runtime.tick(req)
    assert runtime.tech_reserve.get("food", 0) > 0
