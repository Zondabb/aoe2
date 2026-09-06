from __future__ import annotations

import copy
import json
from pathlib import Path

import jsonschema
from fastapi.testclient import TestClient
from protocol.models import Command

from brain.tool_call_mapper import TOOL_NAMES, command_to_tool_call, commands_to_tool_calls
from main import app

REPO_ROOT = Path(__file__).resolve().parents[2]
PROTOCOL_DIR = REPO_ROOT / "protocol"
FIXTURES = Path(__file__).parent / "fixtures"


def _opening_payload() -> dict:
    return json.loads((FIXTURES / "opening_eco.json").read_text(encoding="utf-8"))


def _chat_body_from_tick(tick_req: dict) -> dict:
    return {
        "model": "aoe2-rules-v1",
        "stream": False,
        "temperature": 0,
        "max_tokens": 2048,
        "messages": [
            {"role": "system", "content": "You are an RTS commander."},
            {"role": "user", "content": "opening eco"},
        ],
        "tools": [],
        "tool_choice": "auto",
        "metadata": {
            "protocol_version": 2,
            "match_id": tick_req["match_id"],
            "team": tick_req["team"],
            "tick": tick_req["tick"],
            "time_sec": tick_req["time_sec"],
            "profile_id": tick_req["profile_id"],
            "enemy_team": tick_req["enemy_team"],
            "team_label": tick_req.get("team_label", ""),
        },
        "observation": tick_req["observation"],
        "events": tick_req.get("events", []),
    }


def test_v2_examples_match_schema() -> None:
    schema = json.loads((PROTOCOL_DIR / "ai_v2_chat.schema.json").read_text(encoding="utf-8"))
    defs = schema["$defs"]
    request = json.loads(
        (PROTOCOL_DIR / "examples" / "chat_completion_request.json").read_text(encoding="utf-8")
    )
    response = json.loads(
        (PROTOCOL_DIR / "examples" / "chat_completion_response.json").read_text(encoding="utf-8")
    )
    jsonschema.validate(request, {"$defs": defs, "$ref": "#/$defs/chat_completion_request"})
    jsonschema.validate(response, {"$defs": defs, "$ref": "#/$defs/chat_completion_response"})


def test_commands_map_to_tool_calls() -> None:
    commands = [
        Command(command_id="c_128_0", op="gather", unit_id=12, target_id=31),
        Command(command_id="c_128_1", op="train", building_id=5, unit_def_id="villager"),
        Command(command_id="c_128_2", op="move", unit_id=9, pos=[1.0, 2.0]),
    ]
    calls = commands_to_tool_calls(commands)
    assert [c["function"]["name"] for c in calls] == ["gather", "train", "move"]
    gather_args = json.loads(calls[0]["function"]["arguments"])
    assert gather_args == {"command_id": "c_128_0", "unit_id": 12, "target_id": 31}
    train_args = json.loads(calls[1]["function"]["arguments"])
    assert train_args["unit_def_id"] == "villager"
    move_args = json.loads(calls[2]["function"]["arguments"])
    assert move_args["pos"] == [1.0, 2.0]
    single = command_to_tool_call(commands[0], 0)
    assert single["id"] == "call_1"
    assert set(TOOL_NAMES) == {
        "gather",
        "train",
        "place_building",
        "build",
        "move",
        "attack",
        "stop",
        "noop",
    }


def test_chat_rejects_stream() -> None:
    client = TestClient(app)
    body = _chat_body_from_tick(_opening_payload()["request"])
    body["stream"] = True
    response = client.post("/v1/chat/completions", json=body)
    assert response.status_code == 400
    assert "stream" in str(response.json()).lower()


def test_chat_rejects_invalid_body() -> None:
    client = TestClient(app)
    response = client.post("/v1/chat/completions", json={"model": "aoe2-rules-v1"})
    assert response.status_code == 422


def test_chat_requires_observation_for_rules() -> None:
    client = TestClient(app)
    response = client.post(
        "/v1/chat/completions",
        json={
            "messages": [{"role": "user", "content": "hi"}],
            "metadata": {"match_id": "no_obs", "team": 0, "tick": 0},
        },
    )
    assert response.status_code == 400
    assert response.json()["detail"] == "missing_observation"


def test_opening_eco_chat_issues_gather_and_train() -> None:
    payload = _opening_payload()
    tick_req = payload["request"]
    client = TestClient(app)
    client.post(
        "/v1/ai/match/start",
        json={"protocol_version": 1, "match_id": tick_req["match_id"], "teams": []},
    )
    response = client.post("/v1/chat/completions", json=_chat_body_from_tick(tick_req))
    assert response.status_code == 200
    body = response.json()
    assert body["object"] == "chat.completion"
    assert body["usage"]["total_tokens"] == 0
    choice = body["choices"][0]
    assert choice["finish_reason"] == "tool_calls"
    names = [call["function"]["name"] for call in choice["message"]["tool_calls"]]
    assert "gather" in names
    assert "train" in names
    gather = next(c for c in choice["message"]["tool_calls"] if c["function"]["name"] == "gather")
    args = json.loads(gather["function"]["arguments"])
    assert args["target_id"] == 20


def test_chat_auth_required_when_token_set(monkeypatch) -> None:
    monkeypatch.setenv("AOE2_AI_TOKEN", "secret-token")
    client = TestClient(app)
    body = _chat_body_from_tick(_opening_payload()["request"])
    denied = client.post("/v1/chat/completions", json=body)
    assert denied.status_code == 401
    ok = client.post(
        "/v1/chat/completions",
        json=body,
        headers={"Authorization": "Bearer secret-token"},
    )
    assert ok.status_code == 200
    health = client.get("/health")
    assert health.status_code == 200


