from __future__ import annotations

import copy
import json

import pytest

from brain.land_progression import CATALOG
from brain.llm_commander import LlmCommander
from brain.llm_proxy import build_openai_payload
from protocol.models import ChatCompletionRequest, ChatCompletionResponse, GameEvent


def unit(eid: int, name: str = "villager", pos=None, team: int = 0, **extra) -> dict:
    return {"id": eid, "kind": "unit", "def_id": name, "team": team, "pos": pos or [0, 0],
            "hp": 40, "max_hp": 40, "order": "NONE", **extra}


def building(eid: int, name: str, pos=None, complete: bool = True, **extra) -> dict:
    return {"id": eid, "kind": "building", "def_id": name, "team": 0, "pos": pos or [0, 0],
            "hp": 500, "max_hp": 500, "is_complete": complete, "train_queue_empty": True,
            "is_researching": False, "trainable": ["villager"] if name == "town_center" else ["militia"], **extra}


def request(tick: int = 1, entities=None, **context) -> ChatCompletionRequest:
    buildings = [{"id": name, **copy.deepcopy(CATALOG["buildings"][name]), "available": True, "blocked_reason": ""}
                 for name in ("house", "barracks", "mill", "farm")]
    units = [{"id": name, **copy.deepcopy(CATALOG["units"][name])} for name in ("villager", "militia")]
    entities = entities if entities is not None else [building(1, "town_center"), unit(10), unit(11), unit(12), unit(20, "scout_cavalry"),
        {"id": 100, "kind": "resource", "resource_type": "FOOD", "pos": [5, 5], "amount": 1000},
        {"id": 101, "kind": "resource", "resource_type": "WOOD", "pos": [5, -5], "amount": 1000},
        {"id": 102, "kind": "resource", "resource_type": "GOLD", "pos": [-5, 5], "amount": 1000}]
    data = {"catalog": {"buildings": buildings, "units": units},
            "construction_options": [{"building_def_id": "barracks", "builder_id": 10, "pos": [24, 0]},
                                     {"building_def_id": "barracks", "builder_id": 11, "pos": [24, 16]},
                                     {"building_def_id": "house", "builder_id": 12, "pos": [0, 24]}],
            "scouting": {"frontiers": [{"pos": [20, 20], "unknown_neighbors": 3}, {"pos": [40, 40], "unknown_neighbors": 5}], "scout_ids": [20]},
            "army": {"rally_point": [8, 8], "enemy_near_base_ids": [], "scout_ids": [20]}, **context}
    return ChatCompletionRequest.model_validate({"model": "mock-model", "messages": [{"role": "user", "content": "play"}],
        "metadata": {"match_id": "llm-test", "team": 0, "tick": tick, "time_sec": tick * 5, "profile_id": "chinese"},
        "observation": {"economy": {"food": 500, "wood": 600, "gold": 400, "stone": 0, "pop_used": 4, "pop_cap": 30},
                        "derived": {"own_tc_id": 1, "own_tc_pos": [0, 0], "enemy_tc_id": -1, "enemy_tc_pos": [0, 0],
                                    "threat_near_base": False, "villager_count": 3, "military_count": 1, "incomplete_buildings": 0},
                        "entities": entities, "progression": {"age": 0}, "map_bounds": {"min": [-100, -100], "max": [100, 100]},
                        "decision_context": data}})


def response(*calls) -> ChatCompletionResponse:
    return ChatCompletionResponse.model_validate({"id": "mock-result", "model": "mock-model",
        "choices": [{"message": {"role": "assistant", "tool_calls": [{"id": f"m_{i}", "type": "function",
            "function": {"name": name, "arguments": json.dumps(args)}} for i, (name, args) in enumerate(calls)]}}],
        "usage": {"total_tokens": 17}})


def act(commander, req, *calls) -> tuple[dict, list[dict]]:
    commander.prepare_request(req)
    out = commander.finish_response(req, response(*calls))
    commands = [{"op": call["function"]["name"], **json.loads(call["function"]["arguments"])}
                for call in (out.choices[0].message.tool_calls or [])]
    return out.model_dump(), commands


