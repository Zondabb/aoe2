from __future__ import annotations

import copy
import json
import threading
import time
from types import SimpleNamespace

from fastapi.testclient import TestClient
import pytest

import main as service
from main import app
from protocol.models import ChatCompletionRequest, ChatCompletionResponse


@pytest.fixture(autouse=True)
def no_model_log_files(monkeypatch):
    monkeypatch.setattr(service, "_write_llm_json", lambda *_args: None)


@pytest.fixture
def commander_registry(monkeypatch):
    now = [100.0]
    monkeypatch.setattr(service, "_commanders", {})
    monkeypatch.setattr(service, "_commander_last_access", {})
    monkeypatch.setattr(service, "_commander_requests", {})
    monkeypatch.setattr(service, "_commander_registry_lock", threading.RLock())
    # Replace only this module's time binding, keeping real thread/HTTP timers.
    monkeypatch.setattr(service, "time", SimpleNamespace(monotonic=lambda: now[0], perf_counter=time.perf_counter))
    return now


def body(match_id: str, team: int = 1, tick: int = 0) -> dict:
    return {
        "model": "test-model", "messages": [{"role": "user", "content": "observed game"}],
        "metadata": {"match_id": match_id, "team": team, "enemy_team": 1 - team,
                     "tick": tick, "time_sec": tick * 10, "profile_id": "teutons", "backend": "openai"},
        "observation": {
            "economy": {"food": 0, "wood": 0, "gold": 0, "pop_used": 0, "pop_cap": 5},
            "derived": {"own_tc_id": -1, "own_tc_pos": [0, 0], "enemy_tc_id": -1,
                        "enemy_tc_pos": [0, 0], "threat_near_base": False,
                        "villager_count": 0, "military_count": 0, "incomplete_buildings": 0},
            "entities": [], "map_bounds": {"min": [-40, -40], "max": [40, 40]},
            "decision_context": {"catalog": {"buildings": [{"id": "barracks", "cost": {"wood": 175}, "available": False}], "units": []},
                                 "construction_options": [], "scouting": {"frontiers": []}, "army": {}},
        },
    }


def completion(calls: list | None = None) -> dict:
    return {"id": "test", "choices": [{"message": {"role": "assistant", "tool_calls": calls}, "finish_reason": "tool_calls" if calls else "stop"}]}


def test_http_plan_persists_isolates_and_retry_skips_model(monkeypatch):
    captured: list[dict] = []

    def model(_url, _headers, payload, _timeout):
        brief = json.loads(payload["messages"][-1]["content"].split("\n", 1)[1])
        captured.append(brief)
        assert "set_strategy" in {tool["function"]["name"] for tool in payload["tools"]}
        if brief["team"] == 1 and brief["tick"] == 0:
            return completion([{"id": "strategy", "type": "function", "function": {
                "name": "set_strategy", "arguments": json.dumps({"stance": "muster", "army_target": 11})}}])
        return completion()

    monkeypatch.setenv("AOE2_AI_BACKEND", "openai")
    monkeypatch.setenv("AOE2_LLM_TOKEN", "test-key")
    monkeypatch.setattr("brain.llm_proxy.post_openai", model)
    client = TestClient(app)
    match = "llm_http_memory"
    client.post("/v1/ai/match/start", json={"match_id": match})
    first = client.post("/v1/chat/completions", json=body(match))
    assert first.status_code == 200
    second_body = body(match, tick=1)
    second = client.post("/v1/chat/completions", json=second_body)
    assert second.status_code == 200
    assert captured[-1]["plan"]["stance"] == "muster"
    assert captured[-1]["plan"]["army_target"] == 11
    retry = client.post("/v1/chat/completions", json=copy.deepcopy(second_body))
    assert retry.json() == second.json()
    assert len(captured) == 2
    opponent = client.post("/v1/chat/completions", json=body(match, team=0, tick=2))
    assert opponent.status_code == 200
    assert captured[-1]["plan"]["stance"] == "develop"
    assert not captured[-1]["plan"]["explicit"]
    client.post("/v1/ai/match/end", json={"match_id": match})
    assert not service._commander_requests
    restarted = client.post("/v1/chat/completions", json=body(match, tick=3))
    assert restarted.status_code == 200
    assert captured[-1]["plan"]["stance"] == "develop"
    client.post("/v1/ai/match/start", json={"match_id": match})
    client.post("/v1/chat/completions", json=body(match, tick=4))
    assert not captured[-1]["plan"]["explicit"]
    client.post("/v1/ai/match/end", json={"match_id": match})
    assert not service._commander_requests


def request(match_id: str, team: int = 1) -> ChatCompletionRequest:
    return ChatCompletionRequest.model_validate(body(match_id, team))


def idle_commander(req: ChatCompletionRequest):
    commander, lock = service._get_llm_commander(req)
    service._release_llm_commander(req, commander, lock)
    return commander, lock


def test_idle_ttl_reclaims_only_expired_team_and_preserves_live_retry_cache(commander_registry):
    now = commander_registry
    expired_req = request("ttl_shared", 0)
    live_req = request("ttl_shared", 1)
    expired, _expired_lock = idle_commander(expired_req)
    live, _live_lock = idle_commander(live_req)
    expired.strategy.stance = "attack"
    live.strategy.stance = "muster"
    expired.finish_response(expired_req, ChatCompletionResponse.model_validate(completion()))
    cached = live.finish_response(live_req, ChatCompletionResponse.model_validate(completion()))
    now[0] += service._COMMANDER_IDLE_TTL_SECONDS - 1
    assert idle_commander(live_req)[0] is live
    now[0] += 1
    idle_commander(request("ttl_cleanup_trigger"))
    assert ("ttl_shared", 0) not in service._commanders
    assert ("ttl_shared", 0) not in service._commander_last_access
    assert service._commanders[("ttl_shared", 1)][0] is live
    assert live.strategy.stance == "muster"
    assert live.cached_response(live_req) == cached
    replacement, _lock = idle_commander(expired_req)
    assert replacement is not expired and replacement.strategy.stance == "develop"
    assert replacement.cached_response(expired_req) is None


