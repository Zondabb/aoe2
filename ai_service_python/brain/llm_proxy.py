from __future__ import annotations

import json
from typing import Any
from urllib.parse import urlsplit

import httpx

from brain import runtime_settings
from protocol.models import (
    ChatCompletionChoice,
    ChatCompletionRequest,
    ChatCompletionResponse,
    ChatMessage,
    ChatUsage,
)

def is_openai_backend(name: str) -> bool:
    return name.strip().lower() in {"openai", "llm", "openai_compat"}


def resolve_backend(req: ChatCompletionRequest) -> str:
    # Legacy metadata remains accepted by the public protocol, but only the
    # service operator chooses which backend and upstream endpoint are used.
    return runtime_settings.backend().lower()


def upstream_model(req: ChatCompletionRequest) -> str:
    """The public request model is a protocol label, never an upstream override."""
    return runtime_settings.llm_model()


def llm_base_url(req: ChatCompletionRequest | None = None) -> str:
    return runtime_settings.llm_base_url().rstrip("/")


def llm_token() -> str:
    return runtime_settings.llm_token()


def llm_timeout_sec() -> float:
    return runtime_settings.llm_timeout_sec()


def post_openai(url: str, headers: dict[str, str], payload: dict[str, Any], timeout: float) -> dict[str, Any]:
    with httpx.Client(timeout=timeout) as client:
        response = client.post(url, headers=headers, json=payload)
        response.raise_for_status()
        body = response.json()
        if not isinstance(body, dict):
            raise ValueError("openai_response_not_object")
        return body


def _messages_payload(req: ChatCompletionRequest) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for msg in req.messages:
        item: dict[str, Any] = {"role": msg.role}
        if msg.content is not None:
            item["content"] = msg.content
        if msg.tool_calls:
            item["tool_calls"] = msg.tool_calls
        out.append(item)
    return out


def _tools_payload(req: ChatCompletionRequest) -> list[dict[str, Any]]:
    return [tool.model_dump() for tool in req.tools]


def _local_ollama_base_url() -> str | None:
    """Only the conventional loopback Ollama endpoint allows tokenless calls."""
    try:
        base = urlsplit(llm_base_url())
        if (base.scheme not in {"http", "https"}
                or base.hostname not in {"localhost", "127.0.0.1", "::1"}
                or base.port != 11434 or base.path not in {"", "/v1"}
                or base.username is not None or base.password is not None
                or base.query or base.fragment):
            return None
    except ValueError:
        return None
    return f"{base.scheme}://{base.netloc}"


def _ollama_plan_url(req: ChatCompletionRequest) -> str | None:
    """Use native structured output only for a local Ollama role-plan request."""
    if len(req.tools) != 1 or req.tools[0].function.name != "propose_plan":
        return None
    choice = req.tool_choice
    if (not isinstance(choice, dict) or choice.get("type") != "function"
            or choice.get("function") != {"name": "propose_plan"}):
        return None
    base = _local_ollama_base_url()
    return f"{base}/api/chat" if base else None


def _numeric_limits(schema: dict[str, Any]) -> str:
    """Ollama's format grammar enforces types and enums but not numeric bounds,
    and the native request carries no tool description the model could read."""
    limits = [f"{name} {rule['minimum']}..{rule['maximum']}" for name, rule in schema.get("properties", {}).items()
              if isinstance(rule, dict) and rule.get("type") in ("integer", "number")
              and "minimum" in rule and "maximum" in rule]
    return f" Numbers must stay within: {', '.join(limits)}." if limits else ""


def _build_ollama_plan_payload(req: ChatCompletionRequest) -> dict[str, Any]:
    messages = _messages_payload(req)
    instruction = ("Return only the propose_plan arguments as one JSON object matching the supplied "
                   "schema. Do not include commentary, markdown, or a tool-call wrapper."
                   + _numeric_limits(req.tools[0].function.parameters))
    if messages and messages[0]["role"] == "system":
        messages[0]["content"] = f"{messages[0].get('content') or ''}\n{instruction}"
    else:
        messages.insert(0, {"role": "system", "content": instruction})
    return {
        "model": upstream_model(req),
        "stream": False,
        "messages": messages,
        "format": req.tools[0].function.parameters,
        # Ollama's OpenAI endpoint does not support forced tool_choice, and
        # qwen3 can consume the entire generation budget on hidden reasoning.
        "think": False,
        "options": {
            "temperature": runtime_settings.llm_temperature(),
            "num_ctx": runtime_settings.llm_num_ctx(),
            "num_predict": min(256, runtime_settings.llm_max_tokens()),
        },
        "keep_alive": "10m",
    }


