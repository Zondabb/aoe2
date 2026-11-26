"""Source generation has its own tool name and output budget on both backends."""
import json

import pytest

from brain import llm_proxy, runtime_settings
from protocol.models import ChatCompletionRequest


def request(tool="legislative_step"):
    return ChatCompletionRequest.model_validate({
        "model": "client-model", "messages": [{"role": "system", "content": "Return one code-agent step."}],
        "tools": [{"type": "function", "function": {"name": tool, "description": "One bounded step",
                    "parameters": {"type": "object", "properties": {"action": {"const": "read"}},
                                   "required": ["action"], "additionalProperties": False}}}],
        "tool_choice": {"type": "function", "function": {"name": tool}},
    })


@pytest.mark.parametrize("tool", ["propose_plan", "propose_source_patch", "legislative_step"])
def test_host_planners_disable_parallel_tool_calls_and_ignore_client_overrides(monkeypatch, tool):
    monkeypatch.setenv("AOE2_LLM_BASE_URL", "https://provider.example/v1")
    req = request(tool).model_copy(update={"parallel_tool_calls": True})
    req.metadata = req.metadata.model_copy(update={"parallel_tool_calls": True})
    payload = llm_proxy.build_openai_payload(req)
    assert payload["parallel_tool_calls"] is False
    assert payload["tool_choice"] == {"type": "function", "function": {"name": tool}}
    assert payload["tools"][0]["function"]["name"] == tool


@pytest.mark.parametrize("tool", ["propose_plan", "propose_source_patch", "legislative_step"])
def test_ollama_planners_keep_the_single_object_format_without_openai_options(monkeypatch, tool):
    monkeypatch.setenv("AOE2_LLM_BASE_URL", "http://127.0.0.1:11434/v1")
    req = request(tool)
    payload = llm_proxy.build_openai_payload(req)
    assert payload["format"] == req.tools[0].function.parameters
    assert "parallel_tool_calls" not in payload and "tools" not in payload
    assert "one JSON object" in payload["messages"][0]["content"]


@pytest.mark.parametrize("tool,choice", [
    ("lookup_unit", {"type": "function", "function": {"name": "lookup_unit"}}),
    ("legislative_step", "auto"),
    ("propose_plan", {"type": "function", "function": {"name": "other_tool"}}),
])
def test_non_planner_tool_requests_keep_existing_transport_options(monkeypatch, tool, choice):
    monkeypatch.setenv("AOE2_LLM_BASE_URL", "https://provider.example/v1")
    req = request(tool)
    req.tool_choice = choice
    payload = llm_proxy.build_openai_payload(req)
    assert "parallel_tool_calls" not in payload
    assert payload["tool_choice"] == choice


@pytest.mark.parametrize("tool", ["propose_source_patch", "legislative_step"])
def test_source_tool_has_dedicated_budget_and_ollama_schema(monkeypatch, tool):
    monkeypatch.setenv("AOE2_LLM_BASE_URL", "http://127.0.0.1:11434/v1")
    req = request(tool)
    payload = llm_proxy.build_openai_payload(req)
    assert payload["options"]["num_predict"] == 8192
    assert payload["options"]["num_ctx"] == 32768
    assert payload["format"] == req.tools[0].function.parameters
    plan = {"action": "read"}
    response = llm_proxy._normalize_ollama_plan_response(
        {"message": {"content": json.dumps(plan)}, "done": True, "usage": {}}, "model", tool)
    call = response.choices[0].message.tool_calls[0]["function"]
    assert call["name"] == tool and json.loads(call["arguments"]) == plan


@pytest.mark.parametrize("tool", ["propose_source_patch", "legislative_step"])
@pytest.mark.parametrize("native", [False, True])
def test_legislative_transport_uses_service_limits_not_global_or_request_overrides(monkeypatch, tool, native):
    monkeypatch.setenv("AOE2_LLM_BASE_URL", "http://127.0.0.1:11434/v1" if native else "https://provider.example/v1")
    monkeypatch.setenv("AOE2_LLM_MAX_TOKENS", "32768")
    monkeypatch.setenv("AOE2_LLM_NUM_CTX", "8192")
    monkeypatch.setenv("AOE2_AI_LEGISLATION_MAX_TOKENS", "4096")
    monkeypatch.setenv("AOE2_AI_LEGISLATION_CONTEXT_TOKENS", "24576")
    req = request(tool)
    req.max_tokens = 99999
    req.metadata = req.metadata.model_copy(update={"plan_output_tokens": 99999,
        "legislation_context_tokens": 99999, "legislation_max_tokens": 99999})
    payload = llm_proxy.build_openai_payload(req)
    if native:
        assert payload["options"]["num_predict"] == 4096
        assert payload["options"]["num_ctx"] == 24576
    else:
        assert payload["max_tokens"] == 4096
    # Ordinary plans still follow their existing operator-controlled budget.
    ordinary = llm_proxy.build_openai_payload(request("propose_plan"))
    if native:
        assert ordinary["options"]["num_predict"] == 256
        assert ordinary["options"]["num_ctx"] == 8192
    else:
        assert ordinary["max_tokens"] == 32768


