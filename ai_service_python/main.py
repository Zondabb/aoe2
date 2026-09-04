from __future__ import annotations

from typing import Any

from fastapi import FastAPI

from brain.director import AiDirector
from protocol.models import (
    HealthResponse,
    MatchEndRequest,
    MatchStartRequest,
    TickRequest,
    TickResponse,
)

app = FastAPI(title="AoE2 RTS AI Service", version="1.0.0")

_directors: dict[tuple[str, int], AiDirector] = {}


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


@app.get("/health", response_model=HealthResponse)
def health() -> HealthResponse:
    return HealthResponse()


@app.post("/v1/ai/match/start")
def match_start(payload: MatchStartRequest) -> dict[str, Any]:
    _clear_match(payload.match_id)
    return {"ok": True, "match_id": payload.match_id}


@app.post("/v1/ai/match/end")
def match_end(payload: MatchEndRequest) -> dict[str, Any]:
    _clear_match(payload.match_id)
    return {"ok": True}


@app.post("/v1/ai/tick", response_model=TickResponse)
def tick(req: TickRequest) -> TickResponse:
    director = _get_or_create_director(req.match_id, req.team, req.profile_id)
    director.apply_events([event.model_dump() for event in req.events])
    return director.evaluate(
        tick=req.tick,
        match_id=req.match_id,
        team=req.team,
        enemy_team=req.enemy_team,
        time_sec=req.time_sec,
        observation=req.observation.model_dump(),
    )
