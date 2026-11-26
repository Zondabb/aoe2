from __future__ import annotations

from brain.multi_agent.runtime import MultiAgentRuntime
from test_cabinet_premier import decision
from test_cabinet_runtime import bought, cabinet, requests, stocked, town
from test_llm_commander import building, unit
from test_multi_agent_runtime import frame, issued, plan


def test_builder_limit_scales_with_workforce_without_letting_walls_starve_farms():
    # Small workforce stays capped at 2.
    small_entities = [
        building(1, "town_center"),
        building(2, "barracks"),
        building(3, "mill"),
        building(300, "palisade_wall", [30, 0], complete=False, build_progress=0.2),
        building(310, "house", [10, 0], complete=False, build_progress=0.0),
        unit(10, pos=[30, 0], order="BUILD", target_id=300),
        unit(11, pos=[10, 0], order="BUILD", target_id=310),
        unit(12),
        unit(13),
        unit(14),
    ]
    small_req = stocked(
        frame(entities=small_entities, construction_options=[{"building_def_id": "farm", "builder_id": 12, "pos": [24, 24]}]),
        food=20,
        wood=2500,
    )
    assert "farm" not in bought(cabinet().tick(small_req))

    # 48 villagers scale builder limit to 8, so 1 wall builder + 1 stuck house builder still allow placing a farm.
    large_entities = [
        building(1, "town_center"),
        building(2, "barracks"),
        building(3, "mill"),
        building(300, "palisade_wall", [30, 0], complete=False, build_progress=0.2),
        building(310, "house", [10, 0], complete=False, build_progress=0.0),
        unit(10, pos=[30, 0], order="BUILD", target_id=300),
        unit(11, pos=[10, 0], order="BUILD", target_id=310),
        *[unit(12 + i) for i in range(46)],
    ]
    large_req = stocked(
        frame(entities=large_entities, construction_options=[{"building_def_id": "farm", "builder_id": 12, "pos": [24, 24]}]),
        food=20,
        wood=2500,
    )
    assert "farm" in bought(cabinet().tick(large_req))
    assert "farm" in bought(MultiAgentRuntime("chinese").tick(large_req))

    # Explicit non-default construction plan still overrides scaling.
    explicit = MultiAgentRuntime("chinese")
    plan(explicit, "construction", max_builders=1)
    assert "farm" not in bought(explicit.tick(large_req))


def test_large_workforce_places_concurrent_farm_foundations_while_small_stays_serial():
    site = [{"building_def_id": "farm", "builder_id": 20, "pos": [28, 28]}]

    # 8 villagers with 1 active farm foundation still stay serial.
    small_farms = [building(300, "farm", [12, 12], complete=False, build_progress=0.2, amount=175, resource_type="FOOD")]
    small_entities = [building(1, "town_center"), building(2, "barracks"), building(3, "mill"), *small_farms, *[unit(10 + i) for i in range(8)]]
    small_entities[-1]["id"] = 20
    small_req = stocked(frame(entities=small_entities, construction_options=site), food=20, wood=2500)
    small_res = cabinet().tick(small_req)
    assert "farm" not in requests(small_res, "economy")
    assert "farm" not in bought(small_res)

    # 36 villagers with 2 incomplete farm foundations still request and place another farm foundation.
    large_farms = [
        building(300, "farm", [12, 12], complete=False, build_progress=0.2, amount=175, resource_type="FOOD"),
        building(301, "farm", [20, 12], complete=False, build_progress=0.3, amount=175, resource_type="FOOD"),
    ]
    large_entities = [building(1, "town_center"), building(2, "barracks"), building(3, "mill"), *large_farms, *[unit(10 + i) for i in range(36)]]
    large_req = stocked(frame(entities=large_entities, construction_options=site), food=20, wood=2500)
    large_res = cabinet().tick(large_req)
    assert "farm" in requests(large_res, "economy")
    assert "farm" in bought(large_res)