def test_opener_finishes_barracks_trains_musters_and_attacks() -> None:
    commander = LlmCommander("chinese")
    req = request()
    _, first = act(commander, req, ("set_strategy", {"stance": "muster", "army_target": 2}))
    assert any(c["op"] == "place_building" and c["building_def_id"] == "barracks" for c in first)
    assert any(c["op"] == "move" and c["unit_id"] == 20 for c in first)
    assert any(c["op"] == "gather" for c in first)
    assert any(c["op"] == "train" and c["unit_def_id"] == "villager" for c in first)
    assert not any(c["op"] == "set_strategy" for c in first)

    second = request(2, entities=req.observation.entities + [building(2, "barracks", [24, 0], complete=False)])
    _, commands = act(commander, second)
    assert any(c["op"] == "build" and c["building_id"] == 2 for c in commands)
    assert not any(c["op"] == "place_building" and c["building_def_id"] == "barracks" for c in commands)

    third = request(3, entities=req.observation.entities + [building(2, "barracks", [24, 0]), unit(30, "militia"), unit(31, "militia")])
    _, commands = act(commander, third)
    assert any(c["op"] == "train" and c["unit_def_id"] == "militia" for c in commands)
    assert any(c["op"] == "move" and c["unit_id"] == 30 and c["pos"] == [8, 8] for c in commands)
    assert not any(c["op"] == "attack" for c in commands)

    enemy = unit(200, "militia", [30, 30], team=1)
    fourth = request(4, entities=third.observation.entities + [enemy])
    _, commands = act(commander, fourth, ("set_strategy", {"stance": "attack", "army_target": 2}))
    assert {c["unit_id"] for c in commands if c["op"] == "attack"} == {30, 31}
    assert all(c["target_id"] == 200 for c in commands if c["op"] == "attack")


def test_scout_preserves_mission_then_advances_frontier() -> None:
    commander = LlmCommander("chinese")
    _, initial = act(commander, request())
    first_move = next(c for c in initial if c["op"] == "move" and c["unit_id"] == 20)
    entities = request().observation.entities
    scout = next(e for e in entities if e["id"] == 20)
    scout.update(order="MOVE", pos=[5, 5], move_goal=first_move["pos"])
    _, transit = act(commander, request(2, entities=entities))
    assert not any(c.get("unit_id") == 20 for c in transit)
    scout.update(order="NONE", pos=first_move["pos"])
    _, arrived = act(commander, request(3, entities=entities))
    assert next(c for c in arrived if c["op"] == "move" and c["unit_id"] == 20)["pos"] == [40, 40]


def test_attack_requires_muster_then_retains_commitment_after_losses() -> None:
    commander = LlmCommander("chinese")
    req = request(entities=[unit(30, "militia"), unit(200, "militia", [40, 40], team=1)])
    _, small = act(commander, req, ("set_strategy", {"stance": "attack", "army_target": 2}))
    assert not any(c["op"] == "attack" for c in small)
    req = request(2, entities=req.observation.entities + [unit(31, "militia")])
    _, large = act(commander, req)
    assert len([c for c in large if c["op"] == "attack"]) == 2
    _, losses = act(commander, request(3, entities=[unit(30, "militia"), unit(200, "militia", [40, 40], team=1)]))
    assert any(c["op"] == "attack" for c in losses)


def test_default_development_retains_attack_commitment_after_losses() -> None:
    commander = LlmCommander("chinese")
    commander.strategy.army_target = 2
    enemy = unit(200, "militia", [30, 30], team=1)
    _, commands = act(commander, request(entities=[unit(30, "militia"), unit(31, "militia"), enemy]))
    assert len([c for c in commands if c["op"] == "attack"]) == 2
    _, commands = act(commander, request(2, entities=[unit(30, "militia"), enemy]))
    assert any(c["op"] == "attack" for c in commands)


