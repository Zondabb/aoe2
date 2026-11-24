"""Coding steps share normal scheduling, with identity-safe retry feedback."""
import json

import pytest

from brain.cabinet.runtime import CabinetRuntime
from brain.multi_agent.scheduler import MultiAgentService, _decode_plan
from protocol.models import ChatCompletionResponse
from test_multi_agent_scheduler import ControlledPool, Runtime, tick_request


class CodingRuntime(Runtime):
    role = "legislative_council"

    def __init__(self, profile):
        super().__init__(profile)
        self.planning_roles = (self.role,)
        self.release = "source-a"
        self.goals = {}
        self.rejections = []

    def planning_interval(self, role):
        return 0

    def planning_context(self, role):
        return {**super().planning_context(role), "goals": self.goals,
                "legislation_phase": "coding", "legislation_step": len(self.plans)}

    def planning_brief(self, role):
        return {"system": "Perform one bounded coding operation.", "context": {"step": len(self.plans)},
                "schema": {"type": "object", "properties": {"action": {"const": "read"}},
                           "required": ["action"], "additionalProperties": False},
                "description": "Read the next source fragment.", "player_orders": False,
                "tool_name": "legislative_step" if role == "legislative_council" else "propose_plan",
                "output_tokens": 8192}

    def plan_rejected(self, role, reason, response=None):
        self.rejections.append((role, reason))


def completion(req, arguments='{"action":"read"}', finish="tool_calls", tool=None):
    raw = {"id": "coding-step", "choices": [{"finish_reason": finish, "message": {"role": "assistant", "tool_calls": [
        {"type": "function", "function": {"name": tool or req.tools[0].function.name,
                                             "arguments": arguments}}]}}]}
    return ChatCompletionResponse.model_validate(raw), {}, raw


def controlled_service(monkeypatch, forward, runtime_factory=CodingRuntime, calls=6):
    monkeypatch.setenv("AOE2_AI_BACKEND", "openai")
    service = MultiAgentService(forward=forward, runtime_factory=runtime_factory,
                                max_workers=1, calls_per_minute=calls, clock=lambda: 0)
    service._pool.shutdown()
    service._pool = ControlledPool()
    return service


def test_each_coding_step_uses_its_tool_effective_budget_and_normal_call_quota(monkeypatch):
    monkeypatch.setenv("AOE2_AI_LEGISLATION_MAX_TOKENS", "32768")
    monkeypatch.setenv("AOE2_AI_LEGISLATION_CONTEXT_TOKENS", "8192")
    sent = []

    def forward(req):
        sent.append(req)
        return completion(req)

    service = controlled_service(monkeypatch, forward, calls=2)
    try:
        for seq in (1, 2):
            service.tick(tick_request(seq, backend="openai"))
            assert len(service._pool.jobs) == 1
            service._pool.finish()
            assert not service._pool.jobs  # A completed step cannot launch an unbudgeted model loop.
        service.tick(tick_request(3, backend="openai"))
        assert not service._pool.jobs and len(sent) == 2
        assert [json.loads(req.messages[1].content)["step"] for req in sent] == [0, 1]
        for req in sent:
            assert req.tools[0].function.name == "legislative_step"
            assert req.tool_choice["function"]["name"] == "legislative_step"
            assert "using legislative_step" in req.messages[0].content
            assert req.max_tokens == 1024
            assert req.metadata.source_release == "source-a"
        session = service._sessions[("multi-test", 0)]
        assert session.runtime.plans == [("legislative_council", {"action": "read"})] * 2
        assert session.plan_status["legislative_council"]["legislation_phase"] == "coding"
        assert session.plan_status["legislative_council"]["legislation_step"] == 2
    finally:
        service.shutdown()


@pytest.mark.parametrize("role,expected", [("legislative_council", "applied"), ("premier_orders", "plan_expired")])
def test_only_coding_steps_survive_fast_game_time(monkeypatch, role, expected):
    monkeypatch.setattr(CodingRuntime, "role", role)
    service = controlled_service(monkeypatch, completion)
    try:
        service.tick(tick_request(backend="openai"))
        session = service._sessions[("multi-test", 0)]
        session.last_sim_time += 181
        service._pool.finish()
        assert session.plan_status[role]["state"] == expected
        assert len(session.runtime.plans) == (expected == "applied")
    finally:
        service.shutdown()


@pytest.mark.parametrize("role", ["legislative_council", "premier_orders"])
@pytest.mark.parametrize("kind,expected", [
    ("schema", "schema_validation_error"), ("truncated", "truncated_plan"),
    ("json", "invalid_json"), ("tool", "invalid_tool_calls"), ("transport", "transport_error:TimeoutError"),
])
def test_invalid_model_step_reports_actionable_retry_reason(monkeypatch, role, kind, expected):
    monkeypatch.setattr(CodingRuntime, "role", role)

    def forward(req):
        if kind == "transport":
            raise TimeoutError("provider unavailable")
        return completion(req, arguments='{}' if kind == "schema" else '{' if kind == "json" else '{"action":"read"}',
                          finish="length" if kind == "truncated" else "tool_calls",
                          tool="wrong_tool" if kind == "tool" else None)

    service = controlled_service(monkeypatch, forward)
    try:
        service.tick(tick_request(backend="openai"))
        session = service._sessions[("multi-test", 0)]
        service._pool.finish()
        assert len(session.runtime.rejections) == 1
        rejected_role, rejected_reason = session.runtime.rejections[0]
        assert rejected_role == role and rejected_reason.startswith(expected)
        if kind == "schema":
            assert "'action' is a required property" in rejected_reason
        assert not session.runtime.plans and not session.inflight
    finally:
        service.shutdown()


