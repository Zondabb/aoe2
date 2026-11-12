"""Phase 0 of the cabinet architecture: selecting it changes no command."""
from __future__ import annotations

import copy
import json

import pytest

from brain.cabinet.runtime import CabinetRuntime
from brain.multi_agent.runtime import MultiAgentRuntime, ROLE_SCHEMAS
from brain.multi_agent.scheduler import MultiAgentService, ROLES
from brain.runtime_factory import create_runtime
from test_llm_commander import building, unit
from test_multi_agent_runtime import accept, army, enemy_tc, frame
from test_multi_agent_scheduler import completion, tick_request, wait_idle


def base_entities():
    return [building(1, "town_center"), unit(10), unit(11), unit(12), unit(20, "scout_cavalry"),
            {"id": 100, "kind": "resource", "resource_type": "FOOD", "pos": [5, 5], "amount": 1000},
            {"id": 101, "kind": "resource", "resource_type": "WOOD", "pos": [5, -5], "amount": 1000},
            {"id": 102, "kind": "resource", "resource_type": "GOLD", "pos": [-5, 5], "amount": 1000}]


def opening(runtime) -> list:
    """One team's first ticks: orders, their receipts, a model plan, an army and the enemy base."""
    seen = []
    result = runtime.tick(frame(1))
    seen.append(copy.deepcopy(result))
    result = runtime.tick(frame(2, events=accept(result)))
    seen.append(copy.deepcopy(result))
    stance = {**runtime.planning_context("commander")["plan"], "stance": "pressure"}
    seen.append(runtime.apply_plan("commander", stance))
    seen.append(runtime.apply_plan("commander", {"stance": "retreat"}))  # outside the schema
    for tick in (3, 4, 5):
        result = runtime.tick(frame(tick, entities=base_entities() + army(6, [2, 2]) + [enemy_tc()],
                                    events=accept(result, seq=tick * 100)))
        seen.append(copy.deepcopy(result))
    seen.append(runtime.tick(frame(5)))  # a retried tick answers from the cache
    seen.append({role: copy.deepcopy(runtime.planning_context(role)) for role in ROLE_SCHEMAS})
    seen.append(copy.deepcopy(runtime.goals))
    seen.append(copy.deepcopy(runtime.match_summary))
    return seen


def test_cabinet_runtime_matches_the_seven_role_runtime_tick_for_tick():
    baseline = opening(MultiAgentRuntime("chinese"))
    assert any(result["commands"] for result in baseline[:2])  # the scenario really issues orders
    assert baseline[2] is True and baseline[3] is False
    assert opening(CabinetRuntime("chinese")) == baseline


def test_cabinet_runtime_takes_cross_match_memory():
    runtime = CabinetRuntime("teutons")
    runtime.load_strategic_memory({"lessons": ["wall early"]})
    assert runtime.legacy.strategic_memory == {"lessons": ["wall early"]}
    assert runtime.legacy.validator.profile_id == "teutons"


def test_factory_follows_the_runtime_setting_for_each_new_session(monkeypatch):
    assert type(create_runtime("chinese")) is MultiAgentRuntime
    monkeypatch.setenv("AOE2_AI_RUNTIME", "cabinet")
    assert type(create_runtime("chinese")) is CabinetRuntime
    monkeypatch.setenv("AOE2_AI_RUNTIME", "multi_agent")
    assert type(create_runtime("chinese")) is MultiAgentRuntime
    monkeypatch.setenv("AOE2_AI_RUNTIME", "cabinnet")
    with pytest.raises(ValueError, match="Unknown AI runtime"):
        create_runtime("chinese")


def played(factory, backend="rules_compat", **service_options) -> list[dict]:
    service = MultiAgentService(runtime_factory=factory, **service_options)
    try:
        out = []
        for seq in range(1, 10):
            result = service.tick(tick_request(seq, backend=backend))
            wait_idle(service)
            # Wall-clock timing and random request ids are not behaviour.
            result["debug"] = [entry for entry in result["debug"] if "elapsed_ms" not in entry["message"]]
            for status in result["planning"].values():
                if isinstance(status, dict):
                    status.pop("request_id", None)
            out.append(result)
        return out
    finally:
        service.shutdown()


def test_service_answers_identically_with_either_runtime(monkeypatch):
    baseline = played(MultiAgentRuntime)
    assert any(result["commands"] for result in baseline)
    monkeypatch.setenv("AOE2_AI_RUNTIME", "cabinet")
    switched = played(create_runtime)
    assert switched == baseline


def test_background_model_plans_reach_the_cabinet_runtime_like_the_baseline(monkeypatch):
    monkeypatch.setenv("AOE2_AI_BACKEND", "openai")

    def planned(factory) -> tuple[list, list[dict]]:
        calls = []

        def forward(req):
            role = req.metadata.model_dump()["agent"]
            calls.append(role)
            plan = json.loads(req.messages[1].content)["plan"]
            if role == "commander":
                plan["stance"] = "pressure"
            return completion(json.dumps(plan))

        results = played(factory, backend="openai", forward=forward, max_workers=2,
                         calls_per_minute=len(ROLES), clock=lambda: 100.0)
        return calls, results

    baseline_calls, baseline = planned(MultiAgentRuntime)
    assert set(baseline_calls) == set(ROLES)
    assert baseline[-1]["agent_status"]["commander"]["plan"]["stance"] == "pressure"
    assert baseline[-1]["agent_status"]["commander"]["plan_source"] == "llm"
    monkeypatch.setenv("AOE2_AI_RUNTIME", "cabinet")
    calls, switched = planned(create_runtime)
    assert sorted(calls) == sorted(baseline_calls)
    assert switched == baseline