def test_opening_eco_v1_and_v2_ops_match() -> None:
    payload = _opening_payload()
    tick_req = payload["request"]
    client = TestClient(app)
    client.post(
        "/v1/ai/match/start",
        json={"protocol_version": 1, "match_id": "parity_v1_v2", "teams": []},
    )
    tick_body = dict(tick_req)
    tick_body["match_id"] = "parity_v1_v2"
    tick_resp = client.post("/v1/ai/tick", json=tick_body)
    assert tick_resp.status_code == 200
    tick_ops = {cmd["op"] for cmd in tick_resp.json()["commands"]}

    client.post(
        "/v1/ai/match/start",
        json={"protocol_version": 1, "match_id": "parity_v1_v2b", "teams": []},
    )
    chat_req = dict(tick_req)
    chat_req["match_id"] = "parity_v1_v2b"
    chat_resp = client.post("/v1/chat/completions", json=_chat_body_from_tick(chat_req))
    assert chat_resp.status_code == 200
    chat_ops = {
        call["function"]["name"]
        for call in chat_resp.json()["choices"][0]["message"]["tool_calls"]
    }
    assert "gather" in tick_ops and "gather" in chat_ops
    assert "train" in tick_ops and "train" in chat_ops
    assert tick_ops == chat_ops


def test_chat_completions_batch_two_teams() -> None:
    payload = _opening_payload()
    req = payload["request"]
    client = TestClient(app)
    client.post(
        "/v1/ai/match/start",
        json={"protocol_version": 1, "match_id": "batch_chat", "teams": []},
    )
    def _retarget(body: dict, team: int, enemy: int) -> dict:
        out = copy.deepcopy(body)
        out["metadata"]["match_id"] = "batch_chat"
        out["metadata"]["team"] = team
        out["metadata"]["enemy_team"] = enemy
        for ent in out["observation"]["entities"]:
            if ent.get("kind") in ("unit", "building"):
                ent["team"] = team
        out["observation"]["derived"]["own_tc_id"] = 1 if team == 1 else 2
        return out

    team_a = _retarget(_chat_body_from_tick(req), 0, 1)
    team_b = _retarget(_chat_body_from_tick(req), 1, 0)
    response = client.post(
        "/v1/chat/completions_batch",
        json={"requests": [team_a, team_b]},
    )
    assert response.status_code == 200
    bodies = response.json()["responses"]
    assert len(bodies) == 2
    for body in bodies:
        calls = body["choices"][0]["message"].get("tool_calls") or []
        names = [call["function"]["name"] for call in calls]
        assert "gather" in names, names


def test_openai_backend_uses_proxy(monkeypatch) -> None:
    captured: dict = {}

    def _fake_post(url, headers, payload, timeout):
        captured["url"] = url
        captured["payload"] = payload
        return {
            "id": "chatcmpl_fake",
            "model": "gpt-test",
            "choices": [
                {
                    "index": 0,
                    "finish_reason": "tool_calls",
                    "message": {
                        "role": "assistant",
                        "content": None,
                        "tool_calls": [
                            {
                                "id": "call_1",
                                "type": "function",
                                "function": {
                                    "name": "gather",
                                    "arguments": '{"unit_id":10,"target_id":20}',
                                },
                            }
                        ],
                    },
                }
            ],
            "usage": {"prompt_tokens": 11, "completion_tokens": 4, "total_tokens": 15},
        }

    monkeypatch.setenv("AOE2_AI_BACKEND", "openai")
    monkeypatch.setenv("AOE2_LLM_TOKEN", "sk-test")
    monkeypatch.setenv("AOE2_LLM_BASE_URL", "https://example.test/v1")
    monkeypatch.setattr("brain.llm_proxy.post_openai", _fake_post)
    client = TestClient(app)
    body = _chat_body_from_tick(_opening_payload()["request"])
    # observation still sent, but openai path should not need it
    response = client.post("/v1/chat/completions", json=body)
    assert response.status_code == 200
    assert captured["url"] == "https://example.test/v1/chat/completions"
    assert "observation" not in captured["payload"]
    names = [c["function"]["name"] for c in response.json()["choices"][0]["message"]["tool_calls"]]
    assert names == ["gather"]
    assert response.json()["usage"]["total_tokens"] == 15


def test_openai_failure_without_observation_is_502(monkeypatch) -> None:
    def _boom(*_args, **_kwargs):
        raise RuntimeError("upstream down")

    monkeypatch.setenv("AOE2_AI_BACKEND", "openai")
    monkeypatch.setenv("AOE2_LLM_TOKEN", "sk-test")
    monkeypatch.setattr("brain.llm_proxy.post_openai", _boom)
    client = TestClient(app)
    response = client.post(
        "/v1/chat/completions",
        json={"messages": [{"role": "user", "content": "hi"}], "metadata": {"backend": "openai"}},
    )
    assert response.status_code == 502


def test_log_observation_emits_debug(monkeypatch, caplog) -> None:
    monkeypatch.setenv("AOE2_AI_LOG_OBSERVATION", "true")
    client = TestClient(app)
    body = _chat_body_from_tick(_opening_payload()["request"])
    with caplog.at_level("INFO"):
        response = client.post("/v1/chat/completions", json=body)
    assert response.status_code == 200
    assert any("chat_debug" in rec.message for rec in caplog.records)
