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


def test_worker_walking_to_berries_or_wood_does_not_ping_pong_on_stock_swings_or_brief_bumps():
    runtime = MultiAgentRuntime("chinese")
    berries_a = resource(100, "FOOD", [24, 24])
    berries_b = resource(103, "FOOD", [26, 24])
    wood = resource(101, "WOOD", [24, -24])
    # Three berry pickers, three woodcutters, plus worker 16 walking empty-handed to berries.
    berry_crew = [unit(10 + i, pos=[23, 24], order="GATHER", target_id=100, gather_state="gathering",
                       carry_amount=4, gather_resource_type="FOOD") for i in range(3)]
    wood_crew = [unit(13 + i, pos=[23, -24], order="GATHER", target_id=101, gather_state="gathering",
                      carry_amount=4, gather_resource_type="WOOD") for i in range(3)]
    walker = unit(16, pos=[15, 15], order="GATHER", target_id=100, gather_state="to_resource",
                  carry_amount=0, gather_resource_type="FOOD", stuck_frames=20)
    base = [building(1, "town_center"), building(2, "barracks"), *berry_crew, *wood_crew, walker, berries_a, berries_b, wood]

    for seq, (food_stock, wood_stock) in enumerate(((40, 70), (90, 20), (610, 590), (590, 620)), start=1):
        req = frame(seq, entities=copy.deepcopy(base), time=seq * 4, construction_options=[])
        req.observation.economy.food, req.observation.economy.wood = food_stock, wood_stock
        out = runtime.tick(req)
        assert not [c for c in out["commands"] if c.get("unit_id") == 16]

    # Even a sustained 3s+ block on bush 100 switches to adjacent bush 103, not across the map to wood.
    blocked = copy.deepcopy(base)
    next(e for e in blocked if e["id"] == 16)["stuck_frames"] = 200
    req = frame(10, entities=blocked, time=50, construction_options=[])
    req.observation.economy.food, req.observation.economy.wood = 90, 20
    out = runtime.tick(req)
    reassigned = [c for c in issued(out, "gather") if c["unit_id"] == 16]
    assert reassigned and reassigned[0]["target_id"] == 103


def test_recalled_forest_walk_counts_toward_staffing_and_switches_to_gather_on_sight():
    runtime = MultiAgentRuntime("chinese")
    berries = resource(100, "FOOD", [12, 12])
    home_wood = resource(101, "WOOD", [36, 0])
    foragers = [unit(10 + i, pos=[2, 2], order="GATHER", target_id=100, gather_state="to_resource",
                     carry_amount=0, gather_resource_type="FOOD") for i in range(4)]
    walker = unit(15, pos=[0, 5])
    t1 = tick(runtime, 1, [building(1, "town_center"), building(2, "barracks"), *foragers, walker, berries, home_wood],
              sight((0, 0, 50)), construction_options=[])
    # Tick 2: home_wood is now in fog; walker 15 is idle and sent via MOVE toward [36, 0].
    req2 = frame(2, entities=[building(1, "town_center"), building(2, "barracks"), *foragers, walker, berries],
                 time=10, events=accept(t1), construction_options=[])
    req2.observation.placement_visibility = sight((0, 0, 20))
    req2.observation.economy.wood, req2.observation.economy.food = 20, 200
    t2 = runtime.tick(req2)
    assert [c["pos"] for c in issued(t2, "move") if c["unit_id"] == 15] == [[36, 0]]

    # Tick 3: walker 15 is halfway there (MOVE); it counts as staffing wood and is not pulled back.
    walking = unit(15, pos=[18, 0], order="MOVE", move_goal=[36, 0])
    req3 = frame(3, entities=[building(1, "town_center"), building(2, "barracks"), *foragers, walking, berries],
                 time=15, events=accept(t2, seq=20), construction_options=[])
    req3.observation.placement_visibility = sight((0, 0, 20), (18, 0, 10))
    req3.observation.economy.wood, req3.observation.economy.food = 200, 20
    t3 = runtime.tick(req3)
    assert not [c for c in t3["commands"] if c.get("unit_id") == 15]

    # Tick 4: home_wood enters walker 15's vision before collision; immediately switch MOVE -> GATHER on wood,
    # even though food is momentarily low!
    nearing = unit(15, pos=[28, 0], order="MOVE", move_goal=[36, 0])
    req4 = frame(4, entities=[building(1, "town_center"), building(2, "barracks"), *foragers, nearing, berries, home_wood],
                 time=20, construction_options=[])
    req4.observation.placement_visibility = sight((0, 0, 20), (28, 0, 10))
    req4.observation.economy.wood, req4.observation.economy.food = 200, 20
    t4 = runtime.tick(req4)
    gathers = [c for c in issued(t4, "gather") if c["unit_id"] == 15]
    assert gathers and gathers[0]["target_id"] == 101