def test_automatic_construction_does_not_interrupt_paired_scout() -> None:
    commander = LlmCommander("chinese")
    entities = [unit(10, order="MOVE", move_goal=[70, 70]), unit(11)]
    req = request(entities=entities, construction_options=[{"building_def_id": "barracks", "builder_id": 10, "pos": [24, 0]}])
    _, commands = act(commander, req)
    assert not any(c["op"] == "place_building" for c in commands)


def test_visible_base_raid_overrides_muster_and_keeps_active_builders() -> None:
    commander = LlmCommander("chinese")
    entities = [unit(10, order="BUILD", target_id=2), building(2, "barracks", complete=False),
                unit(30, "militia"), unit(200, "militia", [10, 10], team=1)]
    req = request(entities=entities, army={"rally_point": [8, 8], "enemy_near_base_ids": [200]})
    _, commands = act(commander, req, ("set_strategy", {"stance": "muster", "army_target": 8}))
    assert any(c["op"] == "attack" and c["unit_id"] == 30 for c in commands)
    assert not any(c.get("unit_id") == 10 or c.get("builder_id") == 10 for c in commands)
    assert commander.phase == "defend"


def test_filter_owned_ids_visible_targets_bounds_conflicts_and_bad_arguments() -> None:
    commander = LlmCommander("chinese")
    req = request(entities=[unit(30, "militia"), unit(200, "militia", [20, 20], team=1)])
    out, commands = act(commander, req,
        ("attack", {"unit_id": 30, "target_id": 999}),
        ("move", {"unit_id": 200, "pos": [1, 1]}),
        ("move", {"unit_id": 30, "pos": [101, 0]}),
        ("move", {"unit_id": 30, "pos": [float("nan"), 0]}),
        ("move", {"unit_id": True, "pos": [0, 0]}),
        ("attack", {"unit_id": 30, "target_id": 200}),
        ("move", {"unit_id": 30, "pos": [1, 1]}),
        ("unknown_tool", {}))
    assert len(commands) == 1 and commands[0]["op"] == "attack"
    assert any("actor_conflict" in debug["message"] for debug in out["debug"])
    assert out["usage"]["total_tokens"] == 17


def test_batch_cost_population_and_producer_reservations() -> None:
    commander = LlmCommander("chinese")
    req = request(entities=[building(2, "barracks"), building(3, "barracks")])
    req.observation.economy.food = 60
    req.observation.economy.gold = 20
    out, commands = act(commander, req,
        ("train", {"building_id": 2, "unit_def_id": "militia"}),
        ("train", {"building_id": 2, "unit_def_id": "militia"}),
        ("train", {"building_id": 3, "unit_def_id": "militia"}))
    assert [c["building_id"] for c in commands] == [2]
    assert any("batch_budget_exceeded" in debug["message"] for debug in out["debug"])
    req = request(2, entities=[building(2, "barracks")])
    req.observation.economy.pop_used = 30
    req.observation.economy.pop_reserved = 1
    _, commands = act(commander, req, ("train", {"building_id": 2, "unit_def_id": "militia"}))
    assert not commands


def test_research_and_queued_production_use_observed_legality() -> None:
    commander = LlmCommander("chinese")
    req = request(entities=[building(2, "barracks", train_queue_empty=False, train_queue=["militia"]), building(1, "town_center", age_upgrade_reason="missing_mill")])
    out, commands = act(commander, req,
        ("train", {"building_id": 2, "unit_def_id": "militia"}),
        ("research_age", {"building_id": 1}),
        ("research_technology", {"building_id": 1, "technology_id": "invented"}))
    assert not any(c.get("building_id") == 2 or c["op"].startswith("research") for c in commands)
    assert any("producer_busy" in d["message"] for d in out["debug"])
    req = request(2, entities=[building(1, "town_center", age_upgrade_reason="")])
    _, commands = act(commander, req, ("research_age", {"building_id": 1}))
    assert [c["op"] for c in commands] == ["research_age"]


