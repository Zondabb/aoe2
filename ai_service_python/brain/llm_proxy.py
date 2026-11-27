from __future__ import annotations

import json
from typing import Any
from urllib.parse import quote, urlsplit

import httpx

from brain import runtime_settings
from brain.legislation.tools import ACTION_TOOLS, TOOL_ACTIONS, is_action_tools, native_schema
from protocol.models import (
    ChatCompletionChoice,
    ChatCompletionRequest,
    ChatCompletionResponse,
    ChatMessage,
    ChatUsage,
)

def is_openai_backend(name: str) -> bool:
    return name.strip().lower() in {"openai", "llm", "openai_compat", "gemini", "google"}


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


LEGISLATIVE_TOOLS = frozenset(("propose_source_patch", "legislative_step"))
PLANNER_TOOLS = LEGISLATIVE_TOOLS | {"propose_plan"}


def is_legislative_request(req: ChatCompletionRequest) -> bool:
    """Recognize the host's code tools, without trusting client budget metadata."""
    return (len(req.tools) == 1 and req.tools[0].function.name in LEGISLATIVE_TOOLS
            or is_action_tools(t.function.name for t in req.tools))


def _is_planner_request(req: ChatCompletionRequest) -> bool:
    """Recognize the host's single forced planner function, not arbitrary tools."""
    if is_action_tools(t.function.name for t in req.tools) and req.tool_choice in ("auto", "required"):
        return True
    if len(req.tools) != 1 or req.tools[0].function.name not in PLANNER_TOOLS:
        return False
    choice = req.tool_choice
    return (isinstance(choice, dict) and choice.get("type") == "function"
            and choice.get("function") == {"name": req.tools[0].function.name})


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
    if not _is_planner_request(req):
        return None
    base = _local_ollama_base_url()
    return f"{base}/api/chat" if base else None


# A plan is a handful of short fields. A planner that also writes text for the
# player (the cabinet's premier) asks the service for more through the request
# metadata, within these bounds; the service sets that field, never the client.
PLAN_OUTPUT_TOKENS, PLAN_OUTPUT_TOKENS_RANGE = 256, (64, 1024)
THINKING_OUTPUT_TOKENS = 4096


def _plan_output_tokens(req: ChatCompletionRequest) -> int:
    if is_legislative_request(req):
        return runtime_settings.legislation_output_tokens()
    asked = getattr(getattr(req, "metadata", None), "plan_output_tokens", None)
    low, high = PLAN_OUTPUT_TOKENS_RANGE
    if isinstance(asked, int) and low <= asked <= high:
        return asked
    return PLAN_OUTPUT_TOKENS


def _numeric_limits(schema: dict[str, Any]) -> str:
    """Ollama's format grammar enforces types and enums but not numeric bounds,
    and the native request carries no tool description the model could read."""
    limits = [f"{name} {rule['minimum']}..{rule['maximum']}" for name, rule in schema.get("properties", {}).items()
              if isinstance(rule, dict) and rule.get("type") in ("integer", "number")
              and "minimum" in rule and "maximum" in rule]
    return f" Numbers must stay within: {', '.join(limits)}." if limits else ""