def test_remembered_remote_berries_do_not_cause_fog_boundary_ping_pong():
    runtime = MultiAgentRuntime("chinese")
    remote_berries = resource(100, "FOOD", [110, 0])
    home_wood = resource(101, "WOOD", [12, 0])
    base_entities = [building(1, "town_center"), building(2, "barracks"), building(3, "mill"),
                     building(300, "farm", [8, 8], amount=300, resource_type="FOOD"),
                     unit(10, order="GATHER", target_id=300, last_resource_id=300, gather_state="gathering",
                          carry_amount=5, gather_resource_type="FOOD"),
                     unit(11), home_wood]
    t1 = tick(runtime, 1, base_entities + [remote_berries], sight((0, 0, 130)), construction_options=[])
    # Remote berries leave sight while the only local farm is occupied: unit 11 gathers wood instead of walking 110 units.
    req2 = frame(2, entities=base_entities, time=10, events=accept(t1), construction_options=[])
    req2.observation.placement_visibility = sight((0, 0, 30))
    req2.observation.economy.food = 20
    out = runtime.tick(req2)
    assert [c["target_id"] for c in issued(out, "gather") if c["unit_id"] == 11] == [101]
    assert not [c for c in issued(out, "move") if c.get("unit_id") == 11]


def test_visible_wall_options_do_not_pull_gatherers_into_perimeter_reveal():
    from brain.cabinet.runtime import CabinetRuntime
    from test_wall_defense import defense_frame

    req = defense_frame(threat=False)
    req.observation.economy.wood = 70  # below reserve_wood=100, so wall waits on wood while options remain visible
    req.observation.decision_context["defense_scout_options"] = [{"unit_id": 10, "pos": [10, 0], "side": 0}]
    for runtime in (MultiAgentRuntime("chinese"), CabinetRuntime("chinese")):
        out = runtime.tick(copy.deepcopy(req))
        assert not [c for c in issued(out, "move") if c.get("unit_id") == 10]


def test_economy_manager_rebalance_hysteresis_does_not_oscillate_between_food_and_wood():
    from brain.command_builder import CommandContext
    from brain.economy_manager import EconomyManager
    from brain.profile_loader import profile_for_id
    from brain.stores import Blackboard, PHASE_BOOM

    food_node = {"id": 20, "kind": "resource", "resource_type": "FOOD", "pos": [10.0, 0.0], "amount": 500.0}
    wood_node = {"id": 21, "kind": "resource", "resource_type": "WOOD", "pos": [-10.0, 0.0], "amount": 500.0}
    gold_node = {"id": 22, "kind": "resource", "resource_type": "GOLD", "pos": [0.0, 10.0], "amount": 500.0}
    villagers = (
        [{"id": 100 + i, "def_id": "villager", "pos": [0.0, 0.0], "order": "GATHER", "gather_state": "to_resource",
          "carry_amount": 0.0, "_last_resource": food_node, "last_resource_id": 20} for i in range(5)]
        + [{"id": 110 + i, "def_id": "villager", "pos": [0.0, 0.0], "order": "GATHER", "gather_state": "to_resource",
            "carry_amount": 0.0, "_last_resource": wood_node, "last_resource_id": 21} for i in range(5)]
        + [{"id": 120, "def_id": "villager", "pos": [0.0, 0.0], "order": "GATHER", "gather_state": "to_resource",
            "carry_amount": 0.0, "_last_resource": gold_node, "last_resource_id": 22}]
    )
    bb = Blackboard(
        progression={"age": 0},
        map_bounds=(-100.0, -100.0, 100.0, 100.0),
        team_buildings=[{"id": 1, "def_id": "town_center", "pos": [0.0, 0.0], "is_complete": True}],
        team_villagers=villagers,
        resource_nodes=[food_node, wood_node, gold_node],
    )
    ctx = CommandContext(tick=1)
    EconomyManager().assign_gatherers(ctx, bb, profile_for_id("chinese"), PHASE_BOOM)
    assert ctx.commands == []


