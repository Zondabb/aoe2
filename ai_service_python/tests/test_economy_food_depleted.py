from __future__ import annotations

from fastapi.testclient import TestClient

from main import app


def test_health_returns_ok() -> None:
    client = TestClient(app)
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_opening_tick_issues_food_gather_and_train() -> None:
    client = TestClient(app)
    client.post(
        "/v1/ai/match/start",
        json={"protocol_version": 1, "match_id": "test_opening", "teams": []},
    )
    payload = {
        "protocol_version": 1,
        "match_id": "test_opening",
        "team": 1,
        "team_label": "Teutons",
        "tick": 0,
        "time_sec": 0.0,
        "profile_id": "teutons",
        "enemy_team": 0,
        "events": [],
        "observation": {
            "economy": {
                "food": 200,
                "wood": 200,
                "gold": 100,
                "pop_used": 4,
                "pop_cap": 5,
            },
            "derived": {
                "own_tc_id": 1,
                "own_tc_pos": [40.0, 40.0],
                "enemy_tc_id": 2,
                "enemy_tc_pos": [-40.0, -40.0],
                "threat_near_base": False,
                "villager_count": 4,
                "military_count": 0,
                "incomplete_buildings": 0,
                "match_time_sec": 0.0,
            },
            "entities": [
                {
                    "id": 10,
                    "kind": "unit",
                    "def_id": "villager",
                    "team": 1,
                    "pos": [42.0, 40.0],
                    "hp": 25.0,
                    "max_hp": 25.0,
                    "order": "NONE",
                },
                {
                    "id": 1,
                    "kind": "building",
                    "def_id": "town_center",
                    "team": 1,
                    "pos": [40.0, 40.0],
                    "hp": 2400.0,
                    "max_hp": 2400.0,
                    "is_complete": True,
                    "build_progress": 0.0,
                    "train_queue_empty": True,
                },
                {
                    "id": 20,
                    "kind": "resource",
                    "resource_type": "FOOD",
                    "pos": [55.0, 50.0],
                    "amount": 200.0,
                },
            ],
        },
    }
    response = client.post("/v1/ai/tick", json=payload)
    assert response.status_code == 200
    body = response.json()
    assert body["commands"]
    ops = {cmd["op"] for cmd in body["commands"]}
    assert "gather" in ops
    assert "train" in ops
    gather = next(cmd for cmd in body["commands"] if cmd["op"] == "gather")
    assert gather["target_id"] == 20


def test_food_depleted_reassigns_to_wood() -> None:
    client = TestClient(app)
    client.post(
        "/v1/ai/match/start",
        json={"protocol_version": 1, "match_id": "test_depleted", "teams": []},
    )
    payload = {
        "protocol_version": 1,
        "match_id": "test_depleted",
        "team": 0,
        "team_label": "Chinese",
        "tick": 64,
        "time_sec": 64.0,
        "profile_id": "chinese",
        "enemy_team": 1,
        "events": [
            {
                "seq": 40,
                "type": "resource_depleted",
                "entity_id": 30,
                "resource_type": "FOOD",
            }
        ],
        "observation": {
            "economy": {
                "food": 180,
                "wood": 200,
                "gold": 100,
                "pop_used": 4,
                "pop_cap": 5,
            },
            "derived": {
                "own_tc_id": 5,
                "own_tc_pos": [-40.0, -40.0],
                "enemy_tc_id": 105,
                "enemy_tc_pos": [40.0, 40.0],
                "threat_near_base": False,
                "villager_count": 4,
                "military_count": 0,
                "incomplete_buildings": 0,
                "match_time_sec": 64.0,
            },
            "entities": [
                {
                    "id": 12,
                    "kind": "unit",
                    "def_id": "villager",
                    "team": 0,
                    "pos": [-38.0, -39.0],
                    "hp": 25.0,
                    "max_hp": 25.0,
                    "order": "GATHER",
                    "gather_state": "",
                    "last_resource_id": 30,
                    "stuck_frames": 0,
                },
                {
                    "id": 5,
                    "kind": "building",
                    "def_id": "town_center",
                    "team": 0,
                    "pos": [-40.0, -40.0],
                    "hp": 2400.0,
                    "max_hp": 2400.0,
                    "is_complete": True,
                    "train_queue_empty": True,
                },
                {
                    "id": 30,
                    "kind": "resource",
                    "resource_type": "FOOD",
                    "pos": [-25.0, -20.0],
                    "amount": 0.0,
                },
                {
                    "id": 31,
                    "kind": "resource",
                    "resource_type": "WOOD",
                    "pos": [-25.0, -50.0],
                    "amount": 200.0,
                },
            ],
        },
    }
    response = client.post("/v1/ai/tick", json=payload)
    assert response.status_code == 200
    body = response.json()
    gather_cmds = [cmd for cmd in body["commands"] if cmd["op"] == "gather"]
    assert gather_cmds, "expected gather command when food bush is depleted"
    assert gather_cmds[0]["target_id"] == 31
    messages = " ".join(entry["message"] for entry in body.get("debug", []))
    assert "wood" in messages


def test_match_end_clears_director_state() -> None:
    client = TestClient(app)
    match_id = "test_reset"
    client.post(
        "/v1/ai/match/start",
        json={"protocol_version": 1, "match_id": match_id, "teams": []},
    )
    client.post(
        "/v1/ai/tick",
        json={
            "protocol_version": 1,
            "match_id": match_id,
            "team": 0,
            "tick": 0,
            "time_sec": 0.0,
            "observation": {
                "economy": {
                    "food": 200,
                    "wood": 200,
                    "gold": 100,
                    "pop_used": 1,
                    "pop_cap": 5,
                },
                "derived": {
                    "own_tc_id": 1,
                    "own_tc_pos": [0.0, 0.0],
                    "enemy_tc_id": 2,
                    "enemy_tc_pos": [10.0, 10.0],
                    "threat_near_base": False,
                    "villager_count": 1,
                    "military_count": 0,
                    "incomplete_buildings": 0,
                },
                "entities": [],
            },
        },
    )
    client.post("/v1/ai/match/end", json={"protocol_version": 1, "match_id": match_id})
    client.post(
        "/v1/ai/match/start",
        json={"protocol_version": 1, "match_id": match_id, "teams": []},
    )
    response = client.get("/health")
    assert response.status_code == 200
