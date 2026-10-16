"""Behavioural regressions for tempo, coordination and observation truth."""
from __future__ import annotations

import copy
import json

import pytest

from brain.land_progression import CATALOG
from brain.multi_agent.runtime import MultiAgentRuntime, ROLE_SCHEMAS
from protocol.models import GameEvent
from test_llm_commander import building, request, unit


def frame(tick=1, entities=None, time=None, events=(), **context):
    req = request(tick, entities=entities, **context)
    req.metadata = req.metadata.model_copy(update={"protocol_version": 3, "session_epoch": "test-epoch", "observation_seq": tick,
                                                  "time_sec": float(time if time is not None else tick)})
    req.events = [GameEvent.model_validate(e) for e in events]
    return req


def plan(runtime, role, **changes):
    value = {**runtime.roles[role].plan, **changes}
    assert runtime.apply_plan(role, value)


def army(count=6, pos=None):
    return [unit(30 + i, "militia", pos or [0, 0]) for i in range(count)]


def enemy_tc(pos=None, **kwargs):
    return building(200, "town_center", pos or [40, 40], team=1, hp=2400, max_hp=2400, **kwargs)


def issued(result, op):
    return [c for c in result["commands"] if c["op"] == op]


def accept(result, seq=1):
    return [{"seq": seq + i, "type": "command_result", "command_id": c["command_id"], "ok": True} for i, c in enumerate(result["commands"])]


def test_default_opener_assigns_roles_and_outside_barracks_before_house_or_mill():
    runtime = MultiAgentRuntime("chinese")
    req = frame()
    req.observation.economy.wood = 200
    req.observation.economy.food = 200
    req.observation.economy.pop_cap = 5
    req.observation.decision_context["construction_options"] += [
        {"building_def_id": "barracks", "builder_id": 10, "pos": [6, 0]},
        {"building_def_id": "mill", "builder_id": 11, "pos": [15, 15]},
    ]
    req.observation.entities = [e for e in req.observation.entities if e.get("resource_type") != "FOOD"]
    out = runtime.tick(req)
    assert set(out["agent_status"]) == set(ROLE_SCHEMAS)
    placed = issued(out, "place_building")
    assert len(placed) == 1 and placed[0]["building_def_id"] == "barracks"
    assert placed[0]["pos"] != [6, 0]
    assert issued(out, "gather") and issued(out, "move")
    actors = [c.get("unit_id", c.get("builder_id")) for c in out["commands"] if "unit_id" in c or "builder_id" in c]
    assert len(actors) == len(set(actors))
    assert all(c["command_id"].startswith("ma_test-epoch_") for c in out["commands"])


def test_population_fully_blocked_prioritizes_house():
    req = frame()
    req.observation.economy.pop_cap = req.observation.economy.pop_used
    out = MultiAgentRuntime().tick(req)
    assert issued(out, "place_building")[0]["building_def_id"] == "house"


def test_failed_unaffordable_construction_does_not_lease_idle_workers():
    req = frame()
    req.observation.economy.wood = 0
    out = MultiAgentRuntime().tick(req)
    assert not issued(out, "place_building")
    assert {c["unit_id"] for c in issued(out, "gather")} == {10, 11, 12}


def test_construction_can_borrow_safe_economy_worker_without_interrupting_delivery():
    runtime = MultiAgentRuntime()
    req = frame(entities=[unit(10, order="GATHER", target_id=100), unit(11, order="GATHER", gather_state="to_drop_off", carry_amount=10),
                          {"id": 100, "kind": "resource", "resource_type": "WOOD", "amount": 1000, "pos": [5, 5]}])
    runtime.leases[10] = {"role": "economy", "until": 20}
    out = runtime.tick(req)
    assert any(c.get("builder_id") == 10 for c in issued(out, "place_building"))
    assert not any(c.get("unit_id") == 11 or c.get("builder_id") == 11 for c in out["commands"])