def test_receding_forest_or_second_woodline_builds_additional_lumber_camp():
    from brain.cabinet.runtime import CabinetRuntime

    def make_req(seq, *, second_camp=False):
        lumberjacks = [
            unit(10 + i, pos=[56, 0], order="GATHER", target_id=102, last_resource_id=102, gather_resource_type="WOOD")
            for i in range(4)
        ]
        farmers = [
            unit(14 + i, pos=[-16, 24], order="GATHER", target_id=300, last_resource_id=300, gather_resource_type="FOOD")
            for i in range(2)
        ]
        buildings = [
            building(1, "town_center"),
            building(2, "barracks", [16, 16]),
            building(3, "mill", [-16, 16]),
            building(300, "farm", [-16, 24], amount=300, resource_type="FOOD"),
            building(4, "lumber_camp", [20, 0]),
        ]
        if second_camp:
            buildings.append(building(5, "lumber_camp", [50, 6]))
        entities = [
            *buildings,
            *lumberjacks,
            *farmers,
            unit(16, pos=[44, 0]),
            unit(17, pos=[0, 10]),
            resource(101, "WOOD", [26, 0], amount=100),
            resource(102, "WOOD", [58, 0], amount=800),
        ]
        options = [
            {"building_def_id": "lumber_camp", "builder_id": 17, "pos": [24, 8], "resource_target_id": 101},
            {"building_def_id": "lumber_camp", "builder_id": 16, "pos": [50, 6], "resource_target_id": 102},
            {"building_def_id": "farm", "builder_id": 17, "pos": [-24, 24]},
        ]
        req = frame(seq, entities=entities, time=seq * 10, catalog=FULL_CATALOG, construction_options=options)
        req.observation.economy.wood = 200
        req.observation.economy.food = 300
        return req

    probe = MultiAgentRuntime("chinese")
    req_probe = make_req(1)
    req_probe.observation.decision_context["construction_options"] = []
    probe.tick(req_probe)
    kept = probe._sane_drop_off_sites(probe.frame, "lumber_camp", make_req(1).observation.decision_context["construction_options"][:2])
    assert [o["pos"] for o in kept] == [[50, 6]]

    for runtime in (MultiAgentRuntime("chinese"), CabinetRuntime("chinese")):
        out = runtime.tick(make_req(1))
        placed = issued(out, "place_building")
        assert [(c["building_def_id"], c["pos"]) for c in placed] == [("lumber_camp", [50, 6])]
        if isinstance(runtime, CabinetRuntime):
            req_camp = next(r for r in out["agent_status"]["economy"]["requests"] if r["item"] == "lumber_camp")
            assert req_camp["urgency"] >= 2 and req_camp["tier"] in ("next", "now")

        after = runtime.tick(make_req(2, second_camp=True))
        assert not [c for c in issued(after, "place_building") if c["building_def_id"] == "lumber_camp"]


def test_depleted_gold_or_distant_stone_builds_additional_mining_camp():
    from brain.cabinet.models import Mandate
    from brain.cabinet.runtime import CabinetRuntime

    def make_gold_req(seq, *, second_camp=False):
        miners = [
            unit(10 + i, pos=[60, -10], order="GATHER", target_id=102, last_resource_id=102, gather_resource_type="GOLD")
            for i in range(3)
        ]
        workers = [unit(13 + i, pos=[0, 8]) for i in range(9)]
        buildings = [
            building(1, "town_center"),
            building(2, "barracks", [16, 16]),
            building(3, "mill", [-16, 16]),
            building(300, "farm", [-16, 24], amount=300, resource_type="FOOD"),
            building(4, "mining_camp", [20, -10]),
        ]
        if second_camp:
            buildings.append(building(5, "mining_camp", [54, -10]))
        entities = [
            *buildings,
            *miners,
            *workers,
            resource(102, "GOLD", [62, -10], amount=800),
        ]
        options = [
            {"building_def_id": "mining_camp", "builder_id": 13, "pos": [24, -14]},
            {"building_def_id": "mining_camp", "builder_id": 14, "pos": [54, -10], "resource_target_id": 102},
        ]
        req = frame(seq, entities=entities, time=seq * 10, catalog=FULL_CATALOG, construction_options=options)
        req.observation.economy.wood = 200
        req.observation.economy.food = 200
        return req

    for runtime in (MultiAgentRuntime("chinese"), CabinetRuntime("chinese")):
        out = runtime.tick(make_gold_req(1))
        placed = issued(out, "place_building")
        assert [(c["building_def_id"], c["pos"]) for c in placed] == [("mining_camp", [54, -10])]
        after = runtime.tick(make_gold_req(2, second_camp=True))
        assert not [c for c in issued(after, "place_building") if c["building_def_id"] == "mining_camp"]

    stone_runtime = CabinetRuntime("chinese")
    stone_runtime.mandates = [Mandate("defense", "towers", amount=3, origin="order#1")]
    stone_miners = [
        unit(10 + i, pos=[54, 25], order="GATHER", target_id=103, last_resource_id=103, gather_resource_type="STONE")
        for i in range(2)
    ]
    stone_entities = [
        building(1, "town_center"),
        building(2, "barracks", [16, 16]),
        building(3, "mill", [-16, 16]),
        building(300, "farm", [-16, 24], amount=300, resource_type="FOOD"),
        building(4, "mining_camp", [20, -10]),
        *stone_miners,
        *[unit(12 + i, pos=[0, 8]) for i in range(8)],
        resource(103, "STONE", [55, 25], amount=400),
    ]
    stone_req = frame(
        1,
        entities=stone_entities,
        time=10,
        catalog=FULL_CATALOG,
        construction_options=[
            {"building_def_id": "mining_camp", "builder_id": 12, "pos": [48, 25], "resource_target_id": 103},
        ],
    )
    stone_req.observation.progression.age = 1
    stone_req.observation.economy.wood = 300
    stone_req.observation.economy.food = 200
    stone_req.observation.economy.stone = 50
    stone_out = stone_runtime.tick(stone_req)
    assert any(c["building_def_id"] == "mining_camp" and c["pos"] == [48, 25] for c in issued(stone_out, "place_building"))
