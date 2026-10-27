"""Home threats do not recall a scout from across the map."""
from __future__ import annotations

from brain.multi_agent.runtime import MultiAgentRuntime
from test_llm_commander import building, unit
from test_multi_agent_runtime import frame, issued

SCOUTING = {"scout_ids": [20], "frontiers": [], "probes": [{"pos": [-80, 80]}, {"pos": [80, -80]}]}


def scene(scout_pos):
    return [building(1, "town_center"), unit(20, "scout_cavalry", scout_pos, hp=45, max_hp=45),
            unit(200, "scout_cavalry", [12, 0], team=1, hp=45, max_hp=45)]


def recalled(result):
    return [c for c in issued(result, "attack") if c["unit_id"] == 20 and c["target_id"] == 200]


def test_a_far_scout_keeps_scouting_while_an_enemy_scout_is_in_our_base():
    runtime = MultiAgentRuntime("chinese")
    result = runtime.tick(frame(entities=scene([80, 80]), time=60, scouting=SCOUTING))
    assert runtime.roles["commander"].memory["threat_ids"] == [200]
    assert not recalled(result)
    assert [c for c in issued(result, "move") if c["unit_id"] == 20]
    assert result["agent_status"]["scout"]["reason"] != "base_defense_preemption"
    assert 20 in runtime.scout_missions


def test_a_scout_near_home_still_answers_the_threat():
    runtime = MultiAgentRuntime("chinese")
    result = runtime.tick(frame(entities=scene([30, 10]), time=60, scouting=SCOUTING))
    assert recalled(result)


def test_without_intelligence_the_far_scout_is_recalled(monkeypatch):
    monkeypatch.setenv("AOE2_AI_INTELLIGENCE", "off")
    runtime = MultiAgentRuntime("chinese")
    result = runtime.tick(frame(entities=scene([80, 80]), time=60, scouting=SCOUTING))
    assert recalled(result)
    assert result["agent_status"]["scout"]["reason"] == "base_defense_preemption"
