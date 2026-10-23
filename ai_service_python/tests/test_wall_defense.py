"""Wall investment, legal placement, queue ownership and gate access regressions."""
import copy

import pytest

from brain.land_progression import CATALOG
from brain.llm_commander import LlmCommander, _DecisionFrame
from brain.multi_agent.runtime import MultiAgentRuntime
from brain.tool_call_mapper import command_to_tool_call, tool_call_to_command
from protocol.models import Command, GameEvent
from test_llm_commander import building, unit
from test_multi_agent_runtime import accept, army, frame, issued, plan


def wall_option(**changes):
    return {"building_def_id": "palisade_wall", "builder_id": 10, "start": [18, -8], "end": [18, 8],
            "include_gate": False, "segment_count": 8, "cost": {"wood": 16}, "orientation": 1,
            "zone": "defensive_front", "preserves_access": True, **changes}


def defense_frame(tick=1, threat=True, **changes):
    entities = [building(1, "town_center"), building(2, "barracks", [12, 0]), unit(20, "scout_cavalry")]
    entities += [unit(10 + index) for index in range(8)] + army()
    entities += [{"id": 100, "kind": "resource", "resource_type": "FOOD", "pos": [4, 4], "amount": 1000},
                 {"id": 101, "kind": "resource", "resource_type": "WOOD", "pos": [4, -4], "amount": 1000}]
    if threat:
        entities.append(unit(200, "militia", [32, 0], team=1))
    req = frame(tick, time=100 + tick, entities=entities, construction_options=[], defense_options=[wall_option()], **changes)
    req.observation.capabilities = {"wall_segments": True, "gate_control": True}
    req.observation.decision_context["catalog"]["buildings"] += [
        {"id": name, **copy.deepcopy(CATALOG["buildings"][name]), "available": True}
        for name in ("palisade_wall", "stone_wall", "gate")]
    return req


def executor():
    runtime = MultiAgentRuntime("chinese")
    plan(runtime, "technology", target_age=0)
    plan(runtime, "defense", policy="reactive")
    return runtime


def wall_args(option=None):
    return {key: value for key, value in (option or wall_option()).items()
            if key in ("builder_id", "building_def_id", "start", "end", "include_gate")}


def test_reactive_defense_builds_only_after_observed_approach_and_keeps_economy():
    runtime = executor()
    assert not issued(executor().tick(defense_frame(threat=False)), "place_wall")
    result = runtime.tick(defense_frame())
    assert len(issued(result, "place_wall")) == 1
    assert issued(result, "train") and issued(result, "gather")
    task = runtime.tasks[issued(result, "place_wall")[0]["command_id"]]
    assert task["role"] == "defense" and task["cost"] == {"wood": 16}
    assert result["agent_status"]["defense"]["status"] == "running"


def test_model_defense_policy_changes_same_observation_to_proactive_wall():
    req = defense_frame(threat=False)
    reactive, proactive = executor(), executor()
    plan(proactive, "defense", policy="balanced")
    assert not issued(reactive.tick(req), "place_wall")
    assert issued(proactive.tick(req), "place_wall")
    context = proactive.planning_context("defense")
    assert context["defense_options"][0]["cost"] == {"wood": 16}
    assert "visible_enemies" in context and "fortifications" in context


def test_default_defense_builds_before_first_raid_once_economy_is_established():
    runtime = MultiAgentRuntime("chinese")
    plan(runtime, "technology", target_age=0)
    assert runtime.roles["defense"].plan["policy"] == "balanced"
    assert issued(runtime.tick(defense_frame(threat=False)), "place_wall")


def test_default_perimeter_budget_continues_past_old_short_wall_limit():
    runtime, req = executor(), defense_frame()
    req.observation.entities += [building(300 + i, "palisade_wall", [-20, i - 8]) for i in range(16)]
    assert runtime.roles["defense"].plan["max_segments"] >= 340
    assert issued(runtime.tick(req), "place_wall")
    plan(runtime, "defense", max_segments=512)


