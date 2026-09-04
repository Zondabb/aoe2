from __future__ import annotations

import json
from pathlib import Path

from brain.director import AiDirector

FIXTURES = Path(__file__).parent / "fixtures"


def _normalize_commands(commands: list[dict]) -> list[tuple]:
    normalized = []
    for cmd in commands:
        entry = (cmd.get("op"), cmd.get("unit_id"), cmd.get("target_id"), cmd.get("building_id"))
        normalized.append(entry)
    return sorted(normalized)


def _load_fixture(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


def test_opening_eco_fixture_commands() -> None:
    payload = _load_fixture("opening_eco.json")
    req = payload["request"]
    director = AiDirector(req["profile_id"])
    response = director.evaluate(
        tick=req["tick"],
        match_id=req["match_id"],
        team=req["team"],
        enemy_team=req["enemy_team"],
        time_sec=req["time_sec"],
        observation=req["observation"],
    )
    ops = {cmd.op for cmd in response.commands}
    for expected in payload["expected_ops"]:
        assert expected in ops


def test_food_depleted_matches_wood_target() -> None:
    from tests.test_economy_food_depleted import test_food_depleted_reassigns_to_wood

    test_food_depleted_reassigns_to_wood()


def test_boom_phase_issues_build_or_train() -> None:
    payload = _load_fixture("opening_eco.json")
    req = payload["request"]
    req = dict(req)
    req["tick"] = 120
    req["time_sec"] = 120.0
    obs = dict(req["observation"])
    derived = dict(obs["derived"])
    derived["villager_count"] = 8
    derived["match_time_sec"] = 120.0
    obs["derived"] = derived
    obs["economy"] = dict(obs["economy"])
    obs["economy"]["food"] = 450
    req["observation"] = obs

    director = AiDirector(req["profile_id"])
    response = director.evaluate(
        tick=req["tick"],
        match_id=req["match_id"],
        team=req["team"],
        enemy_team=req["enemy_team"],
        time_sec=req["time_sec"],
        observation=req["observation"],
    )
    ops = {cmd.op for cmd in response.commands}
    assert ops.intersection({"gather", "train", "place_building"})


def test_attack_phase_issues_army_commands() -> None:
    payload = _load_fixture("opening_eco.json")
    req = payload["request"]
    req = dict(req)
    req["tick"] = 400
    req["time_sec"] = 200.0
    obs = dict(req["observation"])
    derived = dict(obs["derived"])
    derived["military_count"] = 6
    derived["match_time_sec"] = 200.0
    obs["derived"] = derived
    entities = list(obs["entities"])
    entities.append(
        {
            "id": 50,
            "kind": "unit",
            "def_id": "swordsman",
            "team": 1,
            "pos": [45.0, 42.0],
            "hp": 60.0,
            "max_hp": 60.0,
            "order": "NONE",
        }
    )
    entities.append(
        {
            "id": 200,
            "kind": "building",
            "def_id": "town_center",
            "team": 0,
            "pos": [-40.0, -40.0],
            "hp": 2400.0,
            "max_hp": 2400.0,
            "is_complete": True,
        }
    )
    obs["entities"] = entities
    req["observation"] = obs

    director = AiDirector(req["profile_id"])
    response = director.evaluate(
        tick=req["tick"],
        match_id=req["match_id"],
        team=req["team"],
        enemy_team=req["enemy_team"],
        time_sec=req["time_sec"],
        observation=req["observation"],
    )
    ops = {cmd.op for cmd in response.commands}
    assert ops.intersection({"move", "attack", "train"})
