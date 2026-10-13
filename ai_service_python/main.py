from __future__ import annotations

import json
import logging
import os
import time
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse

from brain import runtime_settings
from brain.director import AiDirector
from brain.stores import PHASE_ATTACK, PHASE_BOOM, PHASE_DEFEND, PHASE_ECO
from brain.llm_proxy import build_openai_payload, forward_openai, is_openai_backend, resolve_backend
from brain.rules_compat import observation_or_error, to_tick_request, wrap_tick_response
from protocol.models import (
    ChatCompletionBatchRequest,
    ChatCompletionBatchResponse,
    ChatCompletionRequest,
    ChatCompletionResponse,
    HealthResponse,
    MatchEndRequest,
    MatchStartRequest,
    TickBatchRequest,
    TickBatchResponse,
    TickRequest,
    TickResponse,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
logging.getLogger("httpx").setLevel(logging.WARNING)
logger = logging.getLogger("ai_service")
_LLM_LOG_DIR = Path(__file__).resolve().parent / "logs"

app = FastAPI(title="AoE2 RTS AI Service", version="1.0.0")

_directors: dict[tuple[str, int], AiDirector] = {}

_PHASE_NAMES = {
    PHASE_ECO: "ECO",
    PHASE_BOOM: "BOOM",
    PHASE_ATTACK: "ATTACK",
    PHASE_DEFEND: "DEFEND",
}


def _director_key(match_id: str, team: int) -> tuple[str, int]:
    return match_id, team


def _get_or_create_director(match_id: str, team: int, profile_id: str) -> AiDirector:
    key = _director_key(match_id, team)
    if key not in _directors:
        _directors[key] = AiDirector(profile_id)
    return _directors[key]


def _clear_match(match_id: str) -> None:
    keys = [key for key in _directors if key[0] == match_id]
    for key in keys:
        del _directors[key]


def _expected_token() -> str:
    return runtime_settings.ai_token()


def _log_tick(
    match_id: str,
    team: int,
    tick: int,
    director: AiDirector,
    response: TickResponse,
    elapsed_ms: float,
) -> None:
    logger.info(
        '{"event":"tick","match_id":"%s","team":%d,"tick":%d,"phase":"%s","cmd_count":%d,"latency_ms":%.2f}',
        match_id,
        team,
        tick,
        _PHASE_NAMES.get(director.phase, str(director.phase)),
        len(response.commands),
        elapsed_ms,
    )


def _evaluate_tick(req: TickRequest) -> TickResponse:
    director = _get_or_create_director(req.match_id, req.team, req.profile_id)
    director.apply_events([event.model_dump() for event in req.events])
    started = time.perf_counter()
    response = director.evaluate(
        tick=req.tick,
        match_id=req.match_id,
        team=req.team,
        enemy_team=req.enemy_team,
        time_sec=req.time_sec,
        observation=req.observation.model_dump(),
    )
    elapsed_ms = (time.perf_counter() - started) * 1000.0
    _log_tick(req.match_id, req.team, req.tick, director, response, elapsed_ms)
    return response


@app.middleware("http")
async def bearer_auth_middleware(request: Request, call_next):
    token = _expected_token()
    if token and request.url.path != "/health":
        auth = request.headers.get("Authorization", "")
        if auth != f"Bearer {token}":
            return JSONResponse(status_code=401, content={"error": "unauthorized"})
    return await call_next(request)


@app.get("/health", response_model=HealthResponse)
def health() -> HealthResponse:
    return HealthResponse()


@app.post("/v1/ai/match/start")
def match_start(payload: MatchStartRequest) -> dict[str, Any]:
    _clear_match(payload.match_id)
    logger.info('{"event":"match_start","match_id":"%s","teams":%d}', payload.match_id, len(payload.teams))
    return {"ok": True, "match_id": payload.match_id}


@app.post("/v1/ai/match/end")
def match_end(payload: MatchEndRequest) -> dict[str, Any]:
    _clear_match(payload.match_id)
    logger.info('{"event":"match_end","match_id":"%s"}', payload.match_id)
    return {"ok": True}


@app.post("/v1/ai/tick", response_model=TickResponse)
def tick(req: TickRequest) -> TickResponse:
    return _evaluate_tick(req)


@app.post("/v1/ai/tick_batch", response_model=TickBatchResponse)
def tick_batch(req: TickBatchRequest) -> TickBatchResponse:
    started = time.perf_counter()
    responses: list[TickResponse] = []
    for item in req.requests:
        tick_req = TickRequest(
            match_id=req.match_id,
            team=item.team,
            team_label=item.team_label,
            tick=item.tick,
            time_sec=item.time_sec,
            profile_id=item.profile_id,
            enemy_team=item.enemy_team,
            events=item.events,
            observation=item.observation,
        )
        responses.append(_evaluate_tick(tick_req))
    elapsed_ms = (time.perf_counter() - started) * 1000.0
    logger.info(
        '{"event":"tick_batch","match_id":"%s","teams":%d,"latency_ms":%.2f}',
        req.match_id,
        len(responses),
        elapsed_ms,
    )
    return TickBatchResponse(match_id=req.match_id, responses=responses)


def _log_observation_enabled(req: ChatCompletionRequest) -> bool:
    if os.environ.get("AOE2_AI_LOG_OBSERVATION", "").strip().lower() in {"1", "true", "yes"}:
        return True
    extra = req.metadata.model_dump()
    return bool(extra.get("log_observation"))


def _maybe_log_observation(req: ChatCompletionRequest) -> None:
    if not _log_observation_enabled(req):
        return
    msg_chars = sum(len(msg.content or "") for msg in req.messages)
    entity_count = 0
    if req.observation is not None:
        entity_count = len(req.observation.entities)
    logger.info(
        '{"event":"chat_debug","messages_chars":%d,"message_count":%d,"entity_count":%d}',
        msg_chars,
        len(req.messages),
        entity_count,
    )


def _log_chat(
    model: str,
    match_id: str,
    team: int,
    tick: int,
    tool_call_count: int,
    elapsed_ms: float,
    backend: str,
) -> None:
    logger.info(
        '{"event":"chat_completion","model":"%s","backend":"%s","match_id":"%s","team":%d,"tick":%d,'
        '"tool_call_count":%d,"latency_ms":%.2f}',
        model,
        backend,
        match_id,
        team,
        tick,
        tool_call_count,
        elapsed_ms,
    )


def _llm_file_logger() -> logging.Logger:
    log = logging.getLogger("ai_service.llm_file")
    if not log.handlers:
        _LLM_LOG_DIR.mkdir(parents=True, exist_ok=True)
        handler = logging.FileHandler(_LLM_LOG_DIR / "llm.log", encoding="utf-8")
        handler.setFormatter(logging.Formatter("%(asctime)s %(message)s", datefmt="%Y-%m-%dT%H:%M:%S"))
        log.addHandler(handler)
        log.setLevel(logging.INFO)
        log.propagate = False
    return log


def _write_llm_json(title: str, payload: Any) -> None:
    text = json.dumps(payload, ensure_ascii=False, indent=2, default=str)
    _llm_file_logger().info("%s\n%s", title, text)


def _summarize_llm_response(inbound: dict[str, Any]) -> dict[str, Any]:
    message: dict[str, Any] = {}
    choices = inbound.get("choices") or []
    if choices and isinstance(choices[0], dict):
        raw = choices[0].get("message")
        if isinstance(raw, dict):
            message = raw
    return {
        "reasoning_content": message.get("reasoning_content"),
        "tool_calls": message.get("tool_calls"),
    }


def _print_game_commands(req: ChatCompletionRequest, wrapped: ChatCompletionResponse) -> None:
    tool_calls = []
    if wrapped.choices and wrapped.choices[0].message.tool_calls:
        tool_calls = wrapped.choices[0].message.tool_calls
    lines = [
        f"===== commands match={req.metadata.match_id} team={req.metadata.team} tick={req.metadata.tick} ====="
    ]
    if not tool_calls:
        lines.append("(none)")
    else:
        for call in tool_calls:
            if not isinstance(call, dict):
                lines.append(str(call))
                continue
            fn = call.get("function") if isinstance(call.get("function"), dict) else {}
            name = fn.get("name", "?")
            args = fn.get("arguments", "")
            lines.append(f"{name} {args}")
    print("\n".join(lines), flush=True)


def _complete_chat(req: ChatCompletionRequest) -> ChatCompletionResponse:
    if req.stream:
        raise HTTPException(status_code=400, detail="stream_not_supported")
    _maybe_log_observation(req)
    backend = resolve_backend(req)
    started = time.perf_counter()
    if is_openai_backend(backend):
        try:
            outbound = build_openai_payload(req)
            _write_llm_json(
                "LLM request (to model)",
                {
                    **outbound,
                    "team": req.metadata.team,
                    "tick": req.metadata.tick,
                    "match_id": req.metadata.match_id,
                },
            )
            wrapped, _outbound, inbound = forward_openai(req)
            _write_llm_json("LLM response (from model)", _summarize_llm_response(inbound))
            elapsed_ms = (time.perf_counter() - started) * 1000.0
            tool_call_count = 0
            if wrapped.choices and wrapped.choices[0].message.tool_calls:
                tool_call_count = len(wrapped.choices[0].message.tool_calls)
            _log_chat(
                wrapped.model,
                req.metadata.match_id or "chat",
                req.metadata.team,
                req.metadata.tick,
                tool_call_count,
                elapsed_ms,
                backend,
            )
            _print_game_commands(req, wrapped)
            return wrapped
        except HTTPException:
            raise
        except Exception as exc:
            logger.warning('{"event":"llm_proxy_error","error":"%s"}', str(exc).replace('"', "'"))
            if observation_or_error(req) is None:
                raise HTTPException(status_code=502, detail="llm_upstream_error") from exc
            backend = "rules_compat"

    if observation_or_error(req) is None:
        raise HTTPException(status_code=400, detail="missing_observation")

    meta = req.metadata
    match_id = meta.match_id.strip() or "chat"
    tick_req = to_tick_request(req, match_id)
    tick_response = _evaluate_tick(tick_req)
    elapsed_ms = (time.perf_counter() - started) * 1000.0
    completion_id = f"chatcmpl_{match_id}_{tick_req.tick}_{tick_req.team}"
    wrapped = wrap_tick_response(tick_response, req.model, completion_id)
    tool_call_count = 0
    if wrapped.choices and wrapped.choices[0].message.tool_calls:
        tool_call_count = len(wrapped.choices[0].message.tool_calls)
    _log_chat(req.model, match_id, tick_req.team, tick_req.tick, tool_call_count, elapsed_ms, backend)
    _print_game_commands(req, wrapped)
    return wrapped


@app.post("/v1/chat/completions", response_model=ChatCompletionResponse)
def chat_completions(req: ChatCompletionRequest) -> ChatCompletionResponse:
    return _complete_chat(req)


@app.post("/v1/chat/completions_batch", response_model=ChatCompletionBatchResponse)
def chat_completions_batch(req: ChatCompletionBatchRequest) -> ChatCompletionBatchResponse:
    started = time.perf_counter()
    responses = [_complete_chat(item) for item in req.requests]
    elapsed_ms = (time.perf_counter() - started) * 1000.0
    logger.info(
        '{"event":"chat_completions_batch","teams":%d,"latency_ms":%.2f}',
        len(responses),
        elapsed_ms,
    )
    return ChatCompletionBatchResponse(responses=responses)


def _log_startup(host: str, port: int) -> None:
    token = runtime_settings.llm_token()
    logger.info(
        '{"event":"startup","listen":"%s:%d","backend":"%s","llm_base_url":"%s","llm_token":"%s"}',
        host,
        port,
        runtime_settings.backend() or "(from request)",
        runtime_settings.llm_base_url() or "(from request)",
        runtime_settings.mask_secret(token),
    )
    if not token:
        logger.warning("missing --llm-token; openai backend will fail with missing_llm_token")


if __name__ == "__main__":
    import uvicorn

    args = runtime_settings.build_parser().parse_args()
    runtime_settings.apply_args(args)
    _log_startup(args.host, args.port)
    uvicorn.run(app, host=args.host, port=args.port, access_log=False)
