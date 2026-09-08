from __future__ import annotations

from typing import Any

import httpx

from brain import runtime_settings
from protocol.models import (
    ChatCompletionChoice,
    ChatCompletionRequest,
    ChatCompletionResponse,
    ChatMessage,
    ChatUsage,
)

DEFAULT_OPENAI_BASE = "https://api.openai.com/v1"


def is_openai_backend(name: str) -> bool:
    return name.strip().lower() in {"openai", "llm", "openai_compat"}


def resolve_backend(req: ChatCompletionRequest) -> str:
    env = runtime_settings.backend()
    if env:
        return env.lower()
    extra = req.metadata.model_dump()
    meta_backend = str(extra.get("backend", "")).strip()
    if meta_backend:
        return meta_backend.lower()
    return "rules_compat"


def llm_base_url(req: ChatCompletionRequest | None = None) -> str:
    env = runtime_settings.llm_base_url()
    if env:
        return env.rstrip("/")
    if req is not None:
        extra = req.metadata.model_dump()
        meta_url = str(extra.get("llm_base_url", "")).strip()
        if meta_url:
            return meta_url.rstrip("/")
    return DEFAULT_OPENAI_BASE.rstrip("/")


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


def build_openai_payload(req: ChatCompletionRequest) -> dict[str, Any]:
    """OpenAI-compatible body sent to the upstream LLM (for HTTP and debug logs)."""
    payload: dict[str, Any] = {
        "model": req.model,
        "stream": False,
        "temperature": req.temperature,
        "max_tokens": req.max_tokens,
        "messages": _messages_payload(req),
        "tool_choice": req.tool_choice,
        # "thinking": {"type": "disabled"},
    }
    if req.tools:
        payload["tools"] = _tools_payload(req)
    return payload


def forward_openai(
    req: ChatCompletionRequest,
) -> tuple[ChatCompletionResponse, dict[str, Any], dict[str, Any]]:
    token = llm_token()
    if not token:
        raise RuntimeError("missing_llm_token")
    url = f"{llm_base_url(req)}/chat/completions"
    payload = build_openai_payload(req)
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    raw = post_openai(url, headers, payload, llm_timeout_sec())
    return _normalize_openai_response(raw, req.model), payload, raw


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
