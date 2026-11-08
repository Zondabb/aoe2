from __future__ import annotations

import copy
import json

import pytest

from brain import llm_proxy, runtime_settings
from protocol.models import ChatCompletionRequest


PLAN_SCHEMA = {
    "type": "object",
    "properties": {"stance": {"type": "string", "enum": ["balanced", "pressure", "defend"]}},
    "required": ["stance"],
    "additionalProperties": False,
}


@pytest.fixture(autouse=True)
def isolated_settings(monkeypatch):
    runtime_settings.clear_cli()
    for name in ("AOE2_LLM_TOKEN", "AOE2_LLM_BASE_URL", "AOE2_LLM_MODEL", "AOE2_LLM_NUM_CTX"):
        monkeypatch.delenv(name, raising=False)
    yield
    runtime_settings.clear_cli()


def plan_request() -> ChatCompletionRequest:
    return ChatCompletionRequest.model_validate({
        "model": "qwen3:8b",
        "messages": [
            {"role": "system", "content": "Choose a stance using propose_plan."},
            {"role": "user", "content": '{"role":"commander"}'},
        ],
        "tools": [{"type": "function", "function": {
            "name": "propose_plan", "description": "Update the commander plan.", "parameters": PLAN_SCHEMA,
        }}],
        "tool_choice": {"type": "function", "function": {"name": "propose_plan"}},
    })


def test_local_ollama_sends_schema_and_native_thinking_controls(monkeypatch):
    monkeypatch.setenv("AOE2_LLM_BASE_URL", "http://127.0.0.1:11434/v1")
    monkeypatch.setenv("AOE2_LLM_MODEL", "qwen3:8b-override")
    req = plan_request()
    before = req.model_dump()
    captured = {}
    native_raw = {
        "model": "qwen3:8b-override",
        "message": {"role": "assistant", "content": '{"stance":"pressure"}'},
        "done": True,
        "done_reason": "stop",
        "prompt_eval_count": 2700,
        "eval_count": 9,
        "total_duration": 123456,
        "prompt_eval_duration": 1234,
    }

    def post(url, headers, payload, timeout):
        captured.update(url=url, headers=headers, payload=copy.deepcopy(payload))
        return native_raw

    monkeypatch.setattr(llm_proxy, "post_openai", post)
    expected_payload = llm_proxy.build_openai_payload(req)
    response, sent, raw = llm_proxy.forward_openai(req)
    assert captured["url"] == "http://127.0.0.1:11434/api/chat"
    assert sent == captured["payload"] == expected_payload
    assert sent["model"] == "qwen3:8b-override"
    assert sent["format"] == PLAN_SCHEMA
    assert sent["think"] is False and sent["stream"] is False
    assert sent["options"] == {"temperature": 0.2, "num_ctx": 8192, "num_predict": 256}
    assert sent["keep_alive"] == "10m"
    assert "tools" not in sent and "tool_choice" not in sent and "max_tokens" not in sent
    assert "Return only the propose_plan arguments" in sent["messages"][0]["content"]
    assert "Numbers must stay within" not in sent["messages"][0]["content"]
    assert req.model_dump() == before
    choice = response.choices[0]
    assert choice.finish_reason == "tool_calls"
    call = choice.message.tool_calls[0]
    assert call["function"]["name"] == "propose_plan"
    assert json.loads(call["function"]["arguments"]) == {"stance": "pressure"}
    assert response.usage.model_dump() == {"prompt_tokens": 2700, "completion_tokens": 9, "total_tokens": 2709}
    assert raw["total_duration"] == 123456 and raw["prompt_eval_duration"] == 1234
    assert raw["usage"] == response.usage.model_dump()
    assert "usage" not in native_raw


def test_local_ollama_prompt_states_numeric_ranges(monkeypatch):
    # The format grammar enforces types and enums but not numeric bounds.
    monkeypatch.setenv("AOE2_LLM_BASE_URL", "http://127.0.0.1:11434/v1")
    req = plan_request()
    req.tools[0].function.parameters = {"type": "object", "additionalProperties": False,
        "required": ["worker_target", "food_workers_ratio", "stance"], "properties": {
            "worker_target": {"type": "integer", "minimum": 8, "maximum": 60},
            "food_workers_ratio": {"type": "number", "minimum": .2, "maximum": .65},
            "stance": {"type": "string", "enum": ["balanced"]}}}
    system = llm_proxy.build_openai_payload(req)["messages"][0]["content"]
    assert system.endswith("Numbers must stay within: worker_target 8..60, food_workers_ratio 0.2..0.65.")


@pytest.mark.parametrize("base", [
    "http://localhost:11434", "http://localhost:11434/v1/", "http://[::1]:11434/v1",
])
def test_other_loopback_ollama_urls_use_native(base, monkeypatch):
    monkeypatch.setenv("AOE2_LLM_BASE_URL", base)
    assert llm_proxy.build_openai_payload(plan_request())["format"] == PLAN_SCHEMA


@pytest.mark.parametrize("base", [
    "https://api.openai.com/v1", "http://localhost:8080/v1", "http://127.0.0.1.evil.test:11434/v1",
    "http://localhost.evil.test:11434/v1", "http://evil.test:11434/127.0.0.1",
    "http://127.0.0.1:11434/proxy/v1", "http://user@127.0.0.1:11434/v1",
    "http://127.0.0.1:11434/v1?api_key=secret", "http://127.0.0.1:invalid/v1",
])
def test_non_ollama_urls_retain_openai_payload(base, monkeypatch):
    monkeypatch.setenv("AOE2_LLM_BASE_URL", base)
    sent = llm_proxy.build_openai_payload(plan_request())
    assert sent["tool_choice"]["function"]["name"] == "propose_plan"
    assert "format" not in sent and "think" not in sent


