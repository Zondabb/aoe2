"""Raids on outlying workers: shelter, fight back, call the guard, avoid the spot."""
from __future__ import annotations

import math

from brain.multi_agent.runtime import MultiAgentRuntime
from test_llm_commander import building, unit
from test_multi_agent_runtime import accept, frame, issued


def villager(eid, pos, **extra):
    return unit(eid, pos=pos, hp=25, max_hp=25, **extra)


def wood(eid, pos, amount=500):
    return {"id": eid, "kind": "resource", "resource_type": "WOOD", "pos": pos, "amount": amount}


CAMP = building(5, "lumber_camp", [56, 4])


def step(runtime, seq, entities, time, events=()):
    return runtime.tick(frame(seq, entities=entities, time=time, events=events))


def orders(result, uid):
    return [c for c in result["commands"] if c.get("unit_id") == uid]


def work(result, uid):
    return [c for c in result["commands"] if c.get("unit_id", c.get("builder_id")) == uid
            and c["op"] in ("gather", "build", "place_building", "place_wall")]


def test_lone_lumberjack_shelters_at_the_tc_and_resumes_after_the_raider_leaves():
    runtime = MultiAgentRuntime("chinese")
    tc, forest = [building(1, "town_center"), CAMP], wood(101, [62, 0])
    worker = villager(10, [60, 0], order="GATHER", target_id=101, gather_resource_type="WOOD")
    raider = unit(200, "militia", [66, 0], team=1, order="ATTACK", target_id=10)
    first = step(runtime, 1, [*tc, worker, forest, raider], 100)
    moves = [c for c in orders(first, 10) if c["op"] == "move"]
    assert moves and math.dist(moves[0]["pos"], [0, 0]) <= 6
    assert runtime._sheltered()[10]["mode"] == "flee"
    assert runtime.roles["commander"].memory["raid_ids"] == [200]
    # Still chased on the way home: no gather order sends it back.
    running = {**worker, "pos": [45, 0], "order": "MOVE", "move_goal": moves[0]["pos"]}
    second = step(runtime, 2, [*tc, running, forest, {**raider, "pos": [52, 0]}], 101, accept(first))
    assert not orders(second, 10)
    # Raider gone: hold briefly, then the economy puts the worker back to work.
    home = {**running, "pos": [4, 0], "order": "NONE"}
    third = step(runtime, 3, [*tc, home, forest], 106, accept(second, 10))
    assert not work(third, 10) and 10 in runtime._sheltered()
    fourth = step(runtime, 4, [*tc, home, forest], 110, accept(third, 20))
    assert 10 not in runtime._sheltered()
    assert work(fourth, 10)                       # gather or build again


