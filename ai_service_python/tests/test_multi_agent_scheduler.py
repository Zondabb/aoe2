from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import copy
import json
import threading
import time

from fastapi.testclient import TestClient
import pytest

from brain.multi_agent.scheduler import MultiAgentService, ROLES, SessionError, _decode_plan
from protocol.models import ChatCompletionResponse
from test_llm_commander import request


def tick_request(seq=1, match="multi-test", team=0, epoch="epoch-a", backend="rules_compat"):
    req = request(seq)
    req.metadata = req.metadata.model_copy(update={"protocol_version": 3, "match_id": match,
        "team": team, "session_epoch": epoch, "observation_seq": seq, "backend": backend})
    return req


class Runtime:
    def __init__(self, profile):
        self.calls = 0
        self.plans = []
        self.version = 1

    def tick(self, req):
        self.calls += 1
        return {"commands": [{"command_id": f"command-{req.metadata.tick}", "op": "noop"}],
                "agent_status": {}, "goals": {"version": self.version}}

    def planning_context(self, role):
        return {"goal_version": self.version, "role": role, "own_count": 4}

    def apply_plan(self, role, plan):
        self.plans.append((role, copy.deepcopy(plan)))
        return True


@pytest.fixture
def schemas(monkeypatch):
    import brain.multi_agent.runtime as runtime
    schema = {"type": "object", "additionalProperties": False,
              "properties": {"value": {"type": "integer", "minimum": 0, "maximum": 2}},
              "required": ["value"]}
    monkeypatch.setattr(runtime, "ROLE_SCHEMAS", {role: schema for role in ROLES})
    monkeypatch.setattr(runtime, "ROLE_PROMPTS", {role: role for role in ROLES})


def completion(arguments='{"value":1}', finish="tool_calls"):
    raw = {"id": "mock", "choices": [{"finish_reason": finish, "message": {
        "role": "assistant", "tool_calls": [{"type": "function", "function": {
            "name": "propose_plan", "arguments": arguments}}]}}],
        "usage": {"prompt_tokens": 40, "completion_tokens": 10, "total_tokens": 50}}
    return ChatCompletionResponse.model_validate(raw), {}, raw


def wait_idle(service):
    deadline = time.monotonic() + 3
    while service._inflight_count and time.monotonic() < deadline:
        time.sleep(.005)
    assert service._inflight_count == 0


def test_idempotent_retry_conflict_old_sequence_and_epoch(monkeypatch):
    monkeypatch.setenv("AOE2_AI_BACKEND", "rules_compat")
    service = MultiAgentService(runtime_factory=Runtime)
    try:
        req = tick_request()
        first = service.tick(req)
        assert first["session_epoch"] == "epoch-a"
        assert first["acknowledged_observation_seq"] == 1
        assert service.tick(req) == first
        assert service._sessions[("multi-test", 0)].runtime.calls == 1
        changed = req.model_copy(deep=True)
        changed.observation.economy.food += 1
        with pytest.raises(SessionError, match="observation_seq_conflict"):
            service.tick(changed)
        with pytest.raises(SessionError, match="session_changed"):
            service.tick(tick_request(2, epoch="epoch-b"))
        service.tick(tick_request(20))
        with pytest.raises(SessionError, match="stale_observation"):
            service.tick(tick_request(2))
        service.close_match("multi-test")
        with pytest.raises(SessionError, match="match_ended"):
            service.tick(tick_request(21))
        service.open_match("multi-test")
        assert service.tick(tick_request(0, epoch="epoch-b"))["session_epoch"] == "epoch-b"
    finally:
        service.shutdown()


def test_slow_model_does_not_block_ticks_and_late_result_cannot_revive(schemas, monkeypatch):
    monkeypatch.setenv("AOE2_AI_BACKEND", "openai")
    entered, release = threading.Event(), threading.Event()
    logs = []

    def forward(req):
        assert len(req.messages) == 2
        assert req.observation is None
        # Client generation values never become the specialist's model budget.
        assert req.max_tokens == 321
        assert req.temperature == 0.4
        assert req.messages[1].content.count("goal_version") == 1
        assert sum(len(msg.content) for msg in req.messages) < 2000
        entered.set()
        assert release.wait(3)
        return completion()

    monkeypatch.setenv("AOE2_LLM_MAX_TOKENS", "321")
    monkeypatch.setenv("AOE2_LLM_TEMPERATURE", "0.4")
    service = MultiAgentService(forward=forward, runtime_factory=Runtime, max_workers=1,
                                log=lambda event, data: logs.append((event, data)))
    try:
        with ThreadPoolExecutor(max_workers=1) as executor:
            first = executor.submit(service.tick, tick_request(backend="openai")).result(timeout=1)
            assert first["commands"]
            assert entered.wait(1)
            for seq in range(2, 9):
                assert executor.submit(service.tick, tick_request(seq, backend="openai")).result(timeout=1)["commands"]
        old = service._sessions[("multi-test", 0)]
        service.close_match("multi-test")
        release.set()
        wait_idle(service)
        assert old.runtime.plans == []
        assert not service._sessions
        assert any(data.get("state") == "session_closed" for event, data in logs if event == "model_result")
    finally:
        release.set()
        service.shutdown()