@pytest.mark.parametrize("native", [False, True])
@pytest.mark.parametrize("context,expected", [(8192, 1024), (12288, 4096), (16384, 8192)])
def test_legislative_output_reserves_context_for_input(monkeypatch, native, context, expected):
    monkeypatch.setenv("AOE2_LLM_BASE_URL", "http://127.0.0.1:11434/v1" if native else "https://provider.example/v1")
    monkeypatch.setenv("AOE2_AI_LEGISLATION_MAX_TOKENS", "32768")
    monkeypatch.setenv("AOE2_AI_LEGISLATION_CONTEXT_TOKENS", str(context))
    assert runtime_settings.legislation_max_tokens() == 32768
    assert runtime_settings.legislation_output_tokens() == expected
    payload = llm_proxy.build_openai_payload(request())
    assert (payload["options"]["num_predict"] if native else payload["max_tokens"]) == expected
    if native:
        assert payload["options"]["num_ctx"] == context


@pytest.mark.parametrize("tool,expected", [("legislative_step", 175), ("propose_source_patch", 175), ("propose_plan", 45)])
@pytest.mark.parametrize("native", [False, True])
def test_forward_uses_dedicated_step_timeout(monkeypatch, tool, expected, native):
    monkeypatch.setenv("AOE2_LLM_BASE_URL", "http://127.0.0.1:11434/v1" if native else "https://provider.example/v1")
    monkeypatch.setenv("AOE2_LLM_TOKEN", "test-token")
    monkeypatch.setenv("AOE2_LLM_TIMEOUT_SEC", "45")
    monkeypatch.setenv("AOE2_AI_LEGISLATION_TIMEOUT_SEC", "175")
    captured = {}
    def post(url, headers, payload, timeout):
        captured.update(timeout=timeout, url=url)
        return {"done": True, "message": {"content": '{"action":"read"}'}} if native else {
            "choices": [{"finish_reason": "stop", "message": {"role": "assistant", "content": "{}"}}]}
    monkeypatch.setattr(llm_proxy, "post_openai", post)
    req = request(tool)
    req.metadata = req.metadata.model_copy(update={"legislation_timeout_sec": 99999, "llm_timeout_sec": 99999})
    llm_proxy.forward_openai(req)
    assert captured["timeout"] == expected


def test_legislative_limits_load_from_toml_and_environment(tmp_path, monkeypatch):
    path = tmp_path / "agent.toml"
    path.write_text('[ai]\nlegislation_timeout_sec=180\nlegislation_context_tokens=32768\n'
                    'legislation_max_steps=40\nlegislation_max_tokens=4096\n', encoding="utf-8")
    runtime_settings.load_config(path)
    assert runtime_settings.legislation_timeout_sec() == 180
    assert runtime_settings.legislation_context_tokens() == 32768
    assert runtime_settings.legislation_max_steps() == 40
    assert runtime_settings.legislation_max_tokens() == 4096
    monkeypatch.setenv("AOE2_AI_LEGISLATION_TIMEOUT_SEC", "150")
    assert runtime_settings.legislation_timeout_sec() == 150


@pytest.mark.parametrize("key, getter, default, low, high", [
    ("TIMEOUT_SEC", runtime_settings.legislation_timeout_sec, 120, 10, 600),
    ("CONTEXT_TOKENS", runtime_settings.legislation_context_tokens, 32768, 8192, 131072),
    ("MAX_STEPS", runtime_settings.legislation_max_steps, 24, 4, 100),
])
def test_legislative_limits_are_bounded(key, getter, default, low, high, monkeypatch):
    assert getter() == default
    for value, expected in (("bad", default), ("nan", default), ("-1", low), ("999999", high)):
        monkeypatch.setenv("AOE2_AI_LEGISLATION_" + key, value)
        assert getter() == expected