def test_rejected_site_is_cooled_and_another_legal_site_is_selected() -> None:
    commander = LlmCommander("chinese")
    _, initial = act(commander, request())
    failed = next(c for c in initial if c["op"] == "place_building")
    req = request(2)
    req.events = [GameEvent.model_validate(
        {"seq": 1, "type": "command_result", "command_id": failed["command_id"], "op": "place_building", "ok": False,
         "reason": "blocked_by_terrain", "command": failed})]
    brief = commander.prepare_request(req)
    assert "blocked_by_terrain" in brief.messages[-1].content
    out = commander.finish_response(req, response())
    commands = [json.loads(call["function"]["arguments"]) for call in out.choices[0].message.tool_calls or [] if call["function"]["name"] == "place_building"]
    assert commands and commands[0]["pos"] != failed["pos"]
    assert req.events[0].model_dump()["ok"] is False


def test_seen_enemy_memory_allows_only_coordinates_and_expires() -> None:
    commander = LlmCommander("chinese")
    enemy = building(200, "barracks", [50, 50], team=1)
    req = request(entities=[unit(30, "militia"), unit(31, "militia"), enemy])
    act(commander, req, ("set_strategy", {"stance": "attack", "army_target": 2}))
    unseen = request(2, entities=[unit(30, "militia"), unit(31, "militia")])
    unseen.observation.derived.enemy_tc_id = 999
    unseen.observation.derived.enemy_tc_pos = [90, 90]
    _, commands = act(commander, unseen, ("attack", {"unit_id": 30, "target_id": 200}))
    assert not any(c["op"] == "attack" for c in commands)
    assert any(c["op"] == "move" and c["pos"] == [50, 50] for c in commands)
    assert 999 not in commander.enemy_memory
    late = request(40, entities=[unit(30, "militia")])
    commander.prepare_request(late)
    assert not commander.enemy_memory


def test_team_instances_are_isolated_and_same_tick_is_idempotent() -> None:
    a, b = LlmCommander("chinese"), LlmCommander("chinese")
    req = request()
    first, _ = act(a, req, ("set_strategy", {"stance": "muster", "army_target": 8}))
    again, _ = act(a, req, ("set_strategy", {"stance": "attack", "army_target": 2}))
    assert first == again
    assert a.strategy.stance == "muster" and a.strategy.army_target == 8
    assert b.strategy.stance == "develop" and not b.scout_missions and not b.enemy_memory
    assert a.cached_response(req).model_dump() == first
    assert a.cached_response(request(2)) is None
    without_observation = req.model_copy(update={"observation": None})
    assert a.cached_response(without_observation) is None


def test_attack_waits_for_healthy_group_instead_of_scattered_total() -> None:
    commander = LlmCommander("chinese")
    enemy = unit(200, "militia", [80, 80], team=1)
    scattered = [unit(30, "militia", [-50, -50]), unit(31, "militia", [50, 50]), enemy]
    req = request(entities=scattered, army={"ready_unit_ids": [30, 31], "rally_point": [8, 8], "enemy_near_base_ids": []})
    _, commands = act(commander, req, ("set_strategy", {"stance": "attack", "army_target": 2}))
    assert not any(c["op"] == "attack" for c in commands)
    grouped = [unit(30, "militia", [8, 8]), unit(31, "militia", [9, 9], hp=10), enemy]
    req = request(2, entities=grouped, army={"ready_unit_ids": [30], "rally_point": [8, 8], "enemy_near_base_ids": []})
    _, commands = act(commander, req)
    assert not any(c["op"] == "attack" for c in commands)
    req = request(3, entities=[unit(30, "militia", [8, 8]), unit(31, "militia", [9, 9]), enemy],
                  army={"ready_unit_ids": [30, 31], "rally_point": [8, 8], "enemy_near_base_ids": []})
    _, commands = act(commander, req)
    assert len([c for c in commands if c["op"] == "attack"]) == 2


