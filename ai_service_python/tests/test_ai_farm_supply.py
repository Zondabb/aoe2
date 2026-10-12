from brain.command_builder import CommandContext
from brain.land_progression import LandProgression
from brain.profile_loader import profile_for_id
from brain.stores import Blackboard
import pytest


def board(worker_count=3):
    buildings = [
        dict(id=1, kind="building", def_id="town_center", pos=[-100, -100], is_complete=True),
        dict(id=2, kind="building", def_id="mill", pos=[-84, -100], is_complete=True),
        dict(id=3, kind="building", def_id="lumber_camp", pos=[-84, -84], is_complete=True),
        dict(id=4, kind="building", def_id="barracks", pos=[-100, -84], is_complete=True),
    ]
    return Blackboard(wood=2000, progression={"age": 0}, team_buildings=buildings,
                      all_buildings=buildings.copy(), team_villagers=[
                          dict(id=10 + i, def_id="villager", order="NONE") for i in range(worker_count)])


def complete_command(bb, ctx):
    command = ctx.commands[0]
    farm = dict(id=100 + len(bb.team_buildings), kind="building", def_id="farm",
                pos=command.pos, is_complete=True, amount=175, resource_type="FOOD")
    bb.team_buildings.append(farm)
    bb.all_buildings.append(farm)
    bb.resource_nodes.append(farm)
    return farm


def test_farms_require_mill_and_low_local_natural_food():
    ai, profile, bb = LandProgression(), profile_for_id("teutons"), board()
    bb.resource_nodes = [dict(kind="resource", resource_type="FOOD", pos=[-80, -80], amount=125)]
    assert not ai._ensure_food_supply(CommandContext(1), bb, profile)
    bb.resource_nodes[0]["amount"] = 100
    assert ai._ensure_food_supply(CommandContext(2), bb, profile)
    bb.team_buildings = [bb.team_buildings[0]]
    assert not ai._ensure_food_supply(CommandContext(3), bb, profile)


def test_three_workers_keep_two_farms_and_replace_exhausted_plot():
    ai, profile, bb = LandProgression(), profile_for_id("chinese"), board()
    plots = []
    for tick in range(2):
        ctx = CommandContext(tick)
        before = bb.wood
        assert ai._ensure_food_supply(ctx, bb, profile)
        assert bb.wood == before - 60
        assert not ai._ensure_food_supply(ctx, bb, profile)
        plots.append(complete_command(bb, ctx))
    assert not ai._ensure_food_supply(CommandContext(2), bb, profile)
    plots[0]["amount"] = 0
    ctx = CommandContext(3)
    assert ai._ensure_food_supply(ctx, bb, profile)
    assert plots[0]["amount"] == 0 and ctx.commands[0].pos != plots[0]["pos"]


def test_farms_scale_with_the_workforce():
    ai, profile, bb = LandProgression(), profile_for_id("teutons"), board(12)
    for tick in range(6):
        ctx = CommandContext(tick)
        assert ai._ensure_food_supply(ctx, bb, profile)
        complete_command(bb, ctx)
    assert not ai._ensure_food_supply(CommandContext(6), bb, profile)


def test_farm_target_caps_at_ten_for_a_large_army_economy():
    ai, profile, bb = LandProgression(), profile_for_id("teutons"), board(30)
    bb.wood = 10000
    for tick in range(10):
        ctx = CommandContext(tick)
        assert ai._ensure_food_supply(ctx, bb, profile)
        complete_command(bb, ctx)
    assert not ai._ensure_food_supply(CommandContext(10), bb, profile)


def test_bootstrap_keeps_one_farm_while_saving_wood_for_first_barracks():
    ai, profile, bb = LandProgression(), profile_for_id("teutons"), board(8)
    bb.team_buildings = [b for b in bb.team_buildings if b["def_id"] != "barracks"]
    bb.all_buildings = bb.team_buildings.copy()
    ctx = CommandContext(1)
    assert ai._ensure_food_supply(ctx, bb, profile)
    complete_command(bb, ctx)
    bb.wood = 100
    assert not ai._ensure_food_supply(CommandContext(2), bb, profile)
    assert bb.wood == 100