@pytest.mark.parametrize("role", list(ROLE_SCHEMAS))
def test_role_plans_are_independent_and_strict_bounded_schema(role):
    runtime = MultiAgentRuntime()
    valid = copy.deepcopy(runtime.roles[role].plan)
    assert runtime.apply_plan(role, valid)
    assert not runtime.apply_plan(role, {**valid, "commands": [{"op": "attack"}]})
    assert not runtime.apply_plan(role, {})
    numeric = next(name for name, rule in ROLE_SCHEMAS[role]["properties"].items() if rule["type"] != "string")
    assert not runtime.apply_plan(role, {**valid, numeric: float("nan")})
    assert not runtime.apply_plan(role, {**valid, numeric: True})
    assert runtime.roles[role].plan == valid


def test_role_specific_context_is_bounded_copied_and_has_goal_version():
    runtime = MultiAgentRuntime()
    runtime.tick(frame())
    economy = runtime.planning_context("economy")
    combat = runtime.planning_context("combat")
    assert "workers" in economy and "sites" not in economy and "visible_enemies" not in economy
    assert "visible_enemies" in combat and "workers" not in combat
    assert economy["goal_version"] == runtime.goal_version
    economy["plan"]["worker_target"] = 999
    assert runtime.roles["economy"].plan["worker_target"] != 999
    json.dumps([runtime.planning_context(role) for role in runtime.roles], allow_nan=False)


def test_muster_size_frozen_and_departure_has_deadline_without_model_response():
    runtime = MultiAgentRuntime()
    plan(runtime, "commander", army_target=8, muster_timeout=20)
    first = runtime.tick(frame(entities=army(4) + [enemy_tc()]))
    assert not issued(first, "attack")
    plan(runtime, "combat", army_target=24)
    out = runtime.tick(frame(2, entities=army(4) + [enemy_tc()], time=22, events=accept(first)))
    assert out["goals"]["sortie_target"] == 8
    assert len(issued(out, "attack")) >= 3  # one soldier may hold a scout lease
    assert all(c["target_id"] == 200 for c in issued(out, "attack"))


def test_visible_enemy_tc_is_objective_not_far_away_villager():
    runtime = MultiAgentRuntime()
    out = runtime.tick(frame(entities=army() + [enemy_tc(), unit(201, "villager", [90, 90], team=1)]))
    assert issued(out, "attack")
    assert {c["target_id"] for c in issued(out, "attack")} == {200}


def test_observed_overwhelming_defenders_block_suicidal_timed_departure():
    runtime = MultiAgentRuntime()
    plan(runtime, "commander", army_target=2, muster_timeout=20)
    enemy = [unit(210 + i, "militia", [39, 39], team=1) for i in range(12)]
    runtime.tick(frame(entities=army(2) + [enemy_tc()] + enemy))
    out = runtime.tick(frame(2, entities=army(2) + [enemy_tc()] + enemy, time=130))
    assert out["goals"]["sortie_departed"] is None
    assert not issued(out, "attack")
    assert out["agent_status"]["combat"]["reason"] == "observed_defenders_require_reinforcements"


def test_hidden_tc_memory_survives_long_absence_but_cannot_emit_hidden_attack_id():
    runtime = MultiAgentRuntime()
    runtime.tick(frame(entities=army() + [enemy_tc()]))
    out = runtime.tick(frame(2, entities=army(pos=[10, 10]), time=600))
    assert runtime.enemy_knowledge[200]["pos"] == [40, 40]
    assert runtime.enemy_knowledge[200]["visible"] is False
    assert not issued(out, "attack")
    assert any(c["pos"] == [40, 40] for c in issued(out, "move"))


def test_visible_empty_remembered_footprint_resolves_site_without_claiming_victory():
    runtime = MultiAgentRuntime()
    runtime.tick(frame(entities=[enemy_tc()]))
    req = frame(2, entities=[])
    req.observation.placement_visibility = {"origin": [-100, -100], "cell_size": 2, "grid_size": [100, 100], "sources": [[40, 40, 10]]}
    out = runtime.tick(req)
    assert 200 not in runtime.enemy_knowledge
    assert not out["goals"]["victory_confirmed"]


