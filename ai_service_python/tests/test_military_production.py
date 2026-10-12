import json
from pathlib import Path

import pytest

from brain.command_builder import CommandContext
from brain.director import AiDirector
from brain.economy_manager import EconomyManager
from brain.land_progression import AGE_COSTS, PREREQUISITES, LandProgression
from brain.profile_loader import profile_for_id
from brain.stores import Blackboard, ObservationStore
from protocol.models import TickRequest


def building(name, entity_id=1, **extra):
    return dict(id=entity_id, kind="building", def_id=name, team=1, pos=[40, 40],
                hp=1000, max_hp=1000, is_complete=True, train_queue_empty=True,
                **extra)


def board(age=0, buildings=(), **extra):
    return Blackboard(pop_cap=50, progression={"age": age}, team_buildings=list(buildings),
                      **extra)


def train_commands(ctx):
    return [(c.building_id, c.unit_def_id) for c in ctx.commands if c.op == "train"]


@pytest.mark.parametrize("age,workers,unit", [(0, 8, "militia"), (1, 12, "man_at_arms"), (2, 16, "long_swordsman")])
def test_first_army_trains_without_saving_entire_next_age_cost(age, workers, unit):
    bb = board(age, [building("barracks", trainable=[unit])], food=60, gold=20,
               villager_count=workers)
    ctx = CommandContext(1)
    LandProgression().tick(ctx, bb, profile_for_id("teutons"))
    assert train_commands(ctx) == [(1, unit)]
    assert (bb.food, bb.gold) == (0, 0)


def test_all_idle_producers_train_with_one_shared_resource_and_population_budget():
    bb = board(1, [building("barracks", 1, trainable=["man_at_arms"]),
                   building("archery_range", 2, trainable=["archer"]),
                   building("stable", 3, trainable=["scout_cavalry"])],
               food=140, wood=25, gold=65)
    ctx = CommandContext(1)
    LandProgression().tick(ctx, bb, profile_for_id("teutons"))
    assert train_commands(ctx) == [(1, "man_at_arms"), (2, "archer"), (3, "scout_cavalry")]
    assert (bb.food, bb.wood, bb.gold, bb.pop_used) == (0, 0, 0, 3)


def test_an_affordable_counter_unit_replaces_an_unaffordable_preferred_unit():
    bb = board(1, [building("barracks", trainable=["man_at_arms", "spearman"])],
               food=35, wood=25, gold=0)
    ctx = CommandContext(1)
    LandProgression().tick(ctx, bb, profile_for_id("teutons"))
    assert train_commands(ctx) == [(1, "spearman")]


def test_castle_trains_unique_units_instead_of_a_suicide_petard():
    bb = board(2, [building("castle", trainable=["petard", "teutonic_knight"])], food=85, gold=40)
    ctx = CommandContext(1)
    LandProgression().tick(ctx, bb, profile_for_id("teutons"))
    assert train_commands(ctx) == [(1, "teutonic_knight")]


def test_upgrades_cannot_starve_first_army_or_occupy_its_producer():
    bb = board(1, [building("barracks", trainable=["militia"],
                           technologies=[{"id": "man_at_arms", "reason": ""}])], food=100, gold=40,
               team_units=[dict(def_id="militia")])
    ctx = CommandContext(1)
    LandProgression().tick(ctx, bb, profile_for_id("teutons"))
    assert train_commands(ctx) == [(1, "militia")]
    assert all(c.op != "research_technology" for c in ctx.commands)


def test_saving_for_an_age_starts_only_after_economy_army_and_prerequisites_exist():
    profile = profile_for_id("teutons")
    prerequisites = [building(name, i + 1) for i, name in enumerate(PREREQUISITES[1])]
    bb = board(1, prerequisites, villager_count=12, military_count=6)
    assert LandProgression._age_reserve(bb, profile, 1, False) == AGE_COSTS[1]
    bb.threat_near_base = True
    assert LandProgression._age_reserve(bb, profile, 1, False) == {}
    bb.threat_near_base = False
    bb.team_buildings.pop()
    assert LandProgression._age_reserve(bb, profile, 1, False) == {}
    bb.team_buildings = prerequisites
    bb.villager_count = 8
    assert LandProgression._age_reserve(bb, profile, 1, False) == {}


def test_feudal_army_precedes_castle_research_and_threat_disables_age_research():
    tc = building("town_center", trainable=["villager"], age_upgrade_reason="")
    bb = board(1, [tc], food=1000, gold=200, villager_count=12)
    ctx = CommandContext(1)
    LandProgression().tick(ctx, bb, profile_for_id("teutons"))
    assert not ctx.commands
    bb.military_count = 6
    bb.threat_near_base = True
    LandProgression().tick(CommandContext(2), bb, profile_for_id("teutons"))
    assert bb.food == 1000
    bb.threat_near_base = False
    ctx = CommandContext(3)
    LandProgression().tick(ctx, bb, profile_for_id("teutons"))
    assert [(c.op, c.building_id) for c in ctx.commands] == [("research_age", 1)]


@pytest.mark.parametrize("age,target", [(0, 8), (1, 12), (2, 16), (3, 20)])
def test_economy_target_grows_by_age(age, target):
    bb = board(age, [building("town_center", trainable=["villager"])], food=50,
               villager_count=target - 1)
    ctx = CommandContext(1)
    LandProgression().tick(ctx, bb, profile_for_id("teutons"))
    assert train_commands(ctx) == [(1, "villager")]


