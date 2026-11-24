"""Action-specific required arguments survive provider formatting and decode."""
import json

import pytest
from jsonschema import Draft202012Validator

from brain import llm_proxy, runtime_settings
from brain.legislation.agent import CodingSession
from brain.legislation.tools import ACTION_TOOLS, action_tools
from brain.multi_agent.scheduler import plan_request, _decode_plan
from protocol.models import ChatCompletionRequest, ChatCompletionResponse


def request():
    session = object.__new__(CodingSession)
    session.requirement, session.base, session.data = {"proposal_id": "order-1"}, "a" * 64, {"steps": 7}
    schema = session.schema()
    brief = {"system": "One coding operation", "context": {}, "schema": schema, "tools": action_tools(schema),
             "description": "Coding", "output_tokens": 8192, "orders": (), "statuses": []}
    req, _ = plan_request(ChatCompletionRequest(model="client", messages=[]), "legislative_council", brief, "test")
    return req, schema


def decode(name, arguments, finish="tool_calls"):
    arguments = {"note": "Inspect current contract and continue", **arguments}
    req, schema = request()
    first = ChatCompletionResponse.model_validate({"id": "test", "choices": [{"finish_reason": finish, "message": {
        "role": "assistant", "tool_calls": [{"function": {"name": name, "arguments": json.dumps(arguments)}}]}}]}).choices[0]
    diagnostics = {}
    result = _decode_plan(first, schema, diagnostics=diagnostics,
                          tool_schemas={t.function.name: t.function.parameters for t in req.tools})
    return result, diagnostics


@pytest.mark.parametrize("name,required", [
    ("search", {"query"}), ("read", {"path", "start_line"}),
    ("edit", {"path", "sha256", "old_text", "new_text"}),
    ("finish", {"state_fields", "explanation"}), ("blocked", {"explanation"})])
def test_each_action_has_direct_required_arguments_without_conditionals(name, required):
    req, _ = request()
    schema = next(t.function.parameters for t in req.tools if t.function.name == ACTION_TOOLS[name])
    assert set(schema["required"]) == required | {"note"}
    assert not {"oneOf", "anyOf", "allOf", "if", "then"} & set(schema)
    assert not {"step", "proposal_id", "base_release", "action"} & set(schema["properties"])
    assert not Draft202012Validator(schema).is_valid({})


@pytest.mark.parametrize("name,args", [("search", {"query": "farm"}),
    ("read", {"path": "brain/cabinet/departments/economy.py", "start_line": 1}),
    ("edit", {"path": "brain/cabinet/departments/economy.py", "sha256": "b" * 64, "old_text": "return 1", "new_text": "return 2"}),
    ("finish", {"state_fields": [], "explanation": "ready"}), ("blocked", {"explanation": "No legal adjacent positions"})])
def test_host_binds_identity_and_preserves_strict_action_validation(name, args):
    (plan, _, state), _ = decode(ACTION_TOOLS[name], args)
    assert state == "valid"
    assert plan == {**args, "note": "Inspect current contract and continue", "action": name, "proposal_id": "order-1", "base_release": "a" * 64, "step": 7}


@pytest.mark.parametrize("name,args,field", [("search", {}, "query"), ("read", {}, "path"),
    ("search", {"query": "farm", "step": 8}, "unsupported")])
def test_incomplete_arguments_and_identity_injection_are_rejected(name, args, field):
    result, diagnostic = decode(ACTION_TOOLS[name], args)
    assert result[0] is None and result[2] == "schema_validation_error"
    assert field in diagnostic["problem"]


def test_nonfinite_and_truncated_edits_never_apply():
    assert decode("legislative_finish", {"state_fields": [{"department": "economy", "name": "x", "type": "float", "default": float("nan")}], "explanation": "x"})[0][2] == "invalid_json"
    assert decode("legislative_edit", {}, finish="length")[0][2] == "truncated_plan"


@pytest.mark.parametrize("native", [False, True])
def test_both_transports_use_action_contracts_and_independent_limits(monkeypatch, native):
    monkeypatch.setenv("AOE2_LLM_BASE_URL", "http://127.0.0.1:11434/v1" if native else "https://provider.example/v1")
    req, _ = request()
    payload = llm_proxy.build_openai_payload(req)
    assert llm_proxy.is_legislative_request(req)
    if native:
        assert len(payload["format"]["oneOf"]) == 6
        assert all("properties" in branch and "required" in branch for branch in payload["format"]["oneOf"])
        assert Draft202012Validator(payload["format"]).is_valid({"action": "search", "query": "farm", "note": "Find caller"})
        assert not Draft202012Validator(payload["format"]).is_valid({"action": "search"})
        assert payload["options"]["num_predict"] == runtime_settings.legislation_output_tokens()
    else:
        assert payload["parallel_tool_calls"] is False and payload["tool_choice"] == "auto"
        assert len(payload["tools"]) == 6
        assert payload["max_tokens"] == runtime_settings.legislation_output_tokens()


def test_ollama_native_response_selects_the_action_tool_before_common_validation():
    req, schema = request()
    raw = {"done": True, "usage": {}, "message": {"content": '{"action":"search","query":"farm","note":"Find caller"}'}}
    response = llm_proxy._normalize_ollama_plan_response(raw, "model", action_names=[t.function.name for t in req.tools])
    call = response.choices[0].message.tool_calls[0]["function"]
    assert call["name"] == "legislative_search" and json.loads(call["arguments"]) == {"query": "farm", "note": "Find caller"}
    plan, _, state = _decode_plan(response.choices[0], schema,
        tool_schemas={t.function.name: t.function.parameters for t in req.tools})
    assert state == "valid" and plan["step"] == 7