def test_tc_destruction_uses_actual_victory_rule_and_ends_all_orders():
    runtime = MultiAgentRuntime()
    runtime.tick(frame(entities=army() + [enemy_tc()]))
    req = frame(2, entities=army(), events=[{"seq": 1, "type": "entity_destroyed", "entity_id": 200}])
    req.observation.decision_context["victory_conditions"] = {"type": "destroy_any_enemy_town_center"}
    out = runtime.tick(req)
    assert out["goals"]["victory_confirmed"] and out["goals"]["phase"] == "victory"
    assert out["commands"] == []
    assert all(s["status"] == "complete" for s in out["agent_status"].values())
    assert not runtime.pending


def test_local_defenders_override_tc_but_distant_harassment_does_not():
    out = MultiAgentRuntime().tick(frame(entities=army(pos=[30, 30]) + [enemy_tc(), unit(201, "militia", [32, 32], team=1), unit(202, "militia", [95, 95], team=1)]))
    assert {c["target_id"] for c in issued(out, "attack")} == {201}


def test_damage_stall_starts_at_engagement_not_travel_and_recovery_requests_siege():
    runtime = MultiAgentRuntime()
    first = runtime.tick(frame(entities=army() + [enemy_tc([90, 90])]))
    runtime.tick(frame(2, entities=army() + [enemy_tc([90, 90])], time=60, events=accept(first)))
    assert not runtime.goals["needs_siege"]
    nearby = army(pos=[80, 80]) + [enemy_tc([90, 90])]
    runtime.tick(frame(3, entities=nearby, time=70))
    runtime.tick(frame(4, entities=nearby, time=110))
    assert runtime.goals["needs_siege"]


def test_blocked_attack_approach_retains_detour_between_ticks():
    runtime = MultiAgentRuntime()
    units = army()
    first = runtime.tick(frame(entities=units + [enemy_tc([90, 90])]))
    for u in units:
        u.update(order="ATTACK", target_id=200)
    runtime.tick(frame(2, entities=units + [enemy_tc([90, 90])], time=3, events=accept(first)))
    detoured = runtime.tick(frame(3, entities=units + [enemy_tc([90, 90])], time=16))
    moves = issued(detoured, "move")
    assert moves
    for command in moves:
        next(u for u in units if u["id"] == command["unit_id"]).update(order="MOVE", move_goal=command["pos"])
    next_frame = runtime.tick(frame(4, entities=units + [enemy_tc([90, 90])], time=17, events=accept(detoured, 100)))
    assert not any(c.get("unit_id") in {m["unit_id"] for m in moves} and c["op"] == "attack" for c in next_frame["commands"])


def test_scout_selects_strategic_probe_over_nearby_frontier_and_then_opposite():
    runtime = MultiAgentRuntime()
    scout = unit(20, "scout_cavalry", [80, 80])
    ctx = {"scout_ids": [20], "frontiers": [{"pos": [75, 75]}], "probes": [{"pos": [0, 0]}, {"pos": [-80, -80]}]}
    req = frame(entities=[scout], scouting=ctx)
    req.observation.derived.own_tc_pos = [80, 80]
    first = runtime.tick(req)
    assert issued(first, "move")[0]["pos"] == [0, 0]
    scout.update(pos=[0, 0])
    req = frame(2, entities=[scout], scouting=ctx, events=accept(first))
    req.observation.derived.own_tc_pos = [80, 80]
    second = runtime.tick(req)
    assert issued(second, "move")[0]["pos"] == [-80, -80]


def test_scout_stall_changes_goal_and_does_not_repeat_failed_point():
    runtime = MultiAgentRuntime()
    scout = unit(20, "scout_cavalry", [80, 80])
    ctx = {"scout_ids": [20], "frontiers": [], "probes": [{"pos": [0, 0]}, {"pos": [-80, -80]}]}
    req = frame(entities=[scout], scouting=ctx)
    req.observation.derived.own_tc_pos = [80, 80]
    first = runtime.tick(req)
    scout.update(order="MOVE", move_goal=[0, 0])
    req = frame(2, entities=[scout], scouting=ctx, time=14, events=accept(first))
    req.observation.derived.own_tc_pos = [80, 80]
    second = runtime.tick(req)
    assert issued(second, "move")[0]["pos"] == [-80, -80]