def test_explicit_small_wall_budget_is_not_reported_as_enclosure():
    runtime, req = executor(), defense_frame()
    plan(runtime, "defense", max_segments=4)
    req.observation.entities += [building(300 + i, "palisade_wall", [-20, i]) for i in range(4)]
    result = runtime.tick(req)
    assert not issued(result, "place_wall")
    assert result["agent_status"]["defense"]["status"] == "waiting"
    assert result["agent_status"]["defense"]["reason"] == "perimeter_budget_limit_not_closure"


def test_completed_gated_perimeter_uses_game_closure_and_planning_progress():
    runtime, req = executor(), defense_frame()
    perimeter = {"id": "wall_perimeter_v1:1", "total_segments": 212, "complete_segments": 212,
                 "missing_segments": 0, "blocked_segments": 0, "closed": True, "phase": "complete"}
    req.observation.decision_context["defense_plan"] = perimeter
    result = runtime.tick(req)
    assert not issued(result, "place_wall")
    assert result["agent_status"]["defense"]["reason"] == "perimeter_closed_maintain_gates"
    assert runtime.planning_context("defense")["defense_plan"] == perimeter


def test_connected_repair_precedes_new_unconnected_wall_batch():
    runtime, req = executor(), defense_frame(threat=False)
    plan(runtime, "defense", policy="balanced")
    req.observation.decision_context["defense_options"].append(wall_option(
        start=[-18, -8], end=[-18, 8], repair=True, connected=True, priority=10))
    assert issued(runtime.tick(req), "place_wall")[0]["start"] == [-18, -8]


def test_fixed_perimeter_material_survives_a_later_model_material_preference():
    runtime, req = executor(), defense_frame()
    plan(runtime, "defense", material="stone_wall")
    req.observation.decision_context["defense_plan"] = {"id": "perimeter", "material": "palisade_wall", "closed": False}
    assert issued(runtime.tick(req), "place_wall")[0]["building_def_id"] == "palisade_wall"
    # Older integrations without a persistent perimeter retain their explicit
    # material preference, rather than silently purchasing a different wall.
    req = defense_frame()
    runtime = executor()
    plan(runtime, "defense", material="stone_wall")
    assert not issued(runtime.tick(req), "place_wall")


def test_resource_shortage_retains_wall_wood_demand_without_starving_training():
    runtime, req = executor(), defense_frame()
    req.observation.economy.wood = 110
    definition = next(d for d in req.observation.decision_context["catalog"]["buildings"] if d["id"] == "palisade_wall")
    definition.update(available=False, blocked_reason="资源不足")
    result = runtime.tick(req)
    assert not issued(result, "place_wall")
    assert issued(result, "train")
    assert runtime.demands["wood"] >= 16


def test_large_army_leaves_command_slots_for_perimeter_food_and_production():
    runtime, req = executor(), defense_frame(threat=False)
    plan(runtime, "defense", policy="fortify")
    req.observation.entities = [e for e in req.observation.entities if e.get("def_id") != "militia"] + army(70)
    result = runtime.tick(req)
    first = {c["unit_id"] for c in issued(result, "move") if c["unit_id"] >= 30}
    assert 0 < len(first) <= 24
    assert issued(result, "place_wall") and issued(result, "gather") and issued(result, "train")
    assert len(result["commands"]) <= 36
    # Command receipts clear pending orders, while units still need to move.
    # Later soldiers must receive the next tactical share instead of the first
    # group consuming the limited slots on every observation.
    next_req = req.model_copy(deep=True)
    next_req.metadata.tick = next_req.metadata.observation_seq = 2
    next_req.metadata.time_sec += 2
    next_req.events = [GameEvent.model_validate(e) for e in accept(result)]
    later = runtime.tick(next_req)
    second = {c["unit_id"] for c in issued(later, "move") if c["unit_id"] >= 30}
    assert second and first.isdisjoint(second)
    assert len(later["commands"]) <= 36


