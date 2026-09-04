from __future__ import annotations

import logging
import os
import time
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from brain.director import AiDirector
from brain.stores import PHASE_ATTACK, PHASE_BOOM, PHASE_DEFEND, PHASE_ECO
from protocol.models import (
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
logger = logging.getLogger("ai_service")

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
    return os.environ.get("AOE2_AI_TOKEN", "").strip()


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


if __name__ == "__main__":
    import uvicorn

    host = os.environ.get("AOE2_AI_HOST", "127.0.0.1")
    port = int(os.environ.get("AOE2_AI_PORT", "8765"))
    uvicorn.run(app, host=host, port=port)