def test_first_military_purchase_and_savings_not_starved_by_tc_villagers():
    entities = [building(1, "town_center"), building(2, "barracks")] + [unit(10 + i) for i in range(6)]
    for food in (50, 60, 100):
        req = frame(entities=entities)
        req.observation.economy.food = food
        req.observation.economy.wood = 0
        runtime = MultiAgentRuntime("chinese")
        out = runtime.tick(req)
        trained = issued(out, "train")
        if food < 60:
            assert trained == []  # preserve income for the 60 food militia
        else:
            assert trained[0]["unit_def_id"] == "militia"
            assert not any(c["unit_def_id"] == "villager" for c in trained)


def test_pending_purchase_reserves_budget_until_receipt_or_snapshot_reconciliation():
    runtime = MultiAgentRuntime()
    req = frame(entities=[building(2, "barracks")])
    req.observation.economy.food, req.observation.economy.gold = 60, 20
    first = runtime.tick(req)
    assert len(issued(first, "train")) == 1
    second_req = frame(2, entities=[building(2, "barracks"), building(3, "barracks")])
    second_req.observation.economy.food, second_req.observation.economy.gold = 60, 20
    second = runtime.tick(second_req)
    assert not issued(second, "train")
    third_req = frame(3, entities=[building(2, "barracks", train_queue=["militia"], train_queue_empty=False), building(3, "barracks")], events=accept(first))
    third_req.observation.economy.food, third_req.observation.economy.gold = 60, 20
    third = runtime.tick(third_req)
    assert [c["building_id"] for c in issued(third, "train")] == [3]
    assert runtime.tasks[issued(first, "train")[0]["command_id"]]["status"] == "running"


def test_training_completion_requires_actual_birth_not_acceptance():
    runtime = MultiAgentRuntime()
    first = runtime.tick(frame(entities=[building(2, "barracks")]))
    cmd = issued(first, "train")[0]
    runtime.tick(frame(2, entities=[building(2, "barracks", train_queue_empty=False, production={"queue_ids": [7]})],
                       events=[{"seq": 1, "type": "command_result", "command_id": cmd["command_id"], "ok": True, "queue_id": 7}]))
    assert runtime.tasks[cmd["command_id"]]["status"] == "running"
    runtime.tick(frame(3, entities=[building(2, "barracks"), unit(99, "militia")], events=[
        {"seq": 2, "type": "train_completed", "building_id": 2, "queue_id": 7, "created_entity_id": 99, "lineage": {"command_id": cmd["command_id"]}}]))
    assert runtime.tasks[cmd["command_id"]]["status"] == "completed"
    assert runtime.tasks[cmd["command_id"]]["spawned_entity_id"] == 99


def test_event_retry_does_not_reset_rejection_backoff_or_human_lease():
    runtime = MultiAgentRuntime()
    first = runtime.tick(frame())
    cmd = issued(first, "place_building")[0]
    reports = [{"seq": 10, "type": "command_result", "command_id": cmd["command_id"], "ok": False, "reason": "blocked"},
               {"seq": 11, "type": "human_command", "unit_id": 11}]
    runtime.tick(frame(2, events=reports))
    until = runtime.failures[runtime.validator._key(cmd)]["until"]
    human_until = runtime.leases[11]["until"]
    runtime.tick(frame(3, events=reports))
    assert runtime.failures[runtime.validator._key(cmd)]["until"] == until
    assert runtime.leases[11]["until"] == human_until


@pytest.mark.parametrize("event_type", ["human_command", "manual_command"])
def test_manual_actor_and_tc_lease_prevents_ai_overwrite(event_type):
    req = frame(events=[{"seq": 1, "type": event_type, "unit_id": 10}, {"seq": 2, "type": event_type, "building_id": 1}])
    out = MultiAgentRuntime().tick(req)
    assert not any(c.get("unit_id") == 10 or c.get("builder_id") == 10 or c.get("building_id") == 1 for c in out["commands"])