@pytest.mark.parametrize("problem", [None, "manual", "loaded", "delivery", "queue", "building", "far", "enemy"])
def test_perimeter_reveal_uses_only_safe_small_steps_and_preserves_worker_ownership(problem):
    runtime, req = executor(), defense_frame(threat=False)
    plan(runtime, "defense", policy="balanced")
    context = req.observation.decision_context
    context["defense_options"] = []
    context["defense_scout_options"] = [{"unit_id": 10, "pos": [10, 0], "reason": "reveal_perimeter", "side": 0}]
    worker = next(e for e in req.observation.entities if e["id"] == 10)
    if problem == "manual":
        runtime.leases[10] = {"role": "human", "until": 200}
    elif problem == "loaded":
        worker["carry_amount"] = 5
    elif problem == "delivery":
        worker["gather_state"] = "to_drop_off"
    elif problem == "queue":
        worker["build_queue_ids"] = [300]
    elif problem == "building":
        worker["order"] = "BUILD"
    elif problem == "far":
        context["defense_scout_options"][0]["pos"] = [35, 0]
    elif problem == "enemy":
        req.observation.entities.append(unit(200, "militia", [15, 0], team=1))
    result = runtime.tick(req)
    moves = [c for c in issued(result, "move") if c["unit_id"] == 10]
    assert bool(moves) is (problem is None)
    if problem is None:
        assert not any(c.get("unit_id") == 10 for c in issued(result, "gather"))
        worker.update(order="MOVE", pos=[3, 0])
        req.metadata.tick = 2
        req.metadata.time_sec += 1
        result = runtime.tick(req)
        assert not any(c.get("unit_id") == 10 for c in result["commands"])
        assert runtime.leases[10]["role"] == "defense"


@pytest.mark.parametrize("enemy", [False, True])
def test_perimeter_probe_releases_stalled_worker_or_retreats_from_new_threat(enemy):
    runtime, req = executor(), defense_frame(threat=False)
    plan(runtime, "defense", policy="balanced")
    req.observation.decision_context["defense_options"] = []
    req.observation.decision_context["defense_scout_options"] = [{"unit_id": 10, "pos": [10, 0]}]
    runtime.tick(req)
    worker = next(e for e in req.observation.entities if e["id"] == 10)
    worker.update(order="MOVE", pos=[2, 0], move_goal=[10, 0])
    req.metadata.tick = 2
    req.metadata.time_sec += 2 if enemy else 25
    if enemy:
        req.observation.entities.append(unit(200, "militia", [12, 0], team=1))
    result = runtime.tick(req)
    commands = [c for c in result["commands"] if c.get("unit_id") == 10]
    assert len(commands) == 1
    assert commands[0]["op"] == ("move" if enemy else "stop")
    if enemy:
        assert commands[0]["pos"] == [0, 0]
    assert "perimeter_scout" not in runtime.roles["defense"].memory


def test_defense_checks_wall_endpoints_and_abandoned_foundation_for_enemy_danger():
    req = defense_frame()
    next(e for e in req.observation.entities if e["id"] == 200)["pos"] = [19, 14]
    # The midpoint is safe, but the end of this line is within melee danger.
    assert not issued(executor().tick(req), "place_wall")
    req.observation.entities.append(building(300, "palisade_wall", [18, 8], complete=False))
    assert not issued(executor().tick(req), "build")


@pytest.mark.parametrize("job", ["wall", "foundation", "probe"])
def test_expanded_perimeter_worker_avoids_visible_enemy_outside_old_base_radius(job):
    runtime, req = executor(), defense_frame(threat=False)
    plan(runtime, "defense", policy="fortify")
    worker = next(e for e in req.observation.entities if e["id"] == 10)
    worker["pos"] = [44, 0]
    req.observation.entities.append(unit(200, "militia", [47, 0], team=1))
    context = req.observation.decision_context
    context["defense_options"] = [wall_option(start=[44, -8], end=[44, 8])]
    if job == "foundation":
        req.observation.entities.append(building(300, "palisade_wall", [44, 0], complete=False))
    elif job == "probe":
        context["defense_options"] = []
        context["defense_scout_options"] = [{"unit_id": 10, "pos": [44, 10]}]
    result = runtime.tick(req)
    assert not issued(result, "place_wall") and not issued(result, "build")
    assert not [c for c in issued(result, "move") if c["unit_id"] == 10]