def test_idle_ttl_protects_requests_waiting_for_or_executing_team_lock(commander_registry):
    now = commander_registry
    req = request("ttl_leased")
    commander, lock = service._get_llm_commander(req)
    waiting = threading.Event()
    executing = threading.Event()
    finish = threading.Event()
    received = []

    def queued_request():
        pair = service._get_llm_commander(req)
        received.append(pair)
        waiting.set()
        try:
            with pair[1]:
                executing.set()
                assert finish.wait(2)
        finally:
            service._release_llm_commander(req, *pair)

    lock.acquire()
    owner_released = False
    worker = threading.Thread(target=queued_request)
    worker.start()
    try:
        assert waiting.wait(2)
        now[0] += service._COMMANDER_IDLE_TTL_SECONDS + 1
        idle_commander(request("ttl_other_team", 0))
        assert service._commanders[("ttl_leased", 1)][0] is commander
        assert service._commander_requests[lock] == 2
        service._release_llm_commander(req, commander, lock)
        lock.release()
        owner_released = True
        assert executing.wait(2)
        now[0] += service._COMMANDER_IDLE_TTL_SECONDS + 1
        idle_commander(request("ttl_other_match"))
        assert service._commanders[("ttl_leased", 1)][0] is commander
        assert service._commander_requests[lock] == 1
    finally:
        # Always release the worker, including an assertion failure.
        if not owner_released:
            lock.release()
        finish.set()
        worker.join(2)
    assert not worker.is_alive()
    assert received[0][0] is commander
    assert lock not in service._commander_requests
    assert service._commander_last_access[("ttl_leased", 1)] == now[0]
    idle_commander(request("ttl_after_completion"))
    assert service._commanders[("ttl_leased", 1)][0] is commander


def test_idle_ttl_never_waits_for_busy_unleased_team_lock(commander_registry):
    now = commander_registry
    req = request("ttl_busy_lock")
    commander, lock = idle_commander(req)
    ready = threading.Event()
    finish = threading.Event()

    def hold_lock():
        with lock:
            ready.set()
            assert finish.wait(2)

    worker = threading.Thread(target=hold_lock)
    worker.start()
    try:
        assert ready.wait(2)
        now[0] += service._COMMANDER_IDLE_TTL_SECONDS + 1
        idle_commander(request("ttl_busy_trigger"))
        assert service._commanders[("ttl_busy_lock", 1)][0] is commander
    finally:
        finish.set()
        worker.join(2)
    assert not worker.is_alive()
    idle_commander(request("ttl_reclaim_trigger"))
    assert ("ttl_busy_lock", 1) not in service._commanders
    assert ("ttl_busy_lock", 1) not in service._commander_last_access


def test_explicit_end_clears_timestamps_and_late_completion_cannot_revive_session(commander_registry):
    now = commander_registry
    match = "ttl_explicit_end"
    idle_commander(request(match, 0))
    old_req = request(match, 1)
    old, old_lock = service._get_llm_commander(old_req)
    other_req = request("ttl_unrelated", 0)
    other, _lock = idle_commander(other_req)
    client = TestClient(app)
    assert client.post("/v1/ai/match/end", json={"match_id": match}).status_code == 200
    assert all(key[0] != match for key in service._commanders)
    assert all(key[0] != match for key in service._commander_last_access)
    assert service._commanders[("ttl_unrelated", 0)][0] is other
    assert service._commander_last_access[("ttl_unrelated", 0)] == now[0]
    now[0] += 10
    replacement, replacement_lock = service._get_llm_commander(old_req)
    access = service._commander_last_access[(match, 1)]
    now[0] += 10
    service._release_llm_commander(old_req, old, old_lock)
    assert old_lock not in service._commander_requests
    assert service._commanders[(match, 1)][0] is replacement
    assert service._commander_last_access[(match, 1)] == access
    service._release_llm_commander(old_req, replacement, replacement_lock)
    assert client.post("/v1/ai/match/end", json={"match_id": match}).status_code == 200
    assert all(key[0] != match for key in service._commander_last_access)
    assert not service._commander_requests


def test_http_outage_reports_observed_plan_continuation(monkeypatch):
    def unavailable(*_args, **_kwargs):
        raise RuntimeError("test upstream unavailable")

    monkeypatch.setenv("AOE2_AI_BACKEND", "openai")
    monkeypatch.setenv("AOE2_LLM_TOKEN", "test-key")
    monkeypatch.setattr("brain.llm_proxy.post_openai", unavailable)
    client = TestClient(app)
    match = "llm_http_outage"
    client.post("/v1/ai/match/start", json={"match_id": match})
    result = client.post("/v1/chat/completions", json=body(match, tick=1))
    assert result.status_code == 200
    assert result.json()["usage"]["total_tokens"] == 0
    assert any(entry["category"] == "LLM_FALLBACK" for entry in result.json()["debug"])
    assert not service._commander_requests
    missing = client.post("/v1/chat/completions", json={"messages": [{"role": "user", "content": "no game"}]})
    assert missing.status_code == 502
    assert not service._commander_requests
    client.post("/v1/ai/match/end", json={"match_id": match})