def test_transport_failure_continues_plan_and_is_explicit() -> None:
    commander = LlmCommander("chinese")
    req = request()
    commander.prepare_request(req)
    out = commander.continue_on_failure(req, "timeout")
    assert out.usage.total_tokens == 0
    assert any(e.category == "LLM_FALLBACK" and "timeout" in e.message for e in out.debug)
    names = [call["function"]["name"] for call in out.choices[0].message.tool_calls or []]
    assert "place_building" in names and "move" in names


def test_brief_is_in_actual_upstream_body_and_does_not_mutate_request() -> None:
    commander = LlmCommander("chinese")
    req = request()
    before = req.model_dump()
    prepared = commander.prepare_request(req)
    payload = build_openai_payload(prepared)
    assert req.model_dump() == before
    assert "observation" not in payload
    assert payload["tools"][-1]["function"]["name"] == "set_strategy"
    brief = json.loads(payload["messages"][-1]["content"].split("\n", 1)[1])
    assert brief["catalog"]["units"][1]["cost"] == {"food": 60, "gold": 20}
    assert brief["construction_options"][0]["builder_id"] == 10
    assert brief["scouting"]["frontiers"][0]["pos"] == [20, 20]


def test_old_observation_filters_model_commands_without_autopilot() -> None:
    commander = LlmCommander("chinese")
    req = request()
    req.observation.decision_context = {}
    _, commands = act(commander, req, ("gather", {"unit_id": 10, "target_id": 100}))
    assert [c["op"] for c in commands] == ["gather"]


def test_new_wood_discovery_rebalances_gold_workers_and_saves_barracks_wood() -> None:
    commander = LlmCommander("chinese")
    workers = [unit(eid, order="GATHER", target_id=102, gather_state="harvesting", carry_amount=0) for eid in (10, 11, 12)]
    entities = workers + [building(2, "mill"), building(3, "farm", resource_type="FOOD", amount=600),
                         {"id": 101, "kind": "resource", "resource_type": "WOOD", "pos": [10, 0], "amount": 1000},
                         {"id": 102, "kind": "resource", "resource_type": "GOLD", "pos": [0, 10], "amount": 1000}]
    req = request(entities=entities)
    req.observation.economy.wood = 100
    req.observation.decision_context["construction_options"].append({"building_def_id": "farm", "builder_id": 10, "pos": [40, 0]})
    _, commands = act(commander, req)
    assert any(c["op"] == "gather" and c["target_id"] == 101 for c in commands)
    assert any(c["op"] == "gather" and c["target_id"] == 3 for c in commands)
    assert len([c for c in commands if c["op"] == "gather"]) <= 2
    assert not any(c["op"] == "place_building" and c["building_def_id"] == "farm" for c in commands)


def test_delivery_worker_is_never_rebalanced() -> None:
    commander = LlmCommander("chinese")
    req = request(entities=[unit(10, order="GATHER", target_id=102, gather_state="to_drop_off", carry_amount=10),
        {"id": 101, "kind": "resource", "resource_type": "WOOD", "pos": [10, 0], "amount": 1000},
        {"id": 102, "kind": "resource", "resource_type": "GOLD", "pos": [0, 10], "amount": 1000}])
    _, commands = act(commander, req)
    assert not any(c.get("unit_id") == 10 or c.get("builder_id") == 10 for c in commands)


def test_resource_approach_watchdog_recovers_path_jitter_and_missing_target() -> None:
    commander = LlmCommander("chinese")
    entities = [unit(10, order="GATHER", target_id=101, gather_state="to_resource", stuck_frames=0, pos=[0, 0]),
                {"id": 101, "kind": "resource", "resource_type": "WOOD", "pos": [10, 0], "amount": 1000},
                {"id": 102, "kind": "resource", "resource_type": "WOOD", "pos": [11, 4], "amount": 1000}]
    req = request(entities=entities, construction_options=[])
    _, commands = act(commander, req)
    assert not any(c["op"] == "gather" for c in commands)
    # Small sideways movement is not progress toward the resource.
    entities[0]["pos"] = [0, .1]
    _, commands = act(commander, request(4, entities=entities, construction_options=[]))
    assert any(c["op"] == "gather" and c["target_id"] == 102 for c in commands)
    assert 101 in commander.resource_cooldowns
    broken = request(5, entities=[unit(11, order="GATHER", target_id=None, gather_state="to_resource"), entities[2]], construction_options=[])
    _, commands = act(commander, broken)
    assert any(c["op"] == "gather" and c["target_id"] == 102 for c in commands)