def test_event_gap_reconciles_foundation_from_full_snapshot_without_duplicate_purchase():
    runtime = MultiAgentRuntime()
    first = runtime.tick(frame())
    cmd = issued(first, "place_building")[0]
    req = frame(2, entities=frame().observation.entities + [building(300, "barracks", cmd["pos"], complete=False)])
    req.metadata = req.metadata.model_copy(update={"event_delivery": {"gap": True, "resync_required": True}})
    out = runtime.tick(req)
    assert not any(c["building_def_id"] == "barracks" for c in issued(out, "place_building"))
    assert runtime.tasks[cmd["command_id"]]["status"] in ("running", "cancelled")
    assert any("event_gap" in row["message"] for row in out["debug"])


def test_age_research_gets_tc_window_before_civilian_production():
    entities = [building(1, "town_center", age_upgrade_reason=""), building(2, "barracks"), building(3, "mill")] + [unit(10 + i) for i in range(8)]
    req = frame(entities=entities)
    req.observation.economy.food = 500
    req.observation.economy.wood = 0
    req.observation.decision_context["catalog"]["age_upgrade"] = {"cost": {"food": 500}, "buildings": ["barracks", "mill", "lumber_camp"], "required_distinct_buildings": 2}
    out = MultiAgentRuntime().tick(req)
    assert issued(out, "research_age") == [{"command_id": "ma_test-epoch_1_0", "op": "research_age", "building_id": 1}]
    assert not any(c["building_id"] == 1 for c in issued(out, "train"))


def test_age_budget_applies_to_construction_as_well_as_training():
    runtime = MultiAgentRuntime()
    entities = [building(1, "town_center", age_upgrade_reason="资源不足"), building(2, "barracks"), building(3, "mill")] + [unit(10 + i) for i in range(8)]
    req = frame(entities=entities)
    req.observation.economy.food = 400
    req.observation.economy.wood = 600
    req.observation.economy.pop_cap = 4
    catalog = req.observation.decision_context["catalog"]
    catalog["age_upgrade"] = {"cost": {"food": 500}, "buildings": ["barracks", "mill"], "required_distinct_buildings": 2}
    next(b for b in catalog["buildings"] if b["id"] == "house")["cost"] = {"food": 250}
    out = runtime.tick(req)
    assert runtime.tech_reserve["food"] == 200
    assert not issued(out, "place_building")  # artificial food-cost house exposes all-consumer budget accounting


def test_farms_capped_by_staffable_jobs_and_low_food_prioritized_over_optional_mine():
    runtime = MultiAgentRuntime()
    farmers = [unit(10 + i) for i in range(8)]
    farms = [building(300 + i, "farm", [i * 15, 20], amount=300, resource_type="FOOD") for i in range(12)]
    req = frame(entities=[building(2, "barracks"), building(3, "mill")] + farmers + farms,
                construction_options=[{"building_def_id": "farm", "builder_id": 10, "pos": [20, 20]}])
    req.observation.economy.food = 4000
    first = runtime.tick(req)
    assert not any(c["building_def_id"] == "farm" for c in issued(first, "place_building"))
    req = frame(2, entities=[building(2, "barracks"), building(3, "mill")] + farmers,
                construction_options=[{"building_def_id": "farm", "builder_id": 10, "pos": [20, 20]}], events=accept(first))
    req.observation.economy.food = 50
    assert any(c["building_def_id"] == "farm" for c in issued(runtime.tick(req), "place_building"))


def test_resource_delivery_not_retasked_and_food_surplus_redirects_idle_workers():
    entities = [unit(10, order="GATHER", gather_state="to_drop_off", carry_amount=10, carry_type="FOOD", target_id=1), unit(11), unit(12), building(2, "barracks"),
                {"id": 100, "kind": "resource", "resource_type": "FOOD", "pos": [2, 2], "amount": 1000},
                {"id": 101, "kind": "resource", "resource_type": "WOOD", "pos": [3, 3], "amount": 1000}]
    req = frame(entities=entities, construction_options=[])
    req.observation.economy.food, req.observation.economy.wood = 4000, 0
    out = MultiAgentRuntime().tick(req)
    assert not any(c.get("unit_id") == 10 for c in out["commands"])
    assert all(c["target_id"] == 101 for c in issued(out, "gather"))