def test_enough_villagers_fight_back_a_lone_scout_but_not_the_whole_camp():
    runtime = MultiAgentRuntime("chinese")
    workers = [villager(10 + i, [60 + i % 3, i // 3], order="GATHER", target_id=101, gather_resource_type="WOOD") for i in range(6)]
    scout = unit(200, "scout_cavalry", [64, 0], team=1, hp=45, max_hp=45)
    result = step(runtime, 1, [building(1, "town_center"), *workers, wood(101, [62, 0]), scout], 100)
    attackers = [c["unit_id"] for c in issued(result, "attack") if c["target_id"] == 200]
    assert 2 <= len(attackers) < 6
    assert not [c for c in issued(result, "move") if c["unit_id"] in attackers]
    assert all(runtime._sheltered()[uid]["mode"] == "fight" for uid in attackers)


def test_villagers_shelter_from_a_raid_they_cannot_beat():
    runtime = MultiAgentRuntime("chinese")
    workers = [villager(10 + i, [60, i], order="GATHER", target_id=101, gather_resource_type="WOOD") for i in range(3)]
    raiders = [unit(200 + i, "man_at_arms", [65, i], team=1, hp=45, max_hp=45, order="ATTACK", target_id=10 + i) for i in range(3)]
    result = step(runtime, 1, [building(1, "town_center"), *workers, wood(101, [62, 0]), *raiders], 100)
    assert not [c for c in issued(result, "attack") if c["unit_id"] in (10, 11, 12)]
    moved = {c["unit_id"] for c in issued(result, "move")}
    assert {10, 11, 12} <= moved


def test_economy_raid_calls_the_nearest_guard_without_pausing_scouting():
    runtime = MultiAgentRuntime("chinese")
    guard = [unit(30 + i, "militia", [20, i]) for i in range(3)]
    entities = [building(1, "town_center"), CAMP, villager(10, [60, 0], order="GATHER", target_id=101),
                wood(101, [62, 0]), unit(200, "militia", [64, 0], team=1), unit(20, "scout_cavalry", [-20, 0]), *guard]
    result = step(runtime, 1, entities, 100)
    assert runtime.roles["commander"].memory["threat_ids"] == []
    assert result["agent_status"]["commander"]["reason"] == "visible_economy_raid"
    assert result["agent_status"]["scout"]["reason"] != "base_defense_preemption"
    assert {c["unit_id"] for c in issued(result, "attack") if c["target_id"] == 200} & {30, 31, 32}


def test_a_distant_sortie_is_not_recalled_for_a_small_raid():
    runtime = MultiAgentRuntime("chinese")
    sortie = [unit(30 + i, "militia", [150, 150 + i]) for i in range(4)]
    runtime.goals.update(sortie_started=50.0, sortie_departed=60.0, phase="march")
    runtime.roles["combat"].memory["sortie_ids"] = [u["id"] for u in sortie]
    entities = [building(1, "town_center"), CAMP, villager(10, [60, 0], order="GATHER", target_id=101),
                wood(101, [62, 0]), unit(200, "militia", [64, 0], team=1), *sortie]
    result = step(runtime, 1, entities, 100)
    assert not [c for c in issued(result, "attack") if c["target_id"] == 200 and c["unit_id"] >= 30]
    assert runtime.roles["combat"].memory["defender_ids"] == []


def test_a_hopeless_open_field_defense_holds_under_the_tc():
    runtime = MultiAgentRuntime("chinese")
    guard = [unit(30 + i, "militia", [10, i]) for i in range(2)]
    raiders = [unit(200 + i, "man_at_arms", [66, i], team=1, hp=45, max_hp=45) for i in range(6)]
    entities = [building(1, "town_center"), CAMP, villager(10, [60, 0], order="GATHER", target_id=101),
                wood(101, [62, 0]), *raiders, *guard]
    result = step(runtime, 1, entities, 100)
    assert not [c for c in issued(result, "attack") if c["unit_id"] in (30, 31)]
    assert runtime.roles["combat"].memory["defender_ids"] == []


def test_idle_workers_avoid_a_raided_forest():
    runtime = MultiAgentRuntime("chinese")
    entities = [building(1, "town_center"), villager(15, [0, 5]), villager(16, [33, 0]), wood(101, [30, 0]), wood(102, [-30, 0]),
                unit(200, "militia", [36, 0], team=1, order="ATTACK", target_id=16)]
    result = step(runtime, 1, entities, 100)
    gathers = [c for c in issued(result, "gather") if c["unit_id"] == 15]
    assert gathers and gathers[0]["target_id"] == 102


def test_a_passing_scout_does_not_stop_work():
    runtime = MultiAgentRuntime("chinese")
    workers = [villager(10 + i, [60, i], order="GATHER", target_id=101, gather_resource_type="WOOD") for i in range(2)]
    scout = unit(200, "scout_cavalry", [68, 0], team=1, hp=45, max_hp=45, order="MOVE")
    result = step(runtime, 1, [building(1, "town_center"), CAMP, *workers, wood(101, [62, 0]), scout], 100)
    assert not [c for c in result["commands"] if c.get("unit_id") in (10, 11) and c["op"] in ("move", "attack", "stop")]
    assert runtime._sheltered() == {}
    assert runtime.roles["commander"].memory["raid_ids"] == [200]        # the guard still answers it


def test_a_worker_far_from_our_buildings_does_not_call_the_guard():
    runtime = MultiAgentRuntime("chinese")
    guard = [unit(30 + i, "militia", [10, i]) for i in range(3)]
    entities = [building(1, "town_center"), villager(10, [80, 80]), unit(200, "militia", [84, 80], team=1), *guard]
    result = step(runtime, 1, entities, 100)
    assert runtime.roles["commander"].memory["raid_ids"] == []
    assert not [c for c in issued(result, "attack") if c["target_id"] == 200 and c["unit_id"] >= 30]
    assert [c for c in issued(result, "move") if c["unit_id"] == 10]      # its own reflex still runs


def test_villagers_are_never_sent_scouting_when_the_scout_is_lost():
    runtime = MultiAgentRuntime("chinese")
    entities = [building(1, "town_center"), villager(10, [0, 5]), villager(11, [0, -5]), wood(101, [10, 0])]
    req = frame(1, entities=entities, time=100,
                scouting={"scout_ids": [10], "frontiers": [{"pos": [80, 80]}], "probes": [{"pos": [-80, -80]}]})
    result = runtime.tick(req)
    assert not [c for c in issued(result, "move") if c["unit_id"] == 10 and c["pos"] in ([80, 80], [-80, -80])]
    assert 10 not in runtime.scout_missions
