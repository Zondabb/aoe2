from copy import deepcopy

import pytest

from brain.command_builder import CommandContext
from brain.scout_manager import ScoutManager
from brain.stores import Blackboard, PHASE_ECO, PHASE_ATTACK
from brain.director import AiDirector
from brain.economy_manager import EconomyManager
from brain.profile_loader import profile_for_id


def actor(entity_id=2, name="scout_cavalry", order="NONE", pos=(106, 128)):
    return {"id": entity_id, "kind": "unit", "def_id": name, "team": 1, "pos": list(pos), "order": order, "hp": 45}


def board(unit=None):
    unit = unit or actor()
    return Blackboard(ai_team=1, progression={"age": 0}, map_bounds=(-240, -240, 240, 240), own_tc_pos=(120, 120), team_units=[unit], team_villagers=[unit] if unit["def_id"] == "villager" else [], team_buildings=[{"id": 1, "kind": "building", "def_id": "town_center", "pos": [120, 120]}])


def test_opening_scout_moves_with_no_visible_resource_or_enemy():
    bb = board()
    manager = ScoutManager()
    ctx = CommandContext(tick=1)
    manager.tick(ctx, bb, PHASE_ECO)
    command, = ctx.commands
    assert command.op == "move" and command.unit_id == 2
    assert command.pos == pytest.approx([120 - 24 / 2**0.5, 120 - 24 / 2**0.5])
    assert bb.enemy_tc_pos == (0, 0) and not bb.resource_nodes


def test_hidden_entities_cannot_change_scout_route():
    observed = board()
    with_hidden = deepcopy(observed)
    with_hidden.all_entities = [{"id": 999, "pos": [-238, 237], "kind": "resource", "resource_type": "FOOD", "amount": 50000}, {"id": 998, "pos": [233, -222], "kind": "building", "def_id": "town_center", "team": 0}]
    outputs = []
    for bb in [observed, with_hidden]:
        ctx = CommandContext(tick=1)
        ScoutManager().tick(ctx, bb, PHASE_ECO)
        outputs.append([c.model_dump() for c in ctx.commands])
    assert outputs[0] == outputs[1]


def test_waypoints_expand_remain_inside_rectangular_public_map_and_progress_on_arrival():
    bb = board()
    bb.map_bounds = (100, 100, 270, 195)
    manager = ScoutManager()
    destinations = []
    for tick in range(80):
        ctx = CommandContext(tick=tick)
        bb.match_time = tick * 2
        manager.tick(ctx, bb, PHASE_ECO)
        if ctx.commands:
            destination = ctx.commands[0].pos
            destinations.append(destination)
            bb.team_units[0]["pos"] = destination
            bb.team_units[0]["order"] = "MOVE"
    assert all(102 <= x <= 268 and 102 <= y <= 193 for x, y in destinations)
    assert any((x - 120)**2 + (y - 120)**2 > 70**2 for x, y in destinations)
    assert len({tuple(p) for p in destinations}) == len(destinations)


@pytest.mark.parametrize("order", ["GATHER", "BUILD", "ATTACK", "MOVE"])
def test_existing_orders_are_not_overridden(order):
    ctx = CommandContext(tick=1)
    ScoutManager().tick(ctx, board(actor(order=order)), PHASE_ECO)
    assert ctx.commands == []


def test_no_scout_saved_map_uses_one_idle_worker_then_releases_it_to_economy():
    bb = board(actor(name="villager"))
    manager = ScoutManager()
    ctx = CommandContext(tick=1)
    manager.tick(ctx, bb, PHASE_ECO)
    assert len(ctx.commands) == 1
    bb.team_units[0]["order"] = "GATHER"
    bb.resource_nodes = [{"id": 9, "pos": [99, 103], "resource_type": "FOOD", "amount": 125}]
    ctx = CommandContext(tick=2)
    manager.tick(ctx, bb, PHASE_ECO)
    assert ctx.commands == []


def test_pending_builder_command_reserves_worker():
    bb = board(actor(name="villager"))
    ctx = CommandContext(tick=1)
    ctx.issue_place_building("mill", [110, 120], 2)
    ScoutManager().tick(ctx, bb, PHASE_ECO)
    assert [c.op for c in ctx.commands] == ["place_building"]


def test_stalled_route_advances_and_live_route_is_not_spammed():
    bb = board()
    manager = ScoutManager()
    first = CommandContext(tick=1)
    manager.tick(first, bb, PHASE_ECO)
    bb.team_units[0]["order"] = "MOVE"
    bb.match_time = 1
    running = CommandContext(tick=2)
    manager.tick(running, bb, PHASE_ECO)
    assert running.commands == []
    bb.match_time = 10
    stalled = CommandContext(tick=3)
    manager.tick(stalled, bb, PHASE_ECO)
    assert len(stalled.commands) == 1 and stalled.commands[0].pos != first.commands[0].pos


