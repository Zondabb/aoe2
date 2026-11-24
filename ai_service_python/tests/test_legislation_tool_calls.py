"""Provider multi-call replies can advance reads without executing a write batch."""
import copy
import json

import pytest

from brain.legislation.agent import CodingSession
from brain.multi_agent.scheduler import _decode_plan
from protocol.models import ChatCompletionResponse


def schema():
    session = object.__new__(CodingSession)
    session.requirement, session.base, session.data = {"proposal_id": "order-1"}, "a" * 64, {"steps": 1}
    return session.schema()


def action(kind, **args):
    return {"proposal_id": "order-1", "base_release": "a" * 64, "step": 1, "action": kind, **args}


def decode(actions, finish="tool_calls", names=None, tool="legislative_step"):
    calls = [{"type": "function", "function": {"name": names[i] if names else tool,
              "arguments": json.dumps(a) if isinstance(a, dict) else a}} for i, a in enumerate(actions)]
    first = ChatCompletionResponse.model_validate({"id": "multi", "choices": [{"finish_reason": finish,
        "message": {"role": "assistant", "tool_calls": calls}}]}).choices[0]
    diagnostics = {}
    return _decode_plan(first, schema(), tool, diagnostics=diagnostics), diagnostics


def test_observed_read_and_search_returns_one_read_with_explicit_unexecuted_calls():
    read = action("read", path="brain/cabinet/departments/economy.py", start_line=1)
    result, diagnostics = decode([read, action("search", query="boost_resource")])
    assert result == (read, "selected_readonly_tool_call", "valid")
    assert diagnostics["tool_selection"]["selected_call"] == 1
    assert diagnostics["tool_selection"]["unexecuted_calls"] == [1, 2]
    assert diagnostics["tool_selection"]["executed"] is False


def test_search_takes_precedence_over_repeating_a_directory_listing():
    search = action("search", query="construction_options")
    result, diagnostics = decode([action("list"), search])
    assert result[0] == search
    assert diagnostics["tool_selection"]["selected_call"] == 2


def test_missing_search_query_is_reported_without_discarding_a_valid_read():
    read = action("read", path="brain/cabinet/runtime.py", start_line=1)
    result, diagnostics = decode([read, action("search")])
    assert result[0] == read
    assert "'query' is a required property" in diagnostics["tool_selection"]["argument_errors"]


@pytest.mark.parametrize("key,value", [("proposal_id", "other"), ("base_release", "b" * 64), ("step", 2)])
def test_mixed_workspaces_or_steps_are_rejected_as_a_whole(key, value):
    foreign = {**action("search", query="farm"), key: value}
    result, diagnostics = decode([action("list"), foreign])
    assert result[0] is None and result[2] == "invalid_tool_calls"
    assert key in diagnostics["problem"]
    assert "tool_selection" not in diagnostics


@pytest.mark.parametrize("kind", ["edit", "finish", "blocked", "unknown"])
def test_mutating_or_terminal_multi_calls_are_never_partially_applied(kind):
    result, diagnostics = decode([action("list"), action(kind)])
    assert result[0] is None and result[2] == "invalid_tool_calls"
    assert "exactly ONE" in diagnostics["problem"]


def test_multi_call_selection_retains_strict_schema_limits_and_bounds_diagnostics():
    result, diagnostics = decode([action("read", path="x", start_line=0), action("search")])
    assert result[0] is None and result[2] == "invalid_tool_calls"
    assert "start_line" in diagnostics["problem"] and "query" in diagnostics["problem"]
    assert len(diagnostics["problem"]) <= 1500
    result, diagnostics = decode([action("list")] * 5)
    assert result[0] is None and "limit 4" in diagnostics["problem"]


@pytest.mark.parametrize("case", ["wrong_name", "invalid_json", "truncated", "ordinary_planner"])
def test_incomplete_or_unrelated_tool_envelopes_are_not_salvaged(case):
    actions = [action("list"), action("search", query="farm")]
    options = {}
    if case == "wrong_name":
        options["names"] = ["legislative_step", "unknown"]
    elif case == "invalid_json":
        actions[1] = "{"
    elif case == "truncated":
        options["finish"] = "length"
    else:
        options["tool"] = "propose_plan"
    result, diagnostics = decode(actions, **options)
    assert result[0] is None and "tool_selection" not in diagnostics


def test_selection_is_repeatable_and_does_not_mutate_the_source_calls():
    calls = [action("list"), action("read", path="brain/cabinet/runtime.py", start_line=1)]
    before = copy.deepcopy(calls)
    assert decode(calls) == decode(calls)
    assert calls == before


def test_stale_multi_call_is_neither_applied_nor_reported_as_executed(monkeypatch):
    from test_legislation_scheduler import CodingRuntime, controlled_service
    from test_multi_agent_scheduler import tick_request

    class PinnedRuntime(CodingRuntime):
        def planning_brief(self, role):
            brief = super().planning_brief(role)
            brief["schema"] = schema()
            return brief

        def planning_feedback(self, role, feedback):
            pytest.fail("Stale responses must not alter workspace feedback")

    def forward(req):
        service._sessions[("multi-test", 0)].instruction_revision += 1
        calls = [{"type": "function", "function": {"name": "legislative_step", "arguments": json.dumps(plan)}}
                 for plan in [action("list"), action("search", query="farm")]]
        raw = {"id": "stale", "choices": [{"finish_reason": "tool_calls", "message": {"role": "assistant", "tool_calls": calls}}]}
        return ChatCompletionResponse.model_validate(raw), {}, raw

    service = controlled_service(monkeypatch, forward, runtime_factory=PinnedRuntime)
    try:
        service.tick(tick_request(backend="openai"))
        service._pool.finish()
        session = service._sessions[("multi-test", 0)]
        assert not session.runtime.plans and not session.runtime.rejections
        status = session.plan_status["legislative_council"]
        assert status["state"] == "player_instructions_changed"
        assert status["tool_selection"]["executed"] is False
        assert status["tool_selection"]["unexecuted_calls"] == [1, 2]
    finally:
        service.shutdown()