@pytest.mark.parametrize("change", ["no_tools", "other_tool", "multiple_tools", "auto_choice"])
def test_legacy_local_requests_retain_openai_transport(change, monkeypatch):
    monkeypatch.setenv("AOE2_LLM_BASE_URL", "http://127.0.0.1:11434/v1")
    monkeypatch.setenv("AOE2_LLM_TOKEN", "ollama")
    req = plan_request()
    if change == "no_tools":
        req.tools = []
    elif change == "other_tool":
        req.tools[0].function.name = "gather"
    elif change == "multiple_tools":
        req.tools.append(req.tools[0].model_copy(deep=True))
    else:
        req.tool_choice = "auto"
    captured = {}

    def post(url, headers, payload, timeout):
        captured.update(url=url, payload=payload)
        return {"choices": [{"message": {"role": "assistant", "content": "ok"}}]}

    monkeypatch.setattr(llm_proxy, "post_openai", post)
    response, sent, _raw = llm_proxy.forward_openai(req)
    assert captured["url"] == "http://127.0.0.1:11434/v1/chat/completions"
    assert sent == captured["payload"] and "format" not in sent
    assert response.choices[0].message.content == "ok"


@pytest.mark.parametrize("content", [
    'I recommend {"stance":"pressure"}', '```json\n{"stance":"pressure"}\n```',
    '{"stance":"pressure"} explanation', '{"stance":"pressure"',
    '[{"stance":"pressure"}]', 'null', '{"stance":NaN}',
])
def test_native_invalid_output_is_preserved_and_never_becomes_a_tool_call(content, monkeypatch):
    monkeypatch.setenv("AOE2_LLM_BASE_URL", "http://127.0.0.1:11434/v1")
    monkeypatch.setattr(llm_proxy, "post_openai", lambda *_: {
        "message": {"content": content}, "done": True, "done_reason": "stop",
    })
    response, _sent, raw = llm_proxy.forward_openai(plan_request())
    assert response.choices[0].message.content == content
    assert response.choices[0].message.tool_calls is None
    assert raw["message"]["content"] == content


@pytest.mark.parametrize("native_extra, expected_finish", [
    ({"done": True, "done_reason": "length"}, "length"),
    ({"done": False}, "length"),
])
def test_native_incomplete_output_is_not_applied(native_extra, expected_finish, monkeypatch):
    monkeypatch.setenv("AOE2_LLM_BASE_URL", "http://127.0.0.1:11434/v1")
    monkeypatch.setattr(llm_proxy, "post_openai", lambda *_: {
        "message": {"content": '{"stance":"pressure"}'}, **native_extra,
    })
    response, _sent, _raw = llm_proxy.forward_openai(plan_request())
    assert response.choices[0].finish_reason == expected_finish
    assert response.choices[0].message.tool_calls is None


@pytest.mark.parametrize("configured, expected", [("4096", 4096), ("bad", 8192), ("-5", 2048), ("999999", 32768)])
def test_native_context_setting_is_explicit_and_bounded(configured, expected, monkeypatch):
    monkeypatch.setenv("AOE2_LLM_BASE_URL", "http://127.0.0.1:11434/v1")
    monkeypatch.setenv("AOE2_LLM_NUM_CTX", configured)
    req = plan_request()
    req.max_tokens = 100
    monkeypatch.setenv("AOE2_LLM_MAX_TOKENS", "100")
    options = llm_proxy.build_openai_payload(req)["options"]
    assert options["num_ctx"] == expected
    assert options["num_predict"] == 100


def test_remote_openai_still_requires_token(monkeypatch):
    monkeypatch.setenv("AOE2_LLM_BASE_URL", "https://api.openai.com/v1")
    with pytest.raises(RuntimeError, match="missing_llm_token"):
        llm_proxy.forward_openai(plan_request())


def test_service_settings_ignore_legacy_client_overrides(monkeypatch):
    monkeypatch.setenv("AOE2_AI_BACKEND", "openai")
    monkeypatch.setenv("AOE2_LLM_BASE_URL", "https://service-provider.example/v1")
    monkeypatch.setenv("AOE2_LLM_MODEL", "service-model")
    monkeypatch.setenv("AOE2_LLM_MAX_TOKENS", "700")
    monkeypatch.setenv("AOE2_LLM_TEMPERATURE", "0.4")
    req = plan_request()
    req.model = "untrusted-client-model"
    req.max_tokens = 30000
    req.temperature = 2
    req.metadata = req.metadata.model_copy(update={
        "backend": "rules_compat", "llm_base_url": "http://untrusted-client.example/v1",
    })
    before = req.model_dump()
    assert llm_proxy.resolve_backend(req) == "openai"
    assert llm_proxy.llm_base_url(req) == "https://service-provider.example/v1"
    sent = llm_proxy.build_openai_payload(req)
    assert sent["model"] == "service-model"
    assert sent["temperature"] == 0.4
    assert sent["max_tokens"] == 700
    assert req.model_dump() == before


def test_local_ollama_legacy_chat_needs_no_placeholder_token(monkeypatch):
    monkeypatch.setenv("AOE2_LLM_BASE_URL", "http://127.0.0.1:11434/v1")
    req = plan_request()
    req.tools = []
    captured = {}

    def post(url, headers, payload, timeout):
        captured.update(url=url, headers=headers)
        return {"choices": [{"message": {"role": "assistant", "content": "ok"}}]}

    monkeypatch.setattr(llm_proxy, "post_openai", post)
    response, _, _ = llm_proxy.forward_openai(req)
    assert response.choices[0].message.content == "ok"
    assert captured["url"] == "http://127.0.0.1:11434/v1/chat/completions"
    assert "Authorization" not in captured["headers"]