def test_ready_army_probes_geometry_after_all_resource_types_observed():
    bb = board()
    bb.resource_nodes = [{"id": i + 10, "pos": [120, 130], "resource_type": kind, "amount": 100} for i, kind in enumerate(["FOOD", "WOOD", "GOLD", "STONE"])]
    ctx = CommandContext(tick=1)
    ScoutManager().tick(ctx, bb, PHASE_ATTACK)
    assert ctx.commands[0].pos == [0, 0]


def test_director_integrates_scout_from_filtered_observation_without_hidden_targets():
    obs = {"map_bounds": {"min": [-240, -240], "max": [240, 240]}, "progression": {"age": 0}, "economy": {"food": 0, "wood": 0, "gold": 0, "stone": 0, "pop_used": 1, "pop_cap": 5}, "derived": {"own_tc_pos": [120, 120], "enemy_tc_pos": [0, 0]}, "entities": [{"id": 1, "kind": "building", "def_id": "town_center", "team": 1, "pos": [120, 120], "is_complete": True, "age_upgrade_reason": "资源不足", "trainable": []}, actor()]}
    response = AiDirector("teutons").evaluate(1, "map", 1, 0, 0, obs)
    assert [(c.op, c.unit_id) for c in response.commands] == [("move", 2)]


def economic_board(kind="GOLD"):
    bb = board()
    food = {"id": 10, "kind": "resource", "pos": [100, 100], "resource_type": "FOOD", "amount": 125}
    ore = {"id": 11, "kind": "resource", "pos": [65, 135], "resource_type": kind, "amount": 800}
    bb.resource_nodes = [food, ore]
    bb.team_villagers = [dict(actor(entity_id=i, name="villager", order="GATHER"), gather_state="to_resource", carry_amount=0, _last_resource=food, last_resource_id=10) for i in (2, 3, 4)]
    return bb


@pytest.mark.parametrize("kind", ["GOLD", "STONE"])
def test_one_empty_handed_surplus_worker_rebalances_to_visible_ore(kind):
    bb = economic_board(kind)
    ctx = CommandContext(tick=1)
    EconomyManager().assign_gatherers(ctx, bb, profile_for_id("teutons"), PHASE_ECO)
    assert [(c.op, c.unit_id, c.target_id) for c in ctx.commands] == [("gather", 2, 11)]


@pytest.mark.parametrize("order,state,carry", [("GATHER", "to_drop_off", 0), ("GATHER", "to_resource", 10), ("BUILD", "", 0), ("ATTACK", "", 0)])
def test_rebalance_preserves_deliveries_carrying_building_and_attacking(order, state, carry):
    bb = economic_board()
    for worker in bb.team_villagers:
        worker.update(order=order, gather_state=state, carry_amount=carry)
    ctx = CommandContext(tick=1)
    EconomyManager().assign_gatherers(ctx, bb, profile_for_id("teutons"), PHASE_ECO)
    assert ctx.commands == []


def test_fog_absence_preserves_mining_order_and_cached_resource_kind_counts():
    bb = economic_board()
    manager = EconomyManager()
    manager.assign_gatherers(CommandContext(tick=1), bb, profile_for_id("teutons"), PHASE_ECO)
    bb.team_villagers[0].update(last_resource_id=11, _last_resource=None)
    bb.team_villagers[1]["_last_resource"] = None
    bb.team_villagers[2]["_last_resource"] = None
    bb.resource_nodes = []
    ctx = CommandContext(tick=2)
    manager.assign_gatherers(ctx, bb, profile_for_id("teutons"), PHASE_ECO)
    assert ctx.commands == []
    assert manager._count_active_gatherers(bb) == {0: 2, 1: 0, 2: 1, 3: 0}


def test_rebalance_cannot_assign_hidden_ore_or_take_last_food_worker():
    bb = economic_board()
    bb.resource_nodes = bb.resource_nodes[:1]
    bb.all_entities.append({"id": 11, "kind": "resource", "resource_type": "GOLD", "pos": [65, 135], "amount": 800})
    ctx = CommandContext(tick=1)
    EconomyManager().assign_gatherers(ctx, bb, profile_for_id("teutons"), PHASE_ECO)
    assert ctx.commands == []
    bb = economic_board()
    bb.team_villagers = bb.team_villagers[:1]
    ctx = CommandContext(tick=2)
    EconomyManager().assign_gatherers(ctx, bb, profile_for_id("teutons"), PHASE_ECO)
    assert ctx.commands == []