def test_role_plans_apply_and_log_usage_with_global_bounded_calls(schemas, monkeypatch):
    monkeypatch.setenv("AOE2_AI_BACKEND", "openai")
    logs, calls = [], []
    clock = [100.0]

    def forward(req):
        calls.append(req.metadata.model_dump()["agent"])
        return completion()

    service = MultiAgentService(forward=forward, runtime_factory=Runtime, max_workers=2,
        calls_per_minute=len(ROLES), clock=lambda: clock[0], log=lambda event, data: logs.append((event, data)))
    try:
        for seq in range(1, 10):
            service.tick(tick_request(seq, backend="openai"))
            wait_idle(service)
        assert set(calls) == set(ROLES)
        assert len(calls) == len(ROLES)
        assert len(service._sessions[("multi-test", 0)].runtime.plans) == len(ROLES)
        results = [data for event, data in logs if event == "model_result"]
        assert all(data["state"] == "applied" for data in results)
        assert all(data["usage"]["total_tokens"] == 50 for data in results)
        assert len({data["request_id"] for data in results}) == len(ROLES)
        io = [data for event, data in logs if event == "llm_io"]
        assert len(io) == len(ROLES)
        assert all(data["output"]["usage"]["total_tokens"] == 50 for data in io)
    finally:
        service.shutdown()


@pytest.mark.parametrize("arguments,finish", [('"primitive"', "stop"), ('{"value":99}', "tool_calls"),
    ('{"value":1,"commands":[]}', "tool_calls"), ('{', "tool_calls"), ('{"value":1}', "length")])
def test_invalid_or_truncated_model_plan_never_applies(schemas, monkeypatch, arguments, finish):
    monkeypatch.setenv("AOE2_AI_BACKEND", "openai")
    service = MultiAgentService(forward=lambda req: completion(arguments, finish), runtime_factory=Runtime, max_workers=1)
    try:
        service.tick(tick_request(backend="openai"))
        wait_idle(service)
        assert service._sessions[("multi-test", 0)].runtime.plans == []
    finally:
        service.shutdown()