def test_unaffordable_farm_does_not_spend_or_emit_command():
    ai, profile, bb = LandProgression(), profile_for_id("teutons"), board()
    bb.wood = 59
    ctx = CommandContext(1)
    assert not ai._ensure_food_supply(ctx, bb, profile)
    assert bb.wood == 59 and not ctx.commands


def test_remote_berries_do_not_starve_the_local_farm_economy():
    ai, profile, bb = LandProgression(), profile_for_id("teutons"), board()
    bb.resource_nodes = [dict(kind="resource", resource_type="FOOD", pos=[200, 200], amount=1000)]
    assert ai._ensure_food_supply(CommandContext(1), bb, profile)


def test_farm_does_not_replace_the_worker_building_an_unfinished_lumber_camp():
    ai, profile, bb = LandProgression(), profile_for_id("teutons"), board(1)
    foundation = dict(id=3, kind="building", def_id="lumber_camp", pos=[-84, -84], is_complete=False)
    bb.team_buildings.append(foundation)
    bb.all_buildings.append(foundation)
    bb.team_villagers[0].update(order="BUILD", target_id=3)
    before = bb.wood
    ctx = CommandContext(1)
    assert not ai._ensure_food_supply(ctx, bb, profile)
    assert ctx.commands == [] and bb.wood == before
    assert bb.team_villagers[0]["target_id"] == 3


def test_farm_uses_an_empty_handed_gatherer_instead_of_existing_builder():
    ai, profile, bb = LandProgression(), profile_for_id("teutons"), board(2)
    bb.team_villagers[0].update(order="BUILD", target_id=3)
    bb.team_villagers[1].update(order="GATHER", gather_state="to_resource", carry_amount=0)
    ctx = CommandContext(1)
    assert ai._ensure_food_supply(ctx, bb, profile)
    assert ctx.commands[0].builder_id == 11


@pytest.mark.parametrize("order,state,carry", [("ATTACK", "", 0), ("MOVE", "", 0), ("GATHER", "to_drop_off", 0), ("GATHER", "to_resource", 10), ("NONE", "", 10)])
def test_new_farm_preserves_combat_movement_and_resource_delivery(order, state, carry):
    ai, profile, bb = LandProgression(), profile_for_id("teutons"), board(1)
    bb.team_villagers[0].update(order=order, gather_state=state, carry_amount=carry)
    ctx = CommandContext(1)
    before = bb.wood
    assert not ai._ensure_food_supply(ctx, bb, profile)
    assert ctx.commands == [] and bb.wood == before


def test_farm_skips_a_worker_reserved_by_earlier_unit_command():
    ai, profile, bb = LandProgression(), profile_for_id("teutons"), board(2)
    ctx = CommandContext(1)
    ctx.issue_build(10, 3)
    assert ai._ensure_food_supply(ctx, bb, profile)
    assert [(c.op, c.unit_id, c.builder_id) for c in ctx.commands] == [("build", 10, None), ("place_building", None, 11)]


def test_farm_waits_if_the_only_worker_is_already_reserved():
    ai, profile, bb = LandProgression(), profile_for_id("teutons"), board(1)
    ctx = CommandContext(1)
    ctx.issue_gather(10, 99)
    before = bb.wood
    assert not ai._ensure_food_supply(ctx, bb, profile)
    assert len(ctx.commands) == 1 and bb.wood == before


def test_farm_cannot_override_an_earlier_builder_id_command():
    ai, profile, bb = LandProgression(), profile_for_id("teutons"), board(2)
    ctx = CommandContext(1)
    ctx.issue_place_building("house", [-100, -84], 10)
    before = bb.wood
    assert not ai._ensure_food_supply(ctx, bb, profile)
    assert len(ctx.commands) == 1 and ctx.commands[0].builder_id == 10 and bb.wood == before