def test_resource_watchdog_keeps_real_approach_progress_and_deliveries() -> None:
    commander = LlmCommander("chinese")
    target = {"id": 101, "kind": "resource", "resource_type": "WOOD", "pos": [20, 0], "amount": 1000}
    for tick in range(1, 6):
        actor = unit(10, order="GATHER", target_id=101, gather_state="to_resource", pos=[tick * 2, 0])
        _, commands = act(commander, request(tick, entities=[actor, target], construction_options=[]))
        assert not any(c["op"] == "gather" for c in commands)
    actor = unit(10, order="GATHER", target_id=1, gather_state="to_drop_off", carry_amount=10, carry_type="WOOD")
    _, commands = act(commander, request(20, entities=[actor, target], construction_options=[]))
    assert not any(c["op"] == "gather" for c in commands)
    assert not commander.gather_approaches and not commander.resource_cooldowns


def test_resource_leaving_sight_does_not_interrupt_known_approach() -> None:
    commander = LlmCommander("chinese")
    target = {"id": 101, "kind": "resource", "resource_type": "WOOD", "pos": [30, 0], "amount": 1000}
    actor = unit(10, order="GATHER", target_id=101, gather_state="to_resource", pos=[0, 0])
    act(commander, request(entities=[actor, target], construction_options=[]))
    actor = unit(10, order="GATHER", target_id=None, gather_state="to_resource", pos=[10, 0], gather_resource_type="WOOD")
    _, commands = act(commander, request(2, entities=[actor], construction_options=[]))
    assert not any(c["op"] == "gather" for c in commands)
    assert 10 not in commander.stalled_workers


def test_json_content_commands_are_validated_and_cannot_bypass_filter() -> None:
    commander = LlmCommander("chinese")
    req = request(entities=[], construction_options=[])
    raw = response()
    raw.choices[0].message.content = json.dumps({"commands": [{"op": "move", "unit_id": 999, "pos": [1, 1]}]})
    commander.prepare_request(req)
    out = commander.finish_response(req, raw)
    assert out.choices[0].message.content is None and not out.choices[0].message.tool_calls
    req = request(2, entities=[unit(30, "militia")], construction_options=[])
    raw.choices[0].message.content = json.dumps({"commands": [{"op": "move", "unit_id": 30, "pos": [2, 2], "command_id": "unsafe_reused_id"}]})
    commander.prepare_request(req)
    out = commander.finish_response(req, raw)
    args = json.loads(out.choices[0].message.tool_calls[0]["function"]["arguments"])
    assert args["unit_id"] == 30 and args["command_id"] == "llm_2_0"
    assert out.choices[0].message.content is None


def test_fenced_action_content_with_insufficient_budget_is_not_forwarded() -> None:
    commander = LlmCommander("chinese")
    req = request(entities=[building(2, "barracks")], construction_options=[])
    req.observation.economy.food = 0
    req.observation.economy.gold = 0
    raw = response()
    raw.choices[0].message.content = '```json\n{"commands":[{"op":"train","building_id":2,"unit_def_id":"militia"}]}\n```'
    commander.prepare_request(req)
    out = commander.finish_response(req, raw)
    assert out.choices[0].message.content is None and not out.choices[0].message.tool_calls