def test_repeated_missing_purchase_receipt_has_backoff_not_every_tick_repurchase():
    runtime = MultiAgentRuntime()
    req = frame(entities=[building(2, "barracks")])
    first = runtime.tick(req)
    assert issued(first, "train")
    count = 0
    for tick in range(2, 41):
        count += len(issued(runtime.tick(frame(tick, entities=[building(2, "barracks")])), "train"))
    assert count <= 2
    assert any(t.get("reason") == "not_observed_after_receipt_window" for t in runtime.tasks.values())


def test_duplicate_tick_cached_and_old_tick_does_not_mutate_runtime():
    runtime = MultiAgentRuntime()
    req = frame()
    first = runtime.tick(req)
    assert runtime.tick(req) == first
    count = len(runtime.tasks)
    assert runtime.tick(frame(0))["commands"] == []
    assert len(runtime.tasks) == count


def test_occupied_only_food_plot_does_not_idle_workers_when_wood_is_available():
    workers = [unit(10, order="GATHER", gather_state="gathering", target_id=300, last_resource_id=300, gather_resource_type="FOOD")]
    workers += [unit(11 + i) for i in range(8)]
    entities = workers + [building(1, "town_center"), building(2, "barracks"), building(3, "mill"),
                           building(300, "farm", [8, 8], amount=300, resource_type="FOOD"),
                           {"id": 100, "kind": "resource", "resource_type": "WOOD", "amount": 1000, "pos": [4, 4]}]
    req = frame(entities=entities, construction_options=[])
    req.observation.economy.food = 0
    runtime = MultiAgentRuntime()
    plan(runtime, "economy", food_workers_ratio=.65)
    out = runtime.tick(req)
    gathers = issued(out, "gather")
    assert {c["unit_id"] for c in gathers} == {11 + i for i in range(8)}
    assert {c["target_id"] for c in gathers} == {100}


def test_remote_seen_food_does_not_suppress_local_farm_supply():
    entities = [building(1, "town_center"), building(2, "barracks"), building(3, "mill")] + [unit(10 + i) for i in range(8)]
    entities += [{"id": 100, "kind": "resource", "resource_type": "FOOD", "amount": 5000, "pos": [90, 90]}]
    req = frame(entities=entities, construction_options=[{"building_def_id": "farm", "builder_id": 10, "pos": [20, 20]}])
    req.observation.economy.food = 90
    out = MultiAgentRuntime().tick(req)
    assert any(c["building_def_id"] == "farm" for c in issued(out, "place_building"))


def test_age_reservation_accumulates_income_until_research_instead_of_training_forever():
    runtime = MultiAgentRuntime()
    food = 400
    started = False
    for tick in range(1, 31):
        entities = [building(1, "town_center", age_upgrade_reason="" if food >= 500 else "资源不足"), building(2, "barracks"), building(3, "mill")] + [unit(10 + i) for i in range(8)]
        req = frame(tick, entities=entities, construction_options=[])
        req.observation.economy.food = food
        req.observation.economy.wood = 0
        req.observation.decision_context["catalog"]["age_upgrade"] = {"cost": {"food": 500}, "buildings": ["barracks", "mill"], "required_distinct_buildings": 2}
        out = runtime.tick(req)
        if issued(out, "research_age"):
            started = True
            break
        # All other money comes only from real observed income. Training costs
        # are debited rather than providing an artificial infinite bank.
        for command in issued(out, "train"):
            food -= CATALOG["units"][command["unit_def_id"]]["cost"].get("food", 0)
        food += 20
    assert started, "Ordinary production must not permanently starve approved age advancement"


def test_sustained_ineffective_tc_damage_requests_siege_even_when_hp_falls():
    runtime = MultiAgentRuntime()
    first = runtime.tick(frame(entities=army(pos=[80, 80]) + [enemy_tc([90, 90])]))
    tc = enemy_tc([90, 90])
    tc["hp"] = 2390
    runtime.tick(frame(2, time=47, entities=army(pos=[80, 80]) + [tc], events=accept(first)))
    assert runtime.goals["needs_siege"]


