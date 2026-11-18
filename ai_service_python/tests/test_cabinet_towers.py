"""Cabinet tower orders go through the same budget and command arbiter as other construction."""
import copy

import pytest

from brain.cabinet.models import Mandate
from brain.cabinet.orders import TOWER_LINE, ground
from brain.cabinet.premier import interpret_schema
from test_cabinet_orders import m, read
from test_cabinet_runtime import cabinet, requests, stocked, town
from test_llm_commander import building
from test_multi_agent_runtime import frame, issued


def snapshot(tick=1, *, age=1, stone=500, bounds=(-28, -28, 56, 56), extra=(), events=()):
    req = frame(tick, entities=town(8, *extra), construction_options=[], defense_plan={"bounds": list(bounds)}, events=events)
    req.observation.progression.age = age
    return stocked(req, stone=stone, wood=500, food=500)


def tower_commands(result):
    return [c for c in issued(result, "place_building") if c["building_def_id"] in TOWER_LINE]


def with_order(amount=2):
    return cabinet(mandates=[Mandate("defense", "towers", amount=amount, origin="order#1")])


def test_order_pays_one_tower_at_a_time_and_finishes_only_from_a_completed_owned_tower():
    runtime = cabinet()
    text = "造 2 座箭塔"
    existing = building(40, "guard_tower", [-18, 8])
    enemy = building(41, "keep", [18, 8], team=1)

    def tick(number, *added, events=()):
        req = snapshot(number, extra=[existing, enemy, *added], events=events)
        req.observation.player_instructions = [text]
        return runtime.tick(req)

    assert not tower_commands(tick(1))
    assert runtime.planning_brief("premier_orders")["context"]["order"] == text
    assert runtime.apply_plan("premier_orders", read(m("towers", amount=2)))
    result = tick(2)
    tower, = tower_commands(result)
    row = requests(result, "defense")["watch_tower"]
    assert (row["origin"], row["spent"], row["price"]) == ("order#1", {"wood": 25, "stone": 125}, {"wood": 25, "stone": 125})
    assert not tower_commands(tick(3))
    receipt = {"seq": 1, "type": "command_result", "command_id": tower["command_id"], "ok": True}
    assert not tower_commands(tick(4, events=[receipt]))
    site = building(50, "watch_tower", tower["pos"], complete=False)
    assert not tower_commands(tick(5, site))
    assert runtime.ledger.orders[0].status == "active"
    site["is_complete"] = True
    assert not tower_commands(tick(6, site))
    assert runtime.ledger.orders[0].status == "done"
    assert runtime.ledger.orders[0].figures[("defense", "towers")] == "2/2"


def test_towers_derive_feudal_age_and_only_reserve_one_purchase():
    runtime = with_order(4)
    locked = runtime.tick(snapshot(age=0))
    row = requests(locked, "defense")["watch_tower"]
    assert row["needs"] == ["age_1"] and row["held"] == {}
    assert any(m.kind == "advance_age" and m.amount == 1 and m.origin == "order#1" for m in runtime.in_force)
    short = runtime.tick(snapshot(2, stone=80))
    row = requests(short, "defense")["watch_tower"]
    assert not tower_commands(short)
    assert row["price"] == {"wood": 100, "stone": 500} and row["gap"] == {"stone": 45}
    assert runtime.field.demands["stone"] >= 125
    assert len(tower_commands(runtime.tick(snapshot(3)))) == 1


@pytest.mark.parametrize("bounds", [(), (1, 2), (0, 0, 4, 4)])
def test_missing_perimeter_does_not_spend_or_reserve(bounds):
    result = with_order().tick(snapshot(bounds=bounds))
    row = requests(result, "defense")["watch_tower"]
    assert not tower_commands(result) and row["held"] == {} and row["needs"]


def test_visibility_blockers_and_rejection_change_the_site_without_altering_the_observation():
    runtime = with_order()
    req = snapshot()
    req.observation.placement_visibility = {"origin": [-100, -100], "grid_size": [100, 100], "cell_size": 2, "sources": [[0, 0, 3]]}
    assert not tower_commands(runtime.tick(req))
    req = snapshot(2)
    original = copy.deepcopy(req.observation.decision_context)
    first, = tower_commands(runtime.tick(req))
    assert req.observation.decision_context == original
    rejected = {"seq": 1, "type": "command_result", "ok": False, "command_id": first["command_id"], "reason": "invalid_placement"}
    second, = tower_commands(runtime.tick(snapshot(3, events=[rejected])))
    assert second["pos"] != first["pos"]
    blocked = snapshot(extra=[building(40, "house", first["pos"])])
    other, = tower_commands(with_order().tick(blocked))
    assert other["pos"] != first["pos"]


def test_upgraded_tower_is_bought_only_when_researched():
    req = snapshot(age=3)
    req.observation.progression.researched_technologies = {"guard_tower": True}
    tower, = tower_commands(with_order().tick(req))
    assert tower["building_def_id"] == "guard_tower"
    assert ground([m("towers")], "chinese", 1).mandates[0].amount == 1
    assert "towers" in interpret_schema()["properties"]["mandates"]["items"]["properties"]["kind"]["enum"]


def test_gather_for_the_next_tower_while_the_first_is_under_construction():
    runtime = with_order(2)
    foundation = building(40, "watch_tower", [18, 6], complete=False)
    result = runtime.tick(snapshot(stone=0, extra=[foundation]))
    assert runtime.field.demands["stone"] >= 125
    assert not tower_commands(result) and not requests(result, "defense")

