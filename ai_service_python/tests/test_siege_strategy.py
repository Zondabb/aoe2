"""Siege, escort and home-defense behavior using authoritative observations."""
from __future__ import annotations

import copy

import pytest

from brain.land_progression import CATALOG
from brain.multi_agent.runtime import MultiAgentRuntime
from test_llm_commander import building, unit
from test_multi_agent_runtime import accept, army, enemy_tc, frame, issued, plan


def battle(entities, age=2, tick=1, time=1, events=(), **context):
    catalog = {kind: [{"id": name, **copy.deepcopy(record)} for name, record in CATALOG[kind].items()]
               for kind in ("units", "buildings", "technologies")}
    req = frame(tick, entities=entities, time=time, events=events, catalog=catalog, construction_options=[], **context)
    req.observation.progression.age = age
    return req


def attack_map(out):
    return {c["unit_id"]: c["target_id"] for c in issued(out, "attack")}


def departing():
    runtime = MultiAgentRuntime("chinese")
    plan(runtime, "combat", army_target=2)
    return runtime


@pytest.mark.parametrize("name", ["battering_ram", "mangonel", "bombard_cannon", "trebuchet"])
def test_demolition_targets_tc_while_soldiers_screen_defenders(name):
    out = departing().tick(battle([unit(40, name, [35, 35]), *army(4, [35, 35]), enemy_tc(),
                                   unit(210, "militia", [36, 35], team=1), unit(211, "villager", [37, 35], team=1)]))
    attacks = attack_map(out)
    assert attacks[40] == 200
    assert all(attacks[uid] == 210 for uid in range(30, 34))


def test_regular_soldiers_raid_nearby_villagers_before_tc_and_preserve_target():
    soldiers = army(4, [35, 35])
    soldiers[0].update(order="ATTACK", target_id=211)
    out = departing().tick(battle(soldiers + [enemy_tc(), unit(210, pos=[36, 35], team=1), unit(211, pos=[37, 35], team=1)]))
    attacks = attack_map(out)
    assert 30 not in attacks
    assert {attacks[uid] for uid in (31, 32, 33)} == {210}


def test_ram_breaches_visible_wall_then_switches_to_tc_when_destroyed():
    runtime = departing()
    actors = army(4, [30, 40]) + [unit(40, "battering_ram", [30, 40]), enemy_tc([50, 40])]
    wall = building(201, "stone_wall", [40, 40], team=1, footprint=[1, 1], blocks_movement=True)
    first = runtime.tick(battle(actors + [wall]))
    assert attack_map(first)[40] == 201
    actors[4].update(order="ATTACK", target_id=201)
    second = runtime.tick(battle(actors, tick=2, time=3, events=accept(first) + [{"seq": 100, "type": "entity_destroyed", "entity_id": 201}]))
    assert any(c["unit_id"] == 40 for c in issued(second, "move"))
    actors[4]["pos"] = [44, 40]
    third = runtime.tick(battle(actors, tick=3, time=5, events=accept(second, 200)))
    assert attack_map(third)[40] == 200


def test_ranged_siege_fires_over_wall_when_tc_in_range():
    siege = unit(40, "trebuchet", [35, 40], combat={"range": 16})
    wall = building(201, "stone_wall", [40, 40], team=1, footprint=[1, 1])
    out = departing().tick(battle(army(4, [35, 40]) + [siege, wall, enemy_tc([50, 40])]))
    assert attack_map(out)[40] == 200


def test_open_gate_and_wall_away_from_route_do_not_distract_ram():
    wall = building(201, "stone_wall", [40, 46], team=1, footprint=[1, 1])
    gate = building(202, "gate", [40, 40], team=1, footprint=[1, 4], gate_open=True, blocks_movement=False)
    out = departing().tick(battle(army(4, [30, 40]) + [unit(40, "battering_ram", [30, 40]), wall, gate, enemy_tc([50, 40])]))
    assert attack_map(out)[40] == 200


def test_melee_raiders_breach_wall_before_chasing_visible_farmer_behind_it():
    wall = building(201, "palisade_wall", [40, 40], team=1, footprint=[1, 1])
    out = departing().tick(battle(army(4, [35, 40]) + [wall, enemy_tc([55, 40]), unit(210, pos=[45, 40], team=1)]))
    assert set(attack_map(out).values()) == {201}


def test_single_base_raider_recruits_nearest_soldiers_without_recalling_siege():
    actors = [*army(4, [35, 35]), unit(40, "battering_ram", [38, 38]), unit(50, "militia", [0, 0]), unit(51, "militia", [1, 1]),
              building(1, "town_center"), enemy_tc(), unit(210, "militia", [3, 3], team=1, order="ATTACK", target_id=1)]
    runtime = departing()
    runtime.goals["sortie_departed"] = 0
    out = runtime.tick(battle(actors))
    attacks = attack_map(out)
    assert attacks[50] == attacks[51] == 210
    assert attacks[40] == 200
    assert all(attacks[uid] == 200 for uid in range(30, 34))


