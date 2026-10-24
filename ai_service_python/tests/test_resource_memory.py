"""Object permanence for resources and the opening wood economy."""
from __future__ import annotations

import copy

from brain.land_progression import CATALOG
from brain.multi_agent.runtime import MultiAgentRuntime
from test_llm_commander import building, unit
from test_multi_agent_runtime import accept, frame, issued

FULL_CATALOG = {kind: [{"id": name, **copy.deepcopy(record), "available": True, "blocked_reason": ""}
                       for name, record in CATALOG[kind].items()] for kind in ("units", "buildings", "technologies")}


def sight(*sources):
    return {"origin": [-100, -100], "cell_size": 2, "grid_size": [100, 100], "sources": [list(s) for s in sources]}


def resource(eid, kind, pos, amount=500):
    return {"id": eid, "kind": "resource", "resource_type": kind, "pos": pos, "amount": amount}


def tick(runtime, seq, entities, visibility, **context):
    req = frame(seq, entities=entities, time=seq * 5, **context)
    req.observation.placement_visibility = visibility
    return runtime.tick(req)


def farm_requests(runtime):
    # The technology role may also ask for a mill as an age prerequisite.
    return [r for r in runtime.build_requests if r[2] in ("farm_prerequisite", "staffed_food_supply")]


def test_berries_out_of_sight_are_remembered_until_seen_gone():
    base = [building(1, "town_center"), unit(10), unit(11), unit(12)]
    berries = resource(100, "FOOD", [30, 30])
    runtime = MultiAgentRuntime("chinese")
    tick(runtime, 1, base + [berries], sight((0, 0, 60)))
    tick(runtime, 2, base, sight((0, 0, 10)))                  # workers walked home: berries unseen
    assert runtime._food_bridge(runtime.frame) and not farm_requests(runtime)
    fresh = MultiAgentRuntime("chinese")
    tick(fresh, 2, base, sight((0, 0, 10)))                    # never saw them: transition to farms
    assert farm_requests(fresh)
    tick(runtime, 3, base, sight((0, 0, 60)))                  # site visible again, berries gone
    assert 100 not in runtime.resource_memory and farm_requests(runtime)


def test_depletion_event_forgets_a_remembered_site():
    runtime = MultiAgentRuntime("chinese")
    tick(runtime, 1, [building(1, "town_center"), resource(100, "FOOD", [30, 30])], sight((0, 0, 60)))
    req = frame(2, entities=[building(1, "town_center")], time=10,
                events=[{"seq": 9, "type": "resource_depleted", "entity_id": 100}])
    req.observation.placement_visibility = sight((0, 0, 10))
    runtime.tick(req)
    assert 100 not in runtime.resource_memory


def test_memory_is_disabled_without_fog_geometry():
    runtime = MultiAgentRuntime("chinese")
    tick(runtime, 1, [building(1, "town_center"), resource(100, "FOOD", [30, 30])], None)
    assert runtime.resource_memory == {}


def test_far_forest_funds_a_lumber_camp_before_the_opening_barracks():
    lumberjack = unit(10, order="GATHER", target_id=101, gather_resource_type="WOOD", pos=[58, 0])
    entities = [building(1, "town_center"), lumberjack, unit(11), unit(12), resource(101, "WOOD", [60, 0])]
    runtime = MultiAgentRuntime("chinese")
    tick(runtime, 1, entities, sight((0, 0, 70)), catalog=FULL_CATALOG)
    camp = [r for r in runtime.build_requests if r[1] == "lumber_camp"]
    barracks = [r for r in runtime.build_requests if r[1] == "barracks"]
    assert camp and camp[0][0] > barracks[0][0] and camp[0][2] == "long_wood_delivery"
    near = MultiAgentRuntime("chinese")
    close = [building(1, "town_center"), unit(10, order="GATHER", target_id=101, gather_resource_type="WOOD"), resource(101, "WOOD", [20, 0])]
    tick(near, 1, close, sight((0, 0, 70)), catalog=FULL_CATALOG)
    assert all(r[0] < 100 for r in near.build_requests if r[1] == "lumber_camp")


def test_camp_sites_at_a_far_or_enemy_side_forest_are_rejected():
    runtime = MultiAgentRuntime("chinese")
    entities = [building(1, "town_center"), unit(10), resource(101, "WOOD", [40, 0]), resource(102, "WOOD", [-90, -90]),
                building(200, "town_center", [-80, -70], team=1)]
    tick(runtime, 1, entities, sight((0, 0, 100)), catalog=FULL_CATALOG)
    options = [{"building_def_id": "lumber_camp", "pos": [44, 6], "builder_id": 10, "resource_target_id": 101},
               {"building_def_id": "lumber_camp", "pos": [-86, -84], "builder_id": 10, "resource_target_id": 102},
               {"building_def_id": "lumber_camp", "pos": [80, 0], "builder_id": 10}]
    kept = runtime._sane_drop_off_sites(runtime.frame, "lumber_camp", options)
    assert [o["pos"] for o in kept] == [[44, 6]]


def test_idle_worker_walks_back_to_the_remembered_home_forest():
    runtime = MultiAgentRuntime("chinese")
    home_wood, far_wood = resource(101, "WOOD", [30, 0]), resource(102, "WOOD", [-90, 0])
    worker = unit(15, pos=[0, 5])          # not a builder offered by the fixture's construction sites
    first = tick(runtime, 1, [building(1, "town_center"), worker, home_wood], sight((0, 0, 40)))
    # Frame 1's orders were received; the worker is idle again and the home
    # forest is out of sight while another forest is visible across the map.
    out = tick(runtime, 2, [building(1, "town_center"), worker, far_wood], sight((0, 0, 10), (-90, 0, 10)),
               events=accept(first))
    assert not [c for c in issued(out, "gather") if c["unit_id"] == 15]
    moves = [c for c in issued(out, "move") if c["unit_id"] == 15]
    assert moves and moves[0]["pos"] == [30, 0]


def test_default_economy_keeps_producing_villagers_past_the_profile_floor():
    runtime = MultiAgentRuntime("chinese")
    minimum, target = runtime._worker_targets(0)
    assert minimum == 8 and target == 16
    villagers = [unit(10 + i) for i in range(10)]
    out = tick(runtime, 1, [building(1, "town_center")] + villagers, sight((0, 0, 60)))
    assert [c for c in issued(out, "train") if c["unit_def_id"] == "villager"]


def test_unneeded_gold_stock_releases_miners():
    runtime = MultiAgentRuntime("chinese")
    miners = [unit(10 + i, order="GATHER", target_id=102, gather_resource_type="GOLD") for i in range(3)]
    entities = [building(1, "town_center"), *miners, resource(101, "WOOD", [10, 0]), resource(102, "GOLD", [-10, 0])]
    req = frame(1, entities=entities, time=5)
    req.observation.economy.gold = 300
    req.observation.economy.wood = 0
    out = runtime.tick(req)
    moved = [c for c in issued(out, "gather") if c["target_id"] == 101]
    assert moved                                         # surplus gold: shift a miner to wood
