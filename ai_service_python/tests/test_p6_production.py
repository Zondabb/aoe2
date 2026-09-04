from __future__ import annotations

import json
from pathlib import Path

from brain.director import AiDirector
from brain.stores import PHASE_DEFEND
from fastapi.testclient import TestClient

from main import app

FIXTURES = Path(__file__).parent / "fixtures"


def _load_fixture(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


def test_defend_phase_rallies_to_base() -> None:
    payload = _load_fixture("opening_eco.json")
    req = payload["request"]
    obs = dict(req["observation"])
    derived = dict(obs["derived"])
    derived["threat_near_base"] = True
    derived["military_count"] = 4
    derived["match_time_sec"] = 200.0
    obs["derived"] = derived
    entities = list(obs["entities"])
    entities.append(
        {
            "id": 900,
            "kind": "unit",
            "def_id": "swordsman",
            "team": req["team"],
            "pos": [120.0, 120.0],
            "hp": 60.0,
            "max_hp": 60.0,
            "order": "NONE",
        }
    )
    obs["entities"] = entities

    director = AiDirector(req["profile_id"])
    director.phase = PHASE_DEFEND
    response = director.evaluate(
        tick=400,
        match_id=req["match_id"],
        team=req["team"],
        enemy_team=req["enemy_team"],
        time_sec=200.0,
        observation=obs,
    )
    move_ops = [cmd for cmd in response.commands if cmd.op == "move"]
    assert move_ops, "DEFEND should issue move commands to pull units back"
    army_debug = [entry for entry in response.debug if entry.category == "ARMY"]
    assert any("回防" in entry.message for entry in army_debug)


def test_tick_batch_endpoint_returns_two_teams() -> None:
    payload = _load_fixture("opening_eco.json")
    req = payload["request"]
    client = TestClient(app)
    client.post(
        "/v1/ai/match/start",
        json={"protocol_version": 1, "match_id": "batch_test", "teams": []},
    )
    batch_body = {
        "protocol_version": 1,
        "match_id": "batch_test",
        "requests": [
            {
                "team": req["team"],
                "tick": req["tick"],
                "time_sec": req["time_sec"],
                "profile_id": req["profile_id"],
                "enemy_team": req["enemy_team"],
                "events": [],
                "observation": req["observation"],
            },
            {
                "team": req["enemy_team"],
                "tick": req["tick"],
                "time_sec": req["time_sec"],
                "profile_id": "chinese",
                "enemy_team": req["team"],
                "events": [],
                "observation": req["observation"],
            },
        ],
    }
    response = client.post("/v1/ai/tick_batch", json=batch_body)
    assert response.status_code == 200
    body = response.json()
    assert len(body["responses"]) == 2
    teams = {item["team"] for item in body["responses"]}
    assert teams == {req["team"], req["enemy_team"]}


def test_bearer_auth_rejects_missing_token(monkeypatch) -> None:
    monkeypatch.setenv("AOE2_AI_TOKEN", "secret-token")
    client = TestClient(app)
    health = client.get("/health")
    assert health.status_code == 200
    denied = client.post(
        "/v1/ai/tick",
        json={
            "protocol_version": 1,
            "match_id": "auth_test",
            "team": 1,
            "tick": 1,
            "time_sec": 0.0,
            "observation": _load_fixture("opening_eco.json")["request"]["observation"],
        },
    )
    assert denied.status_code == 401

    allowed = client.post(
        "/v1/ai/tick",
        headers={"Authorization": "Bearer secret-token"},
        json={
            "protocol_version": 1,
            "match_id": "auth_test",
            "team": 1,
            "tick": 1,
            "time_sec": 0.0,
            "profile_id": "teutons",
            "enemy_team": 0,
            "observation": _load_fixture("opening_eco.json")["request"]["observation"],
        },
    )
    assert allowed.status_code == 200