def test_essential_farm_supply_cannot_be_held_by_premier_when_wood_is_abundant():
    site = [{"building_def_id": "farm", "builder_id": 10, "pos": [24, 24]}]

    # 30 villagers, 1 usable farm, food=180, wood=2500 -> under_farmed raises urgency to 2 (not 0).
    entities_one_farm = town(30, building(3, "mill"), building(300, "farm", [12, 12], complete=True, amount=175, resource_type="FOOD"))
    req_one_farm = stocked(frame(entities=entities_one_farm, construction_options=site), food=180, wood=2500)
    res_one_farm = cabinet().tick(req_one_farm)
    assert requests(res_one_farm, "economy")["farm"]["urgency"] == 2

    # When food=100 (or 0 usable farms with food=350), Premier putting farm on "hold" is lifted to "next".
    for food_stock, extra in ((100, [building(300, "farm", [12, 12], complete=True, amount=175, resource_type="FOOD")]), (350, [])):
        rt = cabinet()
        entities = town(30, building(3, "mill"), *extra)
        first = rt.tick(stocked(frame(1, entities=entities, construction_options=site), food=food_stock, wood=50))
        farm_id = requests(first, "economy")["farm"]["id"]
        assert rt.apply_plan("premier", decision({farm_id: "hold"}, "defend"))
        second = rt.tick(stocked(frame(2, entities=entities, construction_options=site, time=10), food=food_stock, wood=2500))
        assert second["planning"]["tiers"][farm_id] == "next"
        assert "farm" in bought(second)

    # Scarcity control: wood=0 does NOT protect farm against Premier hold.
    rt_dry = cabinet()
    entities_dry = town(30, building(3, "mill"))
    first_dry = rt_dry.tick(stocked(frame(1, entities=entities_dry, construction_options=site), food=100, wood=0))
    farm_dry_id = requests(first_dry, "economy")["farm"]["id"]
    assert rt_dry.apply_plan("premier", decision({farm_dry_id: "hold"}, "defend"))
    second_dry = rt_dry.tick(stocked(frame(2, entities=entities_dry, construction_options=site, time=10), food=100, wood=0))
    assert second_dry["planning"]["tiers"][farm_dry_id] == "hold"


def test_overflow_workers_do_not_split_evenly_into_surplus_gold_and_shift_to_open_farms():
    resources = [
        {"id": 100, "kind": "resource", "resource_type": "WOOD", "pos": [10, 0], "amount": 1000},
        {"id": 101, "kind": "resource", "resource_type": "GOLD", "pos": [0, 10], "amount": 1000},
    ]
    # 20 idle overflow villagers when food=18, wood=3337, gold=3945, no open food plots.
    idle_workers = [unit(10 + i) for i in range(20)]
    rt = MultiAgentRuntime("chinese")
    req = stocked(frame(entities=[building(1, "town_center"), building(2, "barracks"), *idle_workers, *resources], construction_options=[]),
                  food=18, wood=3337, gold=3945)
    out = rt.tick(req)
    gathers = issued(out, "gather")
    wood_assigned = sum(1 for c in gathers if c["target_id"] == 100)
    gold_assigned = sum(1 for c in gathers if c["target_id"] == 101)
    assert len(gathers) == 20
    assert wood_assigned >= 16 and gold_assigned <= 4

    # Active gatherers do not thrash when both wood and gold are already in surplus.
    active_workers = (
        [unit(10 + i, order="GATHER", target_id=100, gather_resource_type="WOOD") for i in range(10)]
        + [unit(20 + i, order="GATHER", target_id=101, gather_resource_type="GOLD") for i in range(10)]
    )
    rt_active = MultiAgentRuntime("chinese")
    req_active = stocked(frame(entities=[building(1, "town_center"), building(2, "barracks"), *active_workers, *resources], construction_options=[]),
                         food=18, wood=3337, gold=3945)
    out_active = rt_active.tick(req_active)
    assert not issued(out_active, "gather")

    # Once a completed farm appears, a surplus worker rebalances onto the farm;
    # when gold is in surplus and wood is not, specifically a gold miner shifts.
    farm = building(300, "farm", [8, 8], complete=True, amount=175, resource_type="FOOD")
    req_farm = stocked(frame(2, entities=[building(1, "town_center"), building(2, "barracks"), building(3, "mill"), farm, *active_workers, *resources],
                             construction_options=[], time=60),
                       food=18, wood=3337, gold=3945)
    out_farm = rt_active.tick(req_farm)
    assert any(c["target_id"] == 300 for c in issued(out_farm, "gather"))

    rt_gold_surplus = MultiAgentRuntime("chinese")
    req_gold_surplus = stocked(frame(1, entities=[building(1, "town_center"), building(2, "barracks"), building(3, "mill"), farm, *active_workers, *resources],
                                     construction_options=[], time=60),
                               food=18, wood=100, gold=3945)
    out_gold_surplus = rt_gold_surplus.tick(req_gold_surplus)
    assert any(c["target_id"] == 300 and 20 <= c["unit_id"] < 30 for c in issued(out_gold_surplus, "gather"))