def build_openai_payload(req: ChatCompletionRequest) -> dict[str, Any]:
    """Actual upstream body, shared by HTTP forwarding and diagnostic logs."""
    if _ollama_plan_url(req) is not None:
        return _build_ollama_plan_payload(req)
    model = upstream_model(req)
    payload: dict[str, Any] = {
        "model": model,
        "stream": False,
        "temperature": runtime_settings.llm_temperature(),
        "max_tokens": runtime_settings.llm_max_tokens(),
        "messages": _messages_payload(req),
        "tool_choice": req.tool_choice,
    }
    if req.tools:
        payload["tools"] = _tools_payload(req)
    return payload


def forward_openai(
    req: ChatCompletionRequest,
) -> tuple[ChatCompletionResponse, dict[str, Any], dict[str, Any]]:
    token = llm_token()
    native_url = _ollama_plan_url(req)
    if not token and _local_ollama_base_url() is None:
        raise RuntimeError("missing_llm_token")
    url = native_url or f"{llm_base_url(req)}/chat/completions"
    payload = build_openai_payload(req)
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    raw = post_openai(url, headers, payload, llm_timeout_sec())
    if native_url is not None:
        # Preserve native duration/token fields while exposing the common usage
        # shape consumed by model_result logs and the public response.
        raw = dict(raw)
        raw["usage"] = {
            "prompt_tokens": int(raw.get("prompt_eval_count") or 0),
            "completion_tokens": int(raw.get("eval_count") or 0),
        }
        raw["usage"]["total_tokens"] = sum(raw["usage"].values())
        return _normalize_ollama_plan_response(raw, payload["model"]), payload, raw
    return _normalize_openai_response(raw, payload["model"]), payload, raw


def _normalize_ollama_plan_response(raw: dict[str, Any], fallback_model: str) -> ChatCompletionResponse:
    message = raw.get("message") if isinstance(raw.get("message"), dict) else {}
    content = message.get("content")
    calls = None
    finish = "length" if raw.get("done") is not True or raw.get("done_reason") == "length" else "stop"
    # Parse the entire response. Extracting a JSON fragment from explanatory
    # text would hide a failure of the structured-output contract.
    if isinstance(content, str) and raw.get("done") is True and finish != "length":
        try:
            plan = json.loads(content, parse_constant=_reject_json_constant)
            if isinstance(plan, dict):
                calls = [{"id": "call_propose_plan", "type": "function", "function": {
                    "name": "propose_plan", "arguments": content,
                }}]
                finish = "tool_calls"
        except (ValueError, TypeError):
            pass
    usage = raw["usage"]
    return ChatCompletionResponse(
        id="chatcmpl_ollama",
        model=str(raw.get("model") or fallback_model),
        choices=[ChatCompletionChoice(
            finish_reason=finish,
            message=ChatMessage(role="assistant", content=None if calls else content, tool_calls=calls),
        )],
        usage=ChatUsage(**usage),
    )


def _reject_json_constant(value: str) -> None:
    raise ValueError(f"invalid_json_constant:{value}")


def _normalize_openai_response(raw: dict[str, Any], fallback_model: str) -> ChatCompletionResponse:
    choices_in = raw.get("choices") or []
    choices: list[ChatCompletionChoice] = []
    for index, item in enumerate(choices_in):
        if not isinstance(item, dict):
            continue
        message = item.get("message") if isinstance(item.get("message"), dict) else {}
        finish = str(item.get("finish_reason") or "stop")
        if finish not in {"stop", "tool_calls", "length"}:
            finish = "tool_calls" if message.get("tool_calls") else "stop"
        choices.append(
            ChatCompletionChoice(
                index=int(item.get("index", index)),
                finish_reason=finish,  # type: ignore[arg-type]
                message=ChatMessage(
                    role=str(message.get("role") or "assistant"),  # type: ignore[arg-type]
                    content=message.get("content"),
                    tool_calls=message.get("tool_calls"),
                ),
            )
        )
    if not choices:
        choices.append(
            ChatCompletionChoice(
                message=ChatMessage(role="assistant", content=None, tool_calls=None)
            )
        )
    usage_raw = raw.get("usage") if isinstance(raw.get("usage"), dict) else {}
    return ChatCompletionResponse(
        id=str(raw.get("id") or "chatcmpl_openai"),
        model=str(raw.get("model") or fallback_model),
        choices=choices,
        usage=ChatUsage(
            prompt_tokens=int(usage_raw.get("prompt_tokens") or 0),
            completion_tokens=int(usage_raw.get("completion_tokens") or 0),
            total_tokens=int(usage_raw.get("total_tokens") or 0),
        ),
    )