def test_home_defenders_prioritize_attackers_of_own_tc():
    entities = army(4) + [building(1, "town_center"), unit(210, "militia", [1, 1], team=1),
                          unit(211, "militia", [8, 8], team=1, order="ATTACK", target_id=1)]
    runtime = departing()
    out = runtime.tick(battle(entities))
    assert all(attack_map(out)[uid] == 211 for uid in runtime.roles["combat"].memory["defender_ids"])


def test_castle_age_discovery_requests_workshop_without_waiting_for_failed_assault():
    runtime = departing()
    runtime.tick(battle([*army(4), enemy_tc()]))
    assert runtime.goals["needs_siege"]
    assert any(name == "siege_workshop" for _, name, _ in runtime.build_requests)
    assert any(name == "blacksmith" for _, name, _ in runtime.build_requests)


def test_workshop_trains_economical_ram_before_high_attack_mangonel():
    workshop = building(2, "siege_workshop", trainable=["mangonel", "battering_ram"])
    out = departing().tick(battle([*army(4), workshop, enemy_tc()]))
    assert any(c["unit_def_id"] == "battering_ram" for c in issued(out, "train"))


def test_siege_target_counts_all_workshop_queues_and_caps_same_frame_purchases():
    workshops = [building(i, "siege_workshop", trainable=["battering_ram"]) for i in (2, 3, 4)]
    workshops[0].update(train_queue=["battering_ram"], train_queue_empty=False)
    req = battle([*army(4), *workshops, enemy_tc()])
    req.observation.economy.wood = req.observation.economy.gold = 2000
    out = departing().tick(req)
    assert len([c for c in issued(out, "train") if c["unit_def_id"] == "battering_ram"]) == 1


def test_siege_target_replaces_lost_weapons_without_unbounded_mass_production():
    runtime = departing()
    workshop = building(2, "siege_workshop", trainable=["battering_ram", "mangonel"])
    req = battle([*army(4), workshop, unit(40, "battering_ram"), unit(41, "mangonel"), enemy_tc()])
    first = runtime.tick(req)
    assert not issued(first, "train")
    req = battle([*army(4), workshop, unit(41, "mangonel"), enemy_tc()], tick=2, time=3, events=accept(first))
    assert len(issued(runtime.tick(req), "train")) == 1


def test_first_siege_does_not_lose_gold_to_imperial_age_savings_or_escort_training():
    workshop = building(2, "siege_workshop", trainable=["battering_ram"])
    tc = building(1, "town_center", age_upgrade_reason="not_enough_resources")
    entities = [*army(4), *[unit(10 + i) for i in range(8)], tc, workshop, building(3, "barracks"),
                building(4, "monastery"), building(5, "university"), enemy_tc()]
    runtime = departing()
    req = battle(entities)
    req.observation.economy.wood = 160
    req.observation.economy.gold = 75
    out = runtime.tick(req)
    assert any(c["unit_def_id"] == "battering_ram" for c in issued(out, "train"))
    assert not runtime.tech_reserve


def test_unaffordable_first_ram_saves_gold_but_keeps_civilian_food_production():
    entities = [*army(4), building(1, "town_center"), building(2, "barracks"),
                building(3, "siege_workshop", trainable=["battering_ram"], train_blocked_reasons={"battering_ram": "资源不足"}), enemy_tc()]
    req = battle(entities)
    req.observation.economy.gold = 50
    req.observation.economy.wood = 130
    out = departing().tick(req)
    trained = [c["unit_def_id"] for c in issued(out, "train")]
    assert trained == ["villager"]


def test_hidden_enemy_buildings_cannot_be_attacked_by_siege():
    runtime = departing()
    actors = [*army(4, [35, 35]), unit(40, "battering_ram", [35, 35])]
    first = runtime.tick(battle(actors + [enemy_tc()]))
    out = runtime.tick(battle(actors, tick=2, time=3, events=accept(first)))
    assert not issued(out, "attack")
    assert any(c["unit_id"] == 40 and c["pos"] == [40, 40] for c in issued(out, "move"))


def test_human_control_of_siege_is_preserved_during_enemy_base_attack():
    req = battle([*army(4), unit(40, "battering_ram"), enemy_tc()],
                 events=[{"seq": 1, "type": "human_command", "unit_id": 40}])
    assert 40 not in attack_map(departing().tick(req))


def test_ram_complement_is_preferred_over_friendly_fire_artillery():
    workshop = building(2, "siege_workshop", trainable=["mangonel", "battering_ram"])
    out = departing().tick(battle([*army(8), unit(40, "battering_ram"), workshop, enemy_tc()]))
    assert [c["unit_def_id"] for c in issued(out, "train")] == ["battering_ram"]


