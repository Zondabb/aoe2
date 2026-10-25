"""plan_review: explicit, bounded suggestions where a plan contradicts evidence."""
from __future__ import annotations

import json

from brain.multi_agent.runtime import MultiAgentRuntime
from test_llm_commander import building, unit
from test_multi_agent_runtime import frame, plan


def ticked(entities=None, age=0, **context):
    runtime = MultiAgentRuntime("chinese")
    req = frame(1, entities=entities, time=400, **context)
    req.observation.progression.age = age
    runtime.tick(req)
    return runtime


def fields(runtime, role):
    return {note["field"]: note for note in runtime.planning_context(role)["plan_review"]}


def test_reached_age_target_suggests_the_next_age():
    runtime = ticked(age=1)
    plan(runtime, "technology", target_age=1)
    note = fields(runtime, "technology")["target_age"]
    assert note["current"] == 1 and note["suggested"] == 2 and note["why"]


def test_economy_grows_once_the_worker_target_is_met():
    villagers = [unit(10 + i, pos=[i, 3]) for i in range(16)]
    runtime = ticked([building(1, "town_center"), *villagers], age=1)
    assert fields(runtime, "economy")["worker_target"]["suggested"] == 24
    young = ticked([building(1, "town_center"), *villagers], age=0)
    assert "worker_target" not in fields(young, "economy")       # 16 is the Dark Age size


def test_scout_hunts_the_unfound_enemy_town_center():
    runtime = ticked()
    plan(runtime, "scout", focus="resources")
    assert fields(runtime, "scout")["focus"]["suggested"] == "enemy_base"


def test_commander_hears_a_decisive_doctrine_but_not_a_default_one():
    runtime = ticked()
    runtime.recommended_doctrine = {"strategy": "turtle", "why": "enemy committed early"}
    assert fields(runtime, "commander")["strategy"]["suggested"] == "turtle"
    plan(runtime, "commander", strategy="fast_castle")
    runtime.recommended_doctrine = {"strategy": "adaptive", "why": "no decisive enemy signal yet"}
    assert "strategy" not in fields(runtime, "commander")


def test_raid_on_the_economy_asks_for_defense():
    entities = [building(1, "town_center"), unit(10, pos=[30, 0], hp=25, max_hp=25),
                building(5, "lumber_camp", [32, 4]), unit(200, "militia", [34, 0], team=1)]
    runtime = ticked(entities)
    plan(runtime, "commander", stance="pressure")
    plan(runtime, "defense", policy="reactive")
    assert fields(runtime, "commander")["stance"]["suggested"] == "defend"
    assert fields(runtime, "defense")["policy"]["suggested"] == "balanced"


def test_review_is_bounded_serializable_and_off_with_the_switch(monkeypatch):
    runtime = ticked()
    for role in runtime.roles:
        review = runtime.planning_context(role)["plan_review"]
        assert len(review) <= 4
        json.dumps(review, allow_nan=False)
    monkeypatch.setenv("AOE2_AI_INTELLIGENCE", "off")
    off = ticked()
    assert all("plan_review" not in off.planning_context(role) for role in off.roles)