def test_disabled_progression_uses_observed_availability_for_later_units() -> None:
    commander = LlmCommander("chinese")
    req = request(entities=[building(2, "archery_range", trainable=["archer"])], construction_options=[])
    req.observation.progression = None
    catalog = req.observation.decision_context["catalog"]
    catalog["progression_enabled"] = False
    catalog["units"].append({"id": "archer", **copy.deepcopy(CATALOG["units"]["archer"]), "unlocked": True})
    _, commands = act(commander, req, ("train", {"building_id": 2, "unit_def_id": "archer"}))
    assert any(c["op"] == "train" and c["unit_def_id"] == "archer" for c in commands)


def test_dead_owned_actor_and_producer_cannot_issue_commands() -> None:
    commander = LlmCommander("chinese")
    req = request(entities=[unit(30, "militia", hp=0), building(2, "barracks", hp=0)], construction_options=[])
    _, commands = act(commander, req, ("move", {"unit_id": 30, "pos": [1, 1]}),
                      ("train", {"building_id": 2, "unit_def_id": "militia"}))
    assert not commands


def test_depleted_opening_farm_cannot_spend_first_barracks_reserve() -> None:
    commander = LlmCommander("chinese")
    req = request(entities=[unit(10), building(2, "mill"), building(3, "farm", resource_type="FOOD", amount=0)])
    req.observation.economy.wood = 100
    req.observation.decision_context["construction_options"] = [{"building_def_id": "farm", "builder_id": 10, "pos": [40, 0]},
        {"building_def_id": "barracks", "builder_id": 10, "pos": [24, 0]}]
    _, commands = act(commander, req)
    assert not any(c["op"] == "place_building" for c in commands)
    req = request(2, entities=req.observation.entities)
    req.observation.economy.wood = 200
    req.observation.economy.pop_used = 29
    req.observation.decision_context["construction_options"] = [{"building_def_id": "house", "builder_id": 10, "pos": [0, 24]},
        {"building_def_id": "barracks", "builder_id": 10, "pos": [24, 0]}]
    _, commands = act(commander, req)
    assert next(c for c in commands if c["op"] == "place_building")["building_def_id"] == "barracks"


def test_stale_request_does_not_rewind_state_or_issue_commands() -> None:
    commander = LlmCommander("chinese")
    for tick in range(2, 8):
        act(commander, request(tick), ("set_strategy", {"stance": "muster", "army_target": 8}))
    previous_time = commander.last_time
    _, commands = act(commander, request(1), ("set_strategy", {"stance": "attack", "army_target": 2}))
    assert not commands and commander.strategy.stance == "muster"
    assert commander.last_time == previous_time


def test_public_probe_and_formed_army_explore_without_hidden_enemy_data() -> None:
    commander = LlmCommander("chinese")
    req = request(entities=[unit(20, "scout_cavalry", [70, 70]), unit(30, "militia", [80, 80]), unit(31, "militia", [82, 80])],
                  scouting={"frontiers": [{"pos": [60, 60]}, {"pos": [90, 90]}], "probes": [{"pos": [0, 0], "kind": "map_center"}], "scout_ids": [20]})
    req.observation.derived.own_tc_pos = [80, 80]
    req.observation.derived.enemy_tc_pos = [99, 99]
    req.observation.derived.enemy_tc_id = 999
    _, commands = act(commander, req, ("set_strategy", {"stance": "attack", "army_target": 2}))
    assert next(c for c in commands if c["op"] == "move" and c["unit_id"] == 20)["pos"] == [0, 0]
    assert {tuple(c["pos"]) for c in commands if c["op"] == "move" and c["unit_id"] in (30, 31)} == {(60, 60)}
    assert not any(c["op"] == "attack" for c in commands)
    assert not commander.enemy_memory


@pytest.mark.parametrize("bad", [{"stance": "attack", "army_target": 100}, {"stance": "cheat", "army_target": 4},
                                {"stance": "attack", "army_target": True},
                                {"stance": "attack", "army_target": 4, "military_building": ["barracks"]}])
def test_invalid_strategy_cannot_replace_plan(bad) -> None:
    commander = LlmCommander("chinese")
    act(commander, request(), ("set_strategy", bad))
    assert commander.strategy.stance == "develop" and commander.strategy.army_target == 6