def test_queued_population_is_retained_by_protocol_and_prevents_oversubscription():
    payload = json.loads((Path(__file__).parent / "fixtures/opening_eco.json").read_text(encoding="utf8"))["request"]
    payload["observation"]["economy"].update(pop_used=4, pop_reserved=1, pop_cap=5)
    restored = TickRequest.model_validate(payload).model_dump()["observation"]
    store, bb = ObservationStore(), Blackboard()
    store.load_from_dict(restored)
    store.apply_to_blackboard(bb, 1, 0)
    assert bb.pop_used == 5
    bb.progression = {"age": 1}
    bb.team_buildings = [building("barracks", trainable=["man_at_arms"])]
    bb.food, bb.gold = 60, 20
    ctx = CommandContext(1)
    LandProgression().tick(ctx, bb, profile_for_id("teutons"))
    assert not train_commands(ctx)


def test_population_room_builds_house_even_when_soldiers_are_unaffordable():
    buildings = [building("town_center"), building("barracks", 2, trainable=["militia"])]
    bb = board(buildings=buildings, wood=30, pop_used=49, team_villagers=[dict(id=10, order="NONE")],
               all_buildings=buildings.copy())
    ctx = CommandContext(1)
    LandProgression().tick(ctx, bb, profile_for_id("teutons"))
    assert [(c.op, c.building_def_id) for c in ctx.commands] == [("place_building", "house")]


def test_first_barracks_precedes_higher_age_prerequisites():
    buildings = [building("town_center"), building("mill", 2)]
    bb = board(1, buildings, wood=175, team_villagers=[dict(id=10, order="NONE")],
               all_buildings=buildings.copy(), resource_nodes=[dict(kind="resource", resource_type="FOOD", amount=1000, pos=[50, 50])])
    ctx = CommandContext(1)
    LandProgression().tick(ctx, bb, profile_for_id("teutons"))
    assert [(c.op, c.building_def_id) for c in ctx.commands] == [("place_building", "barracks")]


def test_builders_are_not_reassigned_to_gather_or_multiple_foundations_in_same_tick():
    foundations = [dict(id=1, is_complete=False), dict(id=2, is_complete=False)]
    workers = [dict(id=10, order="NONE", pos=[40, 40]), dict(id=11, order="NONE", pos=[40, 40])]
    bb = board(buildings=foundations, team_villagers=workers,
               resource_nodes=[dict(id=90, kind="resource", resource_type="FOOD", amount=1000, pos=[50, 50])])
    ctx, economy = CommandContext(1), EconomyManager()
    economy.assign_builders(ctx, bb)
    economy.assign_gatherers(ctx, bb, profile_for_id("teutons"), 0)
    assert [(c.op, c.unit_id, c.building_id) for c in ctx.commands] == [("build", 10, 1), ("build", 11, 2)]


def test_catalog_director_places_barracks_before_idle_gather_commands():
    payload = json.loads((Path(__file__).parent / "fixtures/opening_eco.json").read_text(encoding="utf8"))["request"]
    obs = payload["observation"]
    obs["progression"] = {"age": 0}
    obs["economy"].update(wood=175, pop_cap=20)
    response = AiDirector("teutons").evaluate(1, "build_before_gather", 1, 0, 1, obs)
    foundation = next(c for c in response.commands if c.op == "place_building")
    assert foundation.building_def_id == "barracks"
    assert not any(c.op == "gather" and c.unit_id == foundation.builder_id for c in response.commands)


def test_bootstrap_rebalances_existing_food_surplus_to_wood_even_with_a_wood_worker():
    resources = [dict(id=90 + i, kind="resource", resource_type=name, amount=1000, pos=[50, 50])
                 for i, name in enumerate(("FOOD", "WOOD", "GOLD", "STONE"))]
    assignments = [0, 0, 0, 0, 0, 1, 2, 3]
    workers = [dict(id=10 + i, order="GATHER", gather_state="to_resource", carry_amount=0,
                    pos=[40, 40], _last_resource=resources[resource], last_resource_id=90 + resource)
               for i, resource in enumerate(assignments)]
    bb = board(team_villagers=workers, resource_nodes=resources, map_bounds=(-100, -100, 100, 100),
               own_tc_pos=(40, 40))
    ctx = CommandContext(1)
    EconomyManager().assign_gatherers(ctx, bb, profile_for_id("teutons"), 0)
    assert [(c.op, c.unit_id, c.target_id) for c in ctx.commands] == [("gather", 10, 91)]


def test_bootstrap_can_release_the_last_stone_worker_to_fund_first_military_buildings():
    resources = [dict(id=90 + i, kind="resource", resource_type=name, amount=1000, pos=[50, 50])
                 for i, name in enumerate(("FOOD", "WOOD", "GOLD", "STONE"))]
    assignments = [0, 0, 0, 0, 1, 1, 2, 3]
    workers = [dict(id=10 + i, order="GATHER", gather_state="to_resource", carry_amount=0,
                    pos=[40, 40], _last_resource=resources[resource], last_resource_id=90 + resource)
               for i, resource in enumerate(assignments)]
    bb = board(team_villagers=workers, resource_nodes=resources, map_bounds=(-100, -100, 100, 100),
               own_tc_pos=(40, 40))
    ctx = CommandContext(1)
    EconomyManager().assign_gatherers(ctx, bb, profile_for_id("teutons"), 0)
    assert [(c.op, c.unit_id, c.target_id) for c in ctx.commands] == [("gather", 17, 91)]