def _build_ollama_plan_payload(req: ChatCompletionRequest) -> dict[str, Any]:
    messages = _messages_payload(req)
    typed = is_action_tools(t.function.name for t in req.tools)
    format_schema = native_schema(req.tools) if typed else req.tools[0].function.parameters
    instruction = (f"Return only the {req.tools[0].function.name} arguments as one JSON object matching the supplied "
                   "schema. Do not include commentary, markdown, or a tool-call wrapper."
                   + _numeric_limits(req.tools[0].function.parameters))
    if typed:
        actions = "; ".join(f"{TOOL_ACTIONS[t.function.name]} ({t.function.description}"
                            f"{_numeric_limits(t.function.parameters)})" for t in req.tools)
        instruction = ("Return exactly one JSON object for one action matching a complete schema branch. "
                       "Put \"action\" first, then \"note\" and all required arguments; no commentary or tool-call wrapper. "
                       f"Actions: {actions}")
    if messages and messages[0]["role"] == "system":
        messages[0]["content"] = f"{messages[0].get('content') or ''}\n{instruction}"
    else:
        messages.insert(0, {"role": "system", "content": instruction})
    legislative = is_legislative_request(req)
    think = runtime_settings.llm_think()
    num_ctx = runtime_settings.legislation_context_tokens() if legislative else runtime_settings.llm_num_ctx()
    if legislative:
        num_predict = runtime_settings.legislation_output_tokens()
    elif think:
        num_predict = min(_plan_output_tokens(req) + THINKING_OUTPUT_TOKENS,
                          runtime_settings.llm_max_tokens(), max(1024, num_ctx // 2))
    else:
        num_predict = min(_plan_output_tokens(req), runtime_settings.llm_max_tokens())
    return {
        "model": upstream_model(req),
        "stream": False,
        "messages": messages,
        "format": format_schema,
        # Ollama's OpenAI endpoint does not support forced tool_choice; native
        # /api/chat supports explicit thinking control with a dedicated budget.
        "think": think,
        "options": {
            "temperature": runtime_settings.llm_temperature(),
            "num_ctx": num_ctx,
            "num_predict": num_predict,
        },
        "keep_alive": "10m",
    }


def _deepseek_forced_tool_thinking(tool_choice: Any) -> dict[str, str] | None:
    """DeepSeek rejects a named or required tool_choice while thinking is on.

    Its flash models enable thinking unless the request turns it off. Other
    OpenAI-compatible hosts do not understand this field, so leave them alone.
    """
    host = urlsplit(llm_base_url()).hostname
    forced = tool_choice == "required" or (
        isinstance(tool_choice, dict) and tool_choice.get("type") == "function")
    if host != "api.deepseek.com" or not forced:
        return None
    return {"type": "disabled"}


def _gemini_generate_url(req: ChatCompletionRequest) -> str | None:
    raw_base = llm_base_url(req)
    base = urlsplit(raw_base)
    explicit = runtime_settings.backend().strip().lower() in {"gemini", "google"}
    is_google_host = (
        base.hostname == "generativelanguage.googleapis.com"
        and not base.path.rstrip("/").endswith("/openai")
    )
    if not (explicit or is_google_host):
        return None
    if raw_base.endswith(":generateContent"):
        return raw_base
    model = upstream_model(req).strip()
    if model.startswith("models/"):
        model = model[len("models/"):]
    model_seg = quote(model, safe="-_.")
    path = base.path.rstrip("/")
    if path == "":
        return f"{raw_base}/v1beta/models/{model_seg}:generateContent"
    if path in {"/v1beta/models", "/v1/models"} or path.endswith("/models"):
        return f"{raw_base}/{model_seg}:generateContent"
    return f"{raw_base}/models/{model_seg}:generateContent"


def _gemini_tool_config(tool_choice: Any) -> dict[str, Any] | None:
    if tool_choice == "none":
        return {"functionCallingConfig": {"mode": "NONE"}}
    if tool_choice == "auto":
        return {"functionCallingConfig": {"mode": "AUTO"}}
    if tool_choice == "required":
        return {"functionCallingConfig": {"mode": "ANY"}}
    if isinstance(tool_choice, dict) and tool_choice.get("type") == "function":
        fn = tool_choice.get("function")
        name = fn.get("name") if isinstance(fn, dict) else None
        if isinstance(name, str) and name:
            return {"functionCallingConfig": {"mode": "ANY", "allowedFunctionNames": [name]}}
    return None


def _build_gemini_payload(req: ChatCompletionRequest) -> dict[str, Any]:
    system_parts: list[str] = []
    contents: list[dict[str, Any]] = []
    for msg in req.messages:
        if msg.role == "system":
            if msg.content:
                system_parts.append(msg.content)
            continue
        role = "model" if msg.role == "assistant" else "user"
        parts: list[dict[str, Any]] = []
        if msg.content:
            parts.append({"text": msg.content})
        if msg.role == "assistant" and msg.tool_calls:
            for call in msg.tool_calls:
                if not isinstance(call, dict):
                    continue
                fn = call.get("function")
                if not isinstance(fn, dict) or not fn.get("name"):
                    continue
                raw_args = fn.get("arguments")
                if isinstance(raw_args, str):
                    try:
                        parsed = json.loads(raw_args)
                    except (ValueError, TypeError):
                        parsed = {}
                    args = parsed if isinstance(parsed, dict) else {}
                elif isinstance(raw_args, dict):
                    args = raw_args
                else:
                    args = {}
                parts.append({"functionCall": {"name": str(fn["name"]), "args": args}})
        if not parts:
            continue
        if contents and contents[-1]["role"] == role:
            contents[-1]["parts"].extend(parts)
        else:
            contents.append({"role": role, "parts": parts})
    if not contents:
        contents = [{"role": "user", "parts": [{"text": "Proceed."}]}]
    max_output_tokens = (
        runtime_settings.legislation_output_tokens()
        if is_legislative_request(req)
        else runtime_settings.llm_max_tokens()
    )
    payload: dict[str, Any] = {
        "contents": contents,
        "generationConfig": {
            "temperature": runtime_settings.llm_temperature(),
            "maxOutputTokens": max_output_tokens,
        },
    }
    if system_parts:
        payload["systemInstruction"] = {"parts": [{"text": "\n\n".join(system_parts)}]}
    if req.tools:
        declarations: list[dict[str, Any]] = []
        for tool in req.tools:
            decl: dict[str, Any] = {"name": tool.function.name}
            if tool.function.description:
                decl["description"] = tool.function.description
            if tool.function.parameters:
                decl["parametersJsonSchema"] = tool.function.parameters
            declarations.append(decl)
        payload["tools"] = [{"functionDeclarations": declarations}]
        tool_config = _gemini_tool_config(req.tool_choice)
        if tool_config is not None:
            payload["toolConfig"] = tool_config
    return payload


def build_openai_payload(req: ChatCompletionRequest) -> dict[str, Any]:
    """Actual upstream body, shared by HTTP forwarding and diagnostic logs."""
    if _gemini_generate_url(req) is not None:
        return _build_gemini_payload(req)
    if _ollama_plan_url(req) is not None:
        return _build_ollama_plan_payload(req)
    model = upstream_model(req)
    payload: dict[str, Any] = {
        "model": model,
        "stream": False,
        "temperature": runtime_settings.llm_temperature(),
        "max_tokens": runtime_settings.legislation_output_tokens()
                      if is_legislative_request(req) else runtime_settings.llm_max_tokens(),
        "messages": _messages_payload(req),
        "tool_choice": req.tool_choice,
    }
    if req.tools:
        payload["tools"] = _tools_payload(req)
    if _is_planner_request(req):
        # Each planner turn is bound to one state/version. Asking the provider
        # explicitly avoids speculative read/edit calls in the same response.
        payload["parallel_tool_calls"] = False
    thinking = _deepseek_forced_tool_thinking(req.tool_choice)
    if thinking is not None:
        payload["thinking"] = thinking
    return payload


def forward_openai(
    req: ChatCompletionRequest,
) -> tuple[ChatCompletionResponse, dict[str, Any], dict[str, Any]]:
    token = llm_token()
    gemini_url = _gemini_generate_url(req)
    if gemini_url is not None:
        if not token:
            raise RuntimeError("missing_llm_token")
        payload = _build_gemini_payload(req)
        headers = {"Content-Type": "application/json", "X-goog-api-key": token}
        timeout = runtime_settings.legislation_timeout_sec() if is_legislative_request(req) else llm_timeout_sec()
        raw = post_openai(gemini_url, headers, payload, timeout)
        raw = dict(raw)
        raw["usage"] = _gemini_usage(raw)
        return _normalize_gemini_response(raw, upstream_model(req)), payload, raw
    native_url = _ollama_plan_url(req)
    if not token and _local_ollama_base_url() is None:
        raise RuntimeError("missing_llm_token")
    url = native_url or f"{llm_base_url(req)}/chat/completions"
    payload = build_openai_payload(req)
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    timeout = runtime_settings.legislation_timeout_sec() if is_legislative_request(req) else llm_timeout_sec()
    raw = post_openai(url, headers, payload, timeout)
    if native_url is not None:
        # Preserve native duration/token fields while exposing the common usage
        # shape consumed by model_result logs and the public response.
        raw = dict(raw)
        raw["usage"] = {
            "prompt_tokens": int(raw.get("prompt_eval_count") or 0),
            "completion_tokens": int(raw.get("eval_count") or 0),
        }
        raw["usage"]["total_tokens"] = sum(raw["usage"].values())
        names = [t.function.name for t in req.tools]
        return _normalize_ollama_plan_response(raw, payload["model"], req.tools[0].function.name,
                                              action_names=names if is_action_tools(names) else None), payload, raw
    return _normalize_openai_response(raw, payload["model"]), payload, raw


def _normalize_ollama_plan_response(raw: dict[str, Any], fallback_model: str, tool_name: str = "propose_plan", *,
                                  action_names: list[str] | None = None) -> ChatCompletionResponse:
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
                if action_names is not None:
                    tool_name = ACTION_TOOLS.get(plan.pop("action", None), "")
                    if tool_name not in action_names:
                        raise ValueError("unknown_coding_action")
                    content = json.dumps(plan, ensure_ascii=False, allow_nan=False)
                calls = [{"id": "call_propose_plan", "type": "function", "function": {
                    "name": tool_name, "arguments": content,
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


def _gemini_usage(raw: dict[str, Any]) -> dict[str, int]:
    meta = raw.get("usageMetadata") if isinstance(raw.get("usageMetadata"), dict) else {}
    prompt = int(meta.get("promptTokenCount") or 0)
    completion = int(meta.get("candidatesTokenCount") or 0) + int(meta.get("thoughtsTokenCount") or 0)
    total = int(meta.get("totalTokenCount") or (prompt + completion))
    return {"prompt_tokens": prompt, "completion_tokens": completion, "total_tokens": total}


def _normalize_gemini_response(raw: dict[str, Any], fallback_model: str) -> ChatCompletionResponse:
    choices: list[ChatCompletionChoice] = []
    for index, cand in enumerate(raw.get("candidates") or []):
        if not isinstance(cand, dict):
            continue
        content_obj = cand.get("content") if isinstance(cand.get("content"), dict) else {}
        parts = content_obj.get("parts") if isinstance(content_obj.get("parts"), list) else []
        text_parts: list[str] = []
        tool_calls: list[dict[str, Any]] = []
        for part in parts:
            if not isinstance(part, dict) or part.get("thought") is True:
                continue
            fc = part.get("functionCall")
            if isinstance(fc, dict):
                fn_name = str(fc.get("name") or "")
                raw_args = fc.get("args")
                args_json = (
                    raw_args
                    if isinstance(raw_args, str)
                    else json.dumps(raw_args if isinstance(raw_args, dict) else {}, ensure_ascii=False, allow_nan=False)
                )
                tool_calls.append(
                    {
                        "id": str(fc.get("id") or f"call_gemini_{len(tool_calls) + 1}"),
                        "type": "function",
                        "function": {"name": fn_name, "arguments": args_json},
                    }
                )
            elif isinstance(part.get("text"), str):
                text_parts.append(part["text"])
        calls = tool_calls or None
        text_content: str | None = "".join(text_parts) if text_parts else None
        if calls and not (text_content or "").strip():
            text_content = None
        raw_finish = str(cand.get("finishReason") or "").upper()
        finish = "length" if raw_finish == "MAX_TOKENS" else ("tool_calls" if calls else "stop")
        choices.append(
            ChatCompletionChoice(
                index=int(cand.get("index", index)),
                finish_reason=finish,  # type: ignore[arg-type]
                message=ChatMessage(role="assistant", content=text_content, tool_calls=calls),
            )
        )
    if not choices:
        choices.append(
            ChatCompletionChoice(
                message=ChatMessage(role="assistant", content=None, tool_calls=None)
            )
        )
    usage_raw = raw.get("usage") if isinstance(raw.get("usage"), dict) else _gemini_usage(raw)
    return ChatCompletionResponse(
        id=str(raw.get("responseId") or "chatcmpl_gemini"),
        model=str(raw.get("modelVersion") or fallback_model),
        choices=choices,
        usage=ChatUsage(
            prompt_tokens=int(usage_raw.get("prompt_tokens") or 0),
            completion_tokens=int(usage_raw.get("completion_tokens") or 0),
            total_tokens=int(usage_raw.get("total_tokens") or 0),
        ),
    )