def test_defense_prioritizes_safe_screen_facing_observed_flank_raid():
    req = defense_frame()
    next(e for e in req.observation.entities if e["id"] == 200)["pos"] = [0, 34]
    req.observation.decision_context["defense_options"].append(wall_option(
        start=[-8, 20], end=[8, 20], zone="defensive_flank"))
    commands = issued(executor().tick(req), "place_wall")
    assert len(commands) == 1 and commands[0]["start"] == [-8, 20]


@pytest.mark.parametrize("problem", ["unsupported", "workers", "food_supply", "food_budget", "wood_reserve", "no_producer", "cap", "manual", "under_fire"])
def test_defense_preserves_opening_and_manual_or_unsafe_workers(problem):
    runtime, req = executor(), defense_frame()
    if problem == "unsupported":
        req.observation.capabilities = {}
    elif problem == "workers":
        req.observation.entities = [e for e in req.observation.entities if e["id"] not in (15, 16, 17)]
    elif problem == "food_supply":
        req.observation.entities = [e for e in req.observation.entities if e.get("resource_type") != "FOOD"]
    elif problem == "food_budget":
        req.observation.economy.food = 40
    elif problem == "wood_reserve":
        req.observation.economy.wood = 110
    elif problem == "no_producer":
        req.observation.entities = [e for e in req.observation.entities if e.get("def_id") != "barracks"]
    elif problem == "cap":
        plan(runtime, "defense", max_segments=4)
    elif problem == "manual":
        runtime.leases[10] = {"role": "human", "until": 200}
    else:
        next(e for e in req.observation.entities if e["id"] == 200)["pos"] = [22, 0]
    assert not issued(runtime.tick(req), "place_wall")


def test_wall_purchase_charges_whole_line_and_never_partial_budget():
    req = defense_frame()
    req.observation.economy.wood = 15
    f = _DecisionFrame(LlmCommander("chinese"), req)
    assert not f.add("place_wall", wall_args(), "model")
    assert f.budget["wood"] == 15 and not f.commands
    req.observation.economy.wood = 16
    f = _DecisionFrame(LlmCommander("chinese"), req)
    assert f.add("place_wall", wall_args(), "model")
    assert f.budget["wood"] == 0


@pytest.mark.parametrize("problem", ["unoffered", "unsafe_access", "hidden", "delivery", "queue", "foreign", "nan_cost", "outside", "gate_flag"])
def test_wall_validator_rejects_unobserved_unsafe_or_invalid_line(problem):
    req, args = defense_frame(), wall_args()
    option = req.observation.decision_context["defense_options"][0]
    worker = next(e for e in req.observation.entities if e["id"] == 10)
    if problem == "unoffered":
        args["end"] = [18, 9]
    elif problem == "unsafe_access":
        option["preserves_access"] = False
    elif problem == "hidden":
        req.observation.placement_visibility = {"origin": [-100, -100], "cell_size": 2, "grid_size": [100, 100], "sources": [[0, 0, 5]]}
    elif problem == "delivery":
        worker["carry_amount"] = 10
    elif problem == "queue":
        worker["build_queue_ids"] = [500]
    elif problem == "foreign":
        worker["team"] = 1
    elif problem == "nan_cost":
        option["cost"] = {"wood": float("nan")}
    elif problem == "outside":
        option["end"] = args["end"] = [18, 110]
    else:
        args["include_gate"] = "false"
    f = _DecisionFrame(LlmCommander("chinese"), req)
    assert not f.add("place_wall", args, "model")
    assert f.budget["wood"] == req.observation.economy.wood