def test_expired_muster_with_wounded_survivors_enters_explicit_rebuild_state():
    runtime = MultiAgentRuntime()
    runtime.tick(frame(entities=army(3) + [enemy_tc()]))
    wounded = army(3)
    for soldier in wounded:
        soldier["hp"] = 8
    out = runtime.tick(frame(2, time=150, entities=wounded + [enemy_tc()]))
    assert out["goals"]["phase"] == "rebuild"
    assert out["agent_status"]["combat"]["reason"] == "insufficient_ready_force_rebuild_support"
    assert not issued(out, "attack")


def test_combat_route_information_request_becomes_scout_mission():
    runtime = MultiAgentRuntime()
    runtime.roles["scout"].memory["route_requested"] = [60, -40]
    req = frame(entities=[unit(20, "scout_cavalry")], scouting={"scout_ids": [20], "frontiers": [{"pos": [10, 10]}], "probes": [{"pos": [-80, -80]}]})
    out = runtime.tick(req)
    assert issued(out, "move")[0]["pos"] == [60, -40]


def test_resource_selection_prices_repeated_compatible_delivery_not_only_worker_distance():
    entities = [building(1, "town_center"), building(2, "barracks"), building(3, "mill", [90, 90]), unit(10, pos=[90, 90]),
                {"id": 100, "kind": "resource", "resource_type": "WOOD", "amount": 1000, "pos": [90, 91]},
                {"id": 101, "kind": "resource", "resource_type": "WOOD", "amount": 1000, "pos": [10, 0]}]
    req = frame(entities=entities, construction_options=[])
    out = MultiAgentRuntime().tick(req)
    assert issued(out, "gather")[0]["target_id"] == 101, "Nearby mill cannot accept wood; recurring delivery to TC dominates initial approach"


def test_empty_handed_remote_food_worker_is_reassigned_but_delivery_keeps_its_load():
    entities = [building(1, "town_center"), building(2, "barracks"), building(3, "mill"), building(300, "farm", [12, 12], amount=300, resource_type="FOOD"),
                unit(10, pos=[89, 89], order="GATHER", target_id=100, last_resource_id=100, gather_resource_type="FOOD", gather_state="to_resource"),
                unit(11, pos=[88, 88], order="GATHER", target_id=3, last_resource_id=100, gather_resource_type="FOOD", gather_state="to_drop_off", carry_amount=10),
                {"id": 100, "kind": "resource", "resource_type": "FOOD", "amount": 1000, "pos": [90, 90]},
                {"id": 101, "kind": "resource", "resource_type": "WOOD", "amount": 1000, "pos": [10, 0]}]
    req = frame(entities=entities, construction_options=[])
    out = MultiAgentRuntime().tick(req)
    assert any(c.get("unit_id") == 10 and c.get("target_id") != 100 for c in out["commands"])
    assert not any(c.get("unit_id") == 11 for c in out["commands"])


def test_remote_food_does_not_resume_when_local_farm_is_still_being_built():
    entities = [building(1, "town_center"), building(300, "farm", [12, 12], complete=False),
                unit(10, pos=[89, 89], order="GATHER", target_id=100, last_resource_id=100, gather_resource_type="FOOD"),
                {"id": 100, "kind": "resource", "resource_type": "FOOD", "amount": 1000, "pos": [90, 90]}]
    req = frame(entities=entities, construction_options=[])
    # Another already building worker avoids repurposing the distant worker as
    # a construction helper, so this specifically tests its collection order.
    req.observation.entities.append(unit(11, order="BUILD", target_id=300))
    out = MultiAgentRuntime().tick(req)
    assert any(c["op"] == "move" and c.get("unit_id") == 10 and c["pos"] == [0, 0] for c in out["commands"])
    assert not any(c.get("target_id") == 100 for c in out["commands"])