@pytest.mark.parametrize("content,valid", [
    ('{"value":1}', True),
    ('{"value":1.0}', True),
    ('{"action":"propose_plan","parameters":{"value":1}}', True),
    ('{"action":"attack","parameters":{"value":1}}', False),
    ('Here is the plan: {"value":1}', False),
    ('{"value":1,"commands":[]}', False),
    ('{"value":NaN}', False),
    ('{"value":true}', False),
    ('{"value":99}', False),
    ('{"value":1', False),
])
def test_complete_json_content_uses_the_same_strict_schema(schemas, content, valid):
    from brain.multi_agent.runtime import ROLE_SCHEMAS
    response = ChatCompletionResponse.model_validate({"id": "local-json", "choices": [{
        "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}]})
    plan, output_format, parse_state = _decode_plan(response.choices[0], ROLE_SCHEMAS["commander"])
    assert (plan == {"value": 1}) == valid
    assert (parse_state == "valid") == valid
    assert output_format.startswith("json_")
    if valid:
        assert type(plan["value"]) is int


def test_goal_discovery_keeps_economy_plan_but_still_rejects_combat_plan(schemas, monkeypatch):
    monkeypatch.setenv("AOE2_AI_BACKEND", "openai")
    logs = []
    service = MultiAgentService(forward=lambda req: completion(), runtime_factory=Runtime, max_workers=1,
                                log=lambda event, data: logs.append((event, data)))
    service._pool.shutdown()
    service._pool = ControlledPool()
    try:
        service.tick(tick_request(backend="openai"))
        session = service._sessions[("multi-test", 0)]
        session.runtime.version += 1
        service._pool.finish()
        assert session.plan_status["commander"]["state"] == "goal_changed"
        session.next_role = ROLES.index("economy")
        service.tick(tick_request(2, backend="openai"))
        session.runtime.version += 1
        service._pool.finish()
        assert session.runtime.plans == [("economy", {"value": 1})]
        applied = [data for event, data in logs if event == "model_result"][-1]
        assert applied["parse_state"] == "valid"
        assert applied["applied_observation_seq"] == 2
        assert applied["changed_fields"] == ["value"]
    finally:
        service.shutdown()


def test_new_player_instruction_reaches_upstream_and_supersedes_inflight_plan(schemas, monkeypatch):
    from brain.llm_proxy import build_openai_payload
    monkeypatch.setenv("AOE2_AI_BACKEND", "openai")
    contexts = []

    def forward(req):
        contexts.append(json.loads(build_openai_payload(req)["messages"][-1]["content"]))
        return completion()

    now = [0.0]
    service = MultiAgentService(forward=forward, runtime_factory=Runtime, max_workers=1, clock=lambda: now[0])
    service._pool.shutdown()
    service._pool = ControlledPool()
    try:
        service.tick(tick_request(1))
        req = tick_request(2)
        req.observation.player_instructions = ["多生产一些骑士", "增加食物采集"]
        service.tick(req)
        service._pool.finish()
        session = service._sessions[("multi-test", 0)]
        assert not session.runtime.plans
        assert session.plan_status["commander"]["state"] == "player_instructions_changed"
        req = tick_request(3)
        req.observation.player_instructions = ["多生产一些骑士", "增加食物采集"]
        service.tick(req)
        service._pool.finish()
        assert contexts[-1]["player_instructions"] == req.observation.player_instructions
        assert len(session.runtime.plans) == 1
        now[0] += 6  # Expire the previous team's unserved demand.
        service.tick(tick_request(1, team=1))
        service._pool.finish()
        assert "player_instructions" not in contexts[-1]
    finally:
        service.shutdown()


def test_expired_invalid_output_reports_both_failures(schemas, monkeypatch):
    monkeypatch.setenv("AOE2_AI_BACKEND", "openai")
    logs = []
    service = MultiAgentService(forward=lambda req: completion('{'), runtime_factory=Runtime, max_workers=1,
                                log=lambda event, data: logs.append((event, data)))
    service._pool.shutdown()
    service._pool = ControlledPool()
    try:
        service.tick(tick_request(backend="openai"))
        service._sessions[("multi-test", 0)].last_sim_time += 181
        service._pool.finish()
        result = next(data for event, data in logs if event == "model_result")
        assert result["state"] == "plan_expired"
        assert result["parse_state"] == "invalid_json"
        assert result["plan_age_sim_sec"] == 181
    finally:
        service.shutdown()


def test_finished_match_ticks_do_not_start_more_model_requests(schemas, monkeypatch):
    monkeypatch.setenv("AOE2_AI_BACKEND", "rules_compat")
    calls = []
    service = MultiAgentService(forward=lambda req: calls.append(req), runtime_factory=Runtime, max_workers=1)
    try:
        service.tick(tick_request())
        service._sessions[("multi-test", 0)].runtime.goals = {"match_over": True}
        monkeypatch.setenv("AOE2_AI_BACKEND", "openai")
        assert service.tick(tick_request(2, backend="openai"))["commands"]
        assert not calls and service._inflight_count == 0
    finally:
        service.shutdown()


def test_native_failure_log_keeps_actual_context_and_thinking_options(schemas, monkeypatch):
    monkeypatch.setenv("AOE2_AI_BACKEND", "openai")
    monkeypatch.setenv("AOE2_LLM_BASE_URL", "http://127.0.0.1:11434/v1")
    logs = []

    def unavailable(req):
        raise TimeoutError("local inference timeout")

    service = MultiAgentService(forward=unavailable, runtime_factory=Runtime, max_workers=1,
                                log=lambda event, data: logs.append((event, data)))
    try:
        service.tick(tick_request(backend="openai"))
        wait_idle(service)
        entry = next(data for event, data in logs if event == "llm_io")
        assert entry["input"]["think"] is False
        assert entry["input"]["options"]["num_predict"] == 256
        assert "format" in entry["input"] and "tool_choice" not in entry["input"]
        assert entry["output"] == {"error": "TimeoutError"}
    finally:
        service.shutdown()


def test_obsolete_objective_and_expired_model_plan_rejected(schemas, monkeypatch):
    monkeypatch.setenv("AOE2_AI_BACKEND", "openai")
    for change in ("goal", "time"):
        release = threading.Event()

        def forward(req):
            assert release.wait(3)
            return completion()

        service = MultiAgentService(forward=forward, runtime_factory=Runtime, max_workers=1)
        try:
            service.tick(tick_request(backend="openai"))
            session = service._sessions[("multi-test", 0)]
            with session.lock:
                if change == "goal":
                    session.runtime.version += 1
                else:
                    session.last_sim_time += 181
            release.set()
            wait_idle(service)
            assert session.runtime.plans == []
            expected = "goal_changed" if change == "goal" else "plan_expired"
            assert session.plan_status["commander"]["state"] == expected
        finally:
            release.set()
            service.shutdown()


def test_two_teams_and_matches_share_bounded_pool_without_state_leaks(schemas, monkeypatch):
    monkeypatch.setenv("AOE2_AI_BACKEND", "openai")
    release = threading.Event()

    def forward(req):
        assert release.wait(3)
        return completion()

    service = MultiAgentService(forward=forward, runtime_factory=Runtime, max_workers=2)
    try:
        for match, team in (("one", 0), ("one", 1), ("two", 0)):
            out = service.tick(tick_request(match=match, team=team, backend="openai"))
            assert out["team"] == team and out["match_id"] == match
        assert service._inflight_count == 2
        assert len(service._sessions) == 3
        assert len({id(entry.runtime) for entry in service._sessions.values()}) == 3
    finally:
        release.set()
        wait_idle(service)
        service.shutdown()


class ControlledPool:
    """Complete model jobs at known times to reproduce saturated scheduling."""
    def __init__(self):
        self.jobs = []

    def submit(self, function, *args):
        self.jobs.append((function, args))

    def finish(self):
        jobs, self.jobs = self.jobs, []
        for function, args in jobs:
            function(*args)

    def shutdown(self, **kwargs):
        self.jobs.clear()


def test_saturated_pool_is_fair_when_one_team_always_ticks_first(schemas, monkeypatch):
    monkeypatch.setenv("AOE2_AI_BACKEND", "openai")
    clock, calls = [0.0], []

    def forward(req):
        calls.append(req.metadata.team)
        return completion()

    service = MultiAgentService(forward=forward, runtime_factory=Runtime, max_workers=2,
                                clock=lambda: clock[0])
    service._pool.shutdown()
    service._pool = ControlledPool()
    try:
        for second in range(181):
            clock[0] = float(second)
            if second and second % 30 == 0:
                service._pool.finish()
            for team in (0, 1):
                service.tick(tick_request(second, match="fair", team=team, backend="openai"))
            assert service._inflight_count <= 2
        # Previously all 12 completions belonged to team 0 and team 1 never planned.
        assert calls.count(0) >= 4 and calls.count(1) >= 4
        assert abs(calls.count(0) - calls.count(1)) <= 2
    finally:
        service.shutdown()


def test_single_team_uses_both_slots_and_inactive_waiter_does_not_reserve_them(schemas, monkeypatch):
    monkeypatch.setenv("AOE2_AI_BACKEND", "openai")
    clock = [0.0]
    service = MultiAgentService(forward=lambda req: completion(), runtime_factory=Runtime,
                                max_workers=2, clock=lambda: clock[0])
    service._pool.shutdown()
    service._pool = ControlledPool()
    try:
        service.tick(tick_request(0, match="one", team=0, backend="openai"))
        assert len(service._sessions[("one", 0)].inflight) == 2
        service.tick(tick_request(0, match="one", team=1, backend="openai"))
        assert ("one", 1) in service._waiting
        service._pool.finish()
        clock[0] = 6.0
        service.tick(tick_request(1, match="one", team=0, backend="openai"))
        assert len(service._sessions[("one", 0)].inflight) == 2
        assert ("one", 1) not in service._waiting
        service.close_match("one")
        assert all(key[0] != "one" for key in service._waiting)
        service._pool.finish()
        service.tick(tick_request(0, match="two", team=0, backend="openai"))
        assert len(service._sessions[("two", 0)].inflight) == 2
    finally:
        service.shutdown()


def test_v3_http_contract_auth_and_session_end(monkeypatch):
    import main
    service = MultiAgentService(runtime_factory=Runtime)
    monkeypatch.setattr(main, "_multi_agent_service", service)
    monkeypatch.setenv("AOE2_AI_BACKEND", "rules_compat")
    monkeypatch.setenv("AOE2_AI_TOKEN", "test-ai-secret")
    client = TestClient(main.app)
    headers = {"Authorization": "Bearer test-ai-secret"}
    try:
        payload = tick_request().model_dump()
        assert client.post("/v3/ai/tick", json=payload).status_code == 401
        response = client.post("/v3/ai/tick", json=payload, headers=headers)
        assert response.status_code == 200
        assert response.json()["protocol_version"] == 3
        payload["metadata"]["session_epoch"] = ""
        assert client.post("/v3/ai/tick", json=payload, headers=headers).status_code == 422
        assert client.post("/v1/ai/match/end", json={"match_id": "multi-test"}, headers=headers).status_code == 200
        payload = tick_request(2).model_dump()
        assert client.post("/v3/ai/tick", json=payload, headers=headers).status_code == 409
    finally:
        service.shutdown()


def test_log_failure_does_not_interrupt_tasks_or_session_cleanup(monkeypatch):
    monkeypatch.setenv("AOE2_AI_BACKEND", "rules_compat")

    def broken_log(event, data):
        raise OSError("volume unavailable")

    service = MultiAgentService(runtime_factory=Runtime, log=broken_log)
    try:
        assert service.tick(tick_request())["commands"]
        service.close_match("multi-test")
        assert not service._sessions
    finally:
        service.shutdown()
