from brain.build_manager import BuildManager
from brain.command_builder import CommandContext
from brain.game_data import BUILDINGS
from brain.stores import Blackboard
from brain.build_placement import can_plan_settlement


def test_one_unapplied_foundation_per_tick_keeps_training_and_replans_next_tick():
    town_center = {"id": 1, "def_id": "town_center", "pos": [-100, -80], "is_complete": True}
    bb = Blackboard(food=10000, wood=10000, gold=10000, pop_cap=50)
    bb.team_buildings = [town_center]
    bb.all_buildings = [town_center]
    bb.team_villagers = [{"id": 2, "def_id": "villager", "order": "NONE"}]
    ctx = CommandContext(tick=1)
    ctx.issue_train(1, "villager")
    manager = BuildManager()
    assert manager.ensure_building(ctx, bb, "barracks")
    assert not manager.ensure_building(ctx, bb, "stable")
    assert [command.op for command in ctx.commands] == ["train", "place_building"]
    placed = {"id": 3, "def_id": "barracks", "pos": ctx.commands[1].pos, "is_complete": False}
    bb.team_buildings.append(placed)
    bb.all_buildings.append(placed)
    next_tick = CommandContext(tick=2, next_build_slot=ctx.next_build_slot)
    assert manager.ensure_building(next_tick, bb, "stable")
    assert can_plan_settlement("stable", tuple(next_tick.commands[0].pos), bb.all_buildings, BUILDINGS)