def test_pending_wall_does_not_buy_twice_and_tracks_all_foundations_to_completion():
    runtime = executor()
    first = runtime.tick(defense_frame())
    command = issued(first, "place_wall")[0]
    assert not issued(runtime.tick(defense_frame(2)), "place_wall")
    req = defense_frame(3)
    req.events = []
    req.observation.decision_context["action_feedback"] = [{"seq": 1, "type": "command_result", "command_id": command["command_id"], "ok": True, "created_entity_ids": [300, 301]}]
    req.observation.entities += [building(300, "palisade_wall", [18, -8]), building(301, "palisade_wall", [18, -6], complete=False)]
    worker = next(e for e in req.observation.entities if e["id"] == 10)
    worker.update(order="BUILD", target_id=301, build_queue_ids=[])
    runtime.tick(req)
    task = runtime.tasks[command["command_id"]]
    assert task["status"] == "running" and task["created_entity_ids"] == [300, 301]
    assert command["command_id"] not in runtime.pending
    req.metadata.tick = 4
    req.metadata.time_sec = 400
    runtime.tick(req)
    assert task["status"] == "running", "Long wall queues must survive the generic 180-second task window"
    req.metadata.tick = 5
    next(e for e in req.observation.entities if e["id"] == 301)["is_complete"] = True
    runtime.tick(req)
    assert task["status"] == "completed"


def test_queued_wall_worker_and_foundations_are_not_reassigned_between_segments():
    runtime, req = executor(), defense_frame()
    worker = next(e for e in req.observation.entities if e["id"] == 10)
    worker.update(order="NONE", build_queue_ids=[300, 301])
    req.observation.entities += [building(300, "palisade_wall", [18, -8], complete=False), building(301, "gate", [18, 0], complete=False)]
    result = runtime.tick(req)
    assert not any(c.get("unit_id", c.get("builder_id")) == 10 for c in result["commands"])
    assert not issued(result, "build") and not issued(result, "place_wall")


def test_defense_resumes_abandoned_wall_foundation_with_its_own_task():
    runtime, req = executor(), defense_frame()
    req.observation.entities += [building(300, "palisade_wall", [18, -8], complete=False)]
    result = runtime.tick(req)
    commands = issued(result, "build")
    assert len(commands) == 1 and commands[0]["building_id"] == 300
    assert runtime.tasks[commands[0]["command_id"]]["role"] == "defense"


def test_locked_gate_plan_keeps_exit_open_for_outside_friendly_unit():
    runtime, req = executor(), defense_frame()
    plan(runtime, "defense", gate_mode="locked")
    req.observation.entities += [building(300, "gate", [18, 0], gate_state="locked"), unit(70, "militia", [35, 0])]
    result = runtime.tick(req)
    assert issued(result, "set_gate_state")[0]["gate_state"] == "auto"


def test_gate_control_rejects_foreign_gates_and_honors_manual_building_lease():
    runtime, req = executor(), defense_frame()
    req.observation.entities += [building(300, "gate", [18, 0], gate_state="locked")]
    runtime.leases[300] = {"role": "human", "until": 200}
    assert not issued(runtime.tick(req), "set_gate_state")
    req.observation.entities[-1]["team"] = 1
    f = _DecisionFrame(LlmCommander("chinese"), req)
    assert not f.add("set_gate_state", {"building_id": 300, "gate_state": "auto"}, "model")


@pytest.mark.parametrize("command", [Command(command_id="w", op="place_wall", **wall_args()),
                                    Command(command_id="g", op="set_gate_state", building_id=300, gate_state="auto"),
                                    Command(command_id="p", op="place_building", builder_id=10, building_def_id="gate", pos=[18, 0], orientation=3)])
def test_wall_and_gate_commands_preserve_geometry_through_tool_mapping(command):
    restored = tool_call_to_command(command_to_tool_call(command, 0), 1, 1)
    assert restored == command.model_dump(exclude_none=True)