def test_artillery_stops_then_resumes_when_friendly_leaves_blast_zone():
    runtime = departing()
    artillery = unit(40, "mangonel", [25, 40], order="ATTACK", target_id=200,
                     combat={"range": 28, "projectile_splash_radius": 4, "projectile_friendly_fire": True})
    actors = [artillery, *army(4, [39, 40]), enemy_tc()]
    first = runtime.tick(battle(actors))
    assert 40 not in attack_map(first)
    assert any(c["unit_id"] == 40 for c in issued(first, "stop"))
    artillery["order"] = "NONE"
    for soldier in actors[1:5]: soldier["pos"] = [30, 32]
    second = runtime.tick(battle(actors, tick=2, time=3, events=accept(first)))
    assert attack_map(second)[40] == 200


def test_separated_squads_concentrate_on_same_breach_and_widen_gap():
    runtime = departing()
    actors = [unit(40, "battering_ram", [30, 40]), *army(4, [30, 45]), enemy_tc([60, 40])]
    walls = [building(300 + i, "stone_wall", [40, 40 + i], team=1, footprint=[1, 1]) for i in range(-4, 5)]
    first = runtime.tick(battle(actors + walls))
    assert set(attack_map(first).values()) == {300}
    second = runtime.tick(battle(actors + [w for w in walls if w["id"] != 300], tick=2, time=3,
                                events=accept(first) + [{"seq": 100, "type": "entity_destroyed", "entity_id": 300}]))
    assert runtime.roles["combat"].memory["breach"]["opened"] is False
    assert len(set(attack_map(second).values())) == 1
    assert attack_map(second)[40] in (299, 301)


def test_open_breach_waypoint_has_no_arrival_dead_zone():
    runtime = departing()
    runtime.roles["combat"].memory["breach"] = {"id": 201, "pos": [40, 40], "objective_id": 200, "opened": True}
    tc = enemy_tc([60, 40])
    # Previously at x=34.5 the entry was x=37: _move returned early (2.5 < 3)
    # but the phase could never advance, leaving every reinforcement idle.
    assert runtime._breach_waypoint(unit(40, "battering_ram", [34.5, 40]), tc) == [46, 40]
    assert runtime._breach_waypoint(unit(40, "battering_ram", [30, 44]), tc) == [36, 40]
    assert runtime._breach_waypoint(unit(40, "battering_ram", [44, 40]), tc) is None


def test_shared_gate_target_is_released_on_opening_and_restored_on_closing():
    runtime = departing()
    actors = [unit(40, "battering_ram", [30, 40]), *army(4, [30, 40]), enemy_tc([60, 40])]
    gate = building(202, "gate", [40, 40], team=1, footprint=[1, 4], gate_open=False, blocks_movement=True)
    first = runtime.tick(battle(actors + [gate]))
    assert set(attack_map(first).values()) == {202}
    for actor in actors[:-1]:
        actor.update(order="ATTACK", target_id=202)
    gate.update(gate_open=True, blocks_movement=False)
    opened = runtime.tick(battle(actors + [gate], tick=2, time=3, events=accept(first)))
    assert runtime.roles["combat"].memory["breach"]["opened"]
    assert 202 not in attack_map(opened).values()
    assert any(c["unit_id"] == 40 for c in issued(opened, "move"))
    for actor in actors[:-1]:
        actor.update(order="MOVE", move_goal=[36, 40])
    gate.update(gate_open=False, blocks_movement=True)
    closed = runtime.tick(battle(actors + [gate], tick=3, time=5, events=accept(opened, 100)))
    assert not runtime.roles["combat"].memory["breach"]["opened"]
    assert attack_map(closed)[40] == 202


def test_real_unaffordable_catalog_keeps_siege_infrastructure_savings():
    actors = [*army(4), *[unit(10 + i) for i in range(8)], building(1, "town_center"),
              building(2, "barracks"), enemy_tc(),
              {"id": 100, "kind": "resource", "resource_type": "FOOD", "pos": [4, 4], "amount": 1000}]
    req = battle(actors)
    req.observation.economy.wood = 60
    req.observation.decision_context["construction_options"] = [{"building_def_id": "blacksmith", "builder_id": 10, "pos": [24, 0]}]
    smith = next(b for b in req.observation.decision_context["catalog"]["buildings"] if b["id"] == "blacksmith")
    smith.update(available=False, blocked_reason="资源不足")
    runtime = departing()
    out = runtime.tick(req)
    assert not issued(out, "place_building")
    assert runtime.roles["construction"].memory["purchase_reservation"]["name"] == "blacksmith"
    assert runtime.construction_reserve["wood"] == 60