def test_observed_two_field_reply_gets_complete_feedback_and_corrected_reply_can_legislate(monkeypatch):
    class OrdersCabinet(CabinetRuntime):
        planning_roles = ("premier_orders",)

        def __init__(self, profile):
            super().__init__(profile)
            self.legislative_enabled = True

    malformed = {"grasp": "exact", "resolution": "legislation"}
    corrected = {"grasp": "exact", "resolution": "legislation", "thinking": "需要经济部增加农田布局算法。",
                 "decision": "提交农田紧贴布局需求。", "mandates": [],
                 "legislation": {"kind": "algorithm_gap", "departments": ["economy"],
                                 "evidence": ["现有任务书不能表达农田紧贴布局。"],
                                 "acceptance": {"positive": ["优先紧贴已有农田的合法位置。"],
                                                "negative": ["不得绕过合法施工候选限制。"]},
                                 "revoke_when": "玩家取消布局目标时撤销。"}}
    contexts = []

    def forward(req):
        contexts.append(json.loads(req.messages[1].content))
        return completion(req, json.dumps(malformed if len(contexts) == 1 else corrected))

    service = controlled_service(monkeypatch, forward, runtime_factory=OrdersCabinet)
    try:
        req = tick_request(backend="openai")
        req.observation.player_instructions = ["农田要贴在一起建造"]
        service.tick(req)
        service._pool.finish()
        session = service._sessions[("multi-test", 0)]
        assert session.runtime.ledger.pending() is not None
        assert session.plan_status["premier_orders"]["parse_state"] == "schema_validation_error"
        service.clock = lambda: 100
        req = tick_request(2, backend="openai")
        req.observation.player_instructions = ["农田要贴在一起建造"]
        service.tick(req)
        service._pool.finish()
        previous = contexts[1]["previous"]
        assert previous["response"] == malformed
        for missing in ("thinking", "decision", "mandates", "legislation"):
            assert f"'{missing}' is a required property" in previous["problem"]
        assert session.plan_status["premier_orders"]["state"] == "applied"
        requests = session.runtime.legislative_requests()
        assert len(requests) == 1 and requests[0]["instruction"] == "农田要贴在一起建造"
    finally:
        service.shutdown()


def test_decode_diagnostics_are_bounded_and_keep_the_three_value_contract():
    schema = {"type": "object", "properties": {f"needed_{i}": {"type": "string"} for i in range(20)},
              "required": [f"needed_{i}" for i in range(20)], "additionalProperties": False}
    malformed = {"oversized": "原回答" * 10000}
    req = tick_request()
    # completion only needs a named tool to construct the common response.
    from protocol.models import ChatTool, ChatToolFunction
    req.tools = [ChatTool(function=ChatToolFunction(name="propose_plan", parameters=schema))]
    first = completion(req, json.dumps(malformed))[0].choices[0]
    diagnostics = {}
    decoded = _decode_plan(first, schema, diagnostics=diagnostics)
    assert decoded == (None, "tool_call", "schema_validation_error")
    assert len(diagnostics["problem"]) <= 1500
    assert diagnostics["problem"].count(";") <= 3
    assert diagnostics["response"]["truncated"]
    assert len(diagnostics["response"]["response_preview"]) <= 4000


@pytest.mark.parametrize("change,expected", [
    ("instruction", "player_instructions_changed"), ("source", "source_release_changed"),
    ("closed", "session_closed"), ("match_over", "match_over"),
])
@pytest.mark.parametrize("failed", [False, True])
def test_obsolete_steps_never_change_or_retry_the_current_workspace(monkeypatch, change, expected, failed):
    def forward(req):
        # Change state while the model is in flight, before it returns or fails.
        if change == "instruction":
            session.instruction_revision += 1
        elif change == "source":
            session.runtime.release = "source-b"
        elif change == "closed":
            session.closed = True
        else:
            session.runtime.goals["match_over"] = True
        if failed:
            raise TimeoutError("provider unavailable")
        return completion(req)

    service = controlled_service(monkeypatch, forward)
    try:
        service.tick(tick_request(backend="openai"))
        session = service._sessions[("multi-test", 0)]
        service._pool.finish()
        assert not session.runtime.rejections and not session.runtime.plans
        if not failed:
            assert session.plan_status["legislative_council"]["state"] == expected
    finally:
        service.shutdown()


@pytest.mark.parametrize("failed", [False, True])
def test_premier_missing_legislation_and_transport_failure_get_repair_in_next_brief(monkeypatch, failed):
    class OrdersCabinet(CabinetRuntime):
        planning_roles = ("premier_orders",)

        def __init__(self, profile):
            super().__init__(profile)
            self.legislative_enabled = True

    def forward(req):
        if failed:
            raise TimeoutError("provider unavailable")
        return completion(req, json.dumps({"grasp": "guess", "thinking": "农田要紧贴，转交立法会。",
                                          "decision": "补农田布局算法。", "mandates": []}))

    service = controlled_service(monkeypatch, forward, runtime_factory=OrdersCabinet)
    try:
        req = tick_request(backend="openai")
        req.observation.player_instructions = ["让农田紧贴在一起"]
        service.tick(req)
        session = service._sessions[("multi-test", 0)]
        service._pool.finish()
        retry = session.runtime.planning_brief("premier_orders")["context"]
        assert retry["order"] == "让农田紧贴在一起"
        problem = retry["previous"]["problem"]
        assert "resolution=legislation" in problem and "mandates 可以为空" in problem
        assert ("transport_error:TimeoutError" if failed else "schema_validation_error") in problem
        assert session.runtime.ledger.pending() is not None
    finally:
        service.shutdown()