def long_delivery_frame(tick=1, wood=60, time=None, events=(), farm=True):
    workers = [unit(10 + i, order="GATHER", target_id=100, last_resource_id=100, gather_resource_type="WOOD", pos=[50, 0]) for i in range(6)]
    entities = [building(1, "town_center"), building(2, "barracks"), building(3, "mill")] + workers
    if farm:
        entities += [building(300, "farm", [12, 12], amount=300, resource_type="FOOD")]
    entities += [{"id": 100, "kind": "resource", "resource_type": "WOOD", "amount": 1000, "pos": [60, 0]}]
    req = frame(tick, entities=entities, time=time, events=events, construction_options=[
        {"building_def_id": "lumber_camp", "builder_id": 10, "pos": [50, 12]},
        {"building_def_id": "farm", "builder_id": 11, "pos": [24, 24]}])
    req.observation.economy.wood, req.observation.economy.food = wood, 20
    req.observation.decision_context["catalog"]["buildings"].append({"id": "lumber_camp", **copy.deepcopy(CATALOG["buildings"]["lumber_camp"]), "available": True})
    return req


def test_lumber_camp_saves_slow_income_until_price_instead_of_spending_every_60_on_farm():
    runtime = MultiAgentRuntime()
    previous = {"commands": []}
    camp = None
    for tick in range(1, 12):
        # Only ten wood per 25 simulation seconds: a short unconditional 60s
        # release would repeatedly spend the 60-wood balance before reaching 100.
        out = runtime.tick(long_delivery_frame(tick, wood=(tick - 1) * 10, time=(tick - 1) * 25, events=accept(previous, tick * 100)))
        placed = issued(out, "place_building")
        assert not any(c["building_def_id"] == "farm" for c in placed)
        if placed:
            camp = placed[0]
            break
        previous = out
    assert camp and camp["building_def_id"] == "lumber_camp"


def test_camp_reservation_yields_on_no_income_and_preserves_first_farm_bridge():
    runtime = MultiAgentRuntime()
    first = runtime.tick(long_delivery_frame())
    assert not issued(first, "place_building")
    expired = runtime.tick(long_delivery_frame(2, time=182, events=accept(first)))
    assert any(c["building_def_id"] == "farm" for c in issued(expired, "place_building"))
    fresh = MultiAgentRuntime().tick(long_delivery_frame(farm=False))
    assert any(c["building_def_id"] == "farm" for c in issued(fresh, "place_building")), "Do not save for a camp at the expense of the first food bridge"


def test_age_building_price_is_saved_before_additional_farms():
    runtime = MultiAgentRuntime()
    def make(tick, wood, events=()):
        req = long_delivery_frame(tick, wood=wood, events=events)
        req.observation.entities += [unit(50), unit(51), building(4, "lumber_camp", [55, 0])]
        req.observation.progression.age = 1
        catalog = req.observation.decision_context["catalog"]
        catalog["buildings"] += [{"id": name, **copy.deepcopy(CATALOG["buildings"][name]), "available": True} for name in ("archery_range", "stable")]
        catalog["age_upgrade"] = {"buildings": ["archery_range", "stable"], "required_distinct_buildings": 2, "cost": {"food": 800, "gold": 200}}
        req.observation.decision_context["construction_options"] += [{"building_def_id": "stable", "builder_id": 10, "pos": [40, 25]}, {"building_def_id": "archery_range", "builder_id": 11, "pos": [25, 40]}]
        return req
    first = runtime.tick(make(1, 60))
    assert not issued(first, "place_building")
    second = runtime.tick(make(2, 175, accept(first)))
    assert issued(second, "place_building")[0]["building_def_id"] in ("stable", "archery_range")


def test_first_sortie_food_protection_does_not_freeze_worker_growth_after_losses():
    runtime = MultiAgentRuntime("chinese")
    runtime.tick(frame(entities=army() + [enemy_tc()]))
    req = frame(2, entities=[building(1, "town_center"), building(2, "barracks")] + [unit(10 + i) for i in range(6)])
    req.observation.economy.food, req.observation.economy.wood = 50, 0
    out = runtime.tick(req)
    assert any(c["unit_def_id"] == "villager" for c in issued(out, "train")), "After the initial sortie, military losses must not reset the opening civilian embargo"
