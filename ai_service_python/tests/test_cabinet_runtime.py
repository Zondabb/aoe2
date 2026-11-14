"""Phase 2 of the cabinet architecture: requests, tiers and earmarks decide every purchase."""
from __future__ import annotations

import json

import pytest

from types import SimpleNamespace

from brain.cabinet.departments.base import Department
from brain.cabinet.models import Mandate
from brain.cabinet.runtime import CabinetRuntime
from brain.cabinet.treasury import Treasury
from brain.multi_agent.runtime import MultiAgentRuntime
from brain.multi_agent.scheduler import MultiAgentService
from brain.runtime_factory import create_runtime
from test_age_banking import age_frame
from test_llm_commander import building, unit
from test_multi_agent_runtime import accept, army, enemy_tc, frame, long_delivery_frame, plan
from test_multi_agent_scheduler import tick_request, wait_idle
from test_siege_strategy import battle
from test_wall_defense import defense_frame

PURCHASES = ("train", "place_building", "place_wall", "research_age", "research_technology")
DEPARTMENTS = {"premier", "economy", "intel", "general", "defense", "tech"}


def cabinet(profile="chinese", mandates=()):
    """A cabinet whose standing mandates are replaced, so a test states its own."""
    runtime = CabinetRuntime(profile)
    runtime.mandates = list(mandates)
    return runtime


def stocked(req, **stock):
    for resource in ("food", "wood", "gold", "stone"):
        setattr(req.observation.economy, resource, stock.get(resource, stock.get("each", 0)))
    return req


def bought(result) -> list[str]:
    return [c.get("unit_def_id") or c.get("building_def_id") or c.get("technology_id") or c["op"]
            for c in result["commands"] if c["op"] in PURCHASES]


def orders(result) -> list[str]:
    return sorted(json.dumps({k: v for k, v in c.items() if k != "command_id"}, sort_keys=True) for c in result["commands"])


def requests(result, dept) -> dict[str, dict]:
    return {row["item"].split(" x")[0]: row for row in result["agent_status"][dept]["requests"]}


def town(villagers, *extra, tc=None):
    return [building(1, "town_center", **(tc or {})), building(2, "barracks"), *extra] + [unit(10 + i) for i in range(villagers)]


def test_first_tick_files_requests_ranks_them_and_pays_from_their_earmarks():
    result = cabinet().tick(frame(1))

    assert set(result["agent_status"]) == DEPARTMENTS
    assert sorted(bought(result)) == ["barracks", "villager"]
    villagers, barracks = requests(result, "economy")["villager"], requests(result, "general")["barracks"]
    # Three villagers are below the dark-age floor of eight: a protected request.
    assert (villagers["tier"], villagers["urgency"]) == ("now", 3) and barracks["tier"] == "next"
    assert result["planning"]["tiers"] == result["agent_status"]["premier"]["tiers"]
    assert result["planning"]["tiers"][villagers["id"]] == "now" and result["planning"]["premier"]["source"] == "rules"
    # A request that has just bought is not short of money: the report shows what it was given and what it paid.
    assert (villagers["held"], villagers["spent"], villagers["gap"]) == ({"food": 50.0}, {"food": 50.0}, {})
    assert result["agent_status"]["economy"]["status"] == "running"
    # What was not set aside for anyone is still the common stock: 500 food less one villager.
    assert result["planning"]["treasury"]["unallocated"]["food"] == 450
    assert result["planning"]["intel"]["threat_level"] == 0
    # The engine roles behind each department stay readable in the tick log.
    roles = {role: status["reason"] for dept in result["agent_status"].values() for role, status in dept.get("roles", {}).items()}
    assert set(roles) == {"commander", "scout", "combat", "economy", "construction", "technology", "defense"}
    assert roles["combat"] == result["agent_status"]["general"]["reason"]


def test_without_money_nothing_is_bought_but_free_orders_go_on():
    result = cabinet().tick(stocked(frame(1)))

    assert bought(result) == []
    assert {c["op"] for c in result["commands"]} == {"gather", "move"}      # workers and the scout still act
    villagers = requests(result, "economy")["villager"]
    assert villagers["held"] == {} and villagers["gap"] == {"food": 50.0} and villagers["eta_sec"] is None
    assert result["agent_status"]["economy"]["status"] == "waiting_funds"


def scenarios():
    def opening(runtime):
        first = runtime.tick(stocked(frame(1), each=50000))
        second = runtime.tick(stocked(frame(2, events=accept(first)), each=50000))
        return [first, second, runtime.tick(stocked(frame(3, events=accept(second, seq=50)), each=50000))]

    def perimeter(runtime, field):
        plan(field, "technology", target_age=0)
        plan(field, "defense", policy="reactive")
        return [runtime.tick(stocked(defense_frame(), each=50000))]

    def siege(runtime, field):
        plan(field, "combat", army_target=2)
        workshop = building(3, "siege_workshop", trainable=["mangonel", "battering_ram"])
        return [runtime.tick(stocked(battle([*army(4), *town(8), workshop, enemy_tc()]), each=50000))]

    def next_age(runtime):
        req = age_frame(1, 16, 300, 300)
        req.observation.entities[0]["age_upgrade_reason"] = ""
        return [runtime.tick(stocked(req, each=50000))]

    return {"opening": lambda r, f: opening(r), "perimeter": perimeter, "siege": siege, "next_age": lambda r, f: next_age(r)}


@pytest.mark.parametrize("name", sorted(scenarios()))
def test_fully_funded_departments_order_what_the_seven_roles_order(name):
    play = scenarios()[name]
    old, new = MultiAgentRuntime("chinese"), cabinet()
    expected, actual = play(old, old), play(new, new.field)

    assert any(set(bought(result)) for result in expected), "the scenario must spend something"
    assert [orders(result) for result in actual] == [orders(result) for result in expected]


def test_villagers_below_the_floor_go_first_then_the_first_army_before_more_villagers():
    short = cabinet().tick(stocked(frame(entities=town(6)), food=60, gold=20))
    assert bought(short) == ["villager"]                     # six villagers: the floor of eight is protected
    assert requests(short, "economy")["villager"]["tier"] == "now"
    assert requests(short, "general")["militia"]["gap"] == {"food": 50.0}

    enough = cabinet().tick(stocked(frame(entities=town(8)), food=60, gold=20))
    assert bought(enough) == ["militia"]                     # at the floor, the first army outranks growth
    assert requests(enough, "economy")["villager"]["gap"] == {"food": 50.0}


def test_an_age_within_reach_takes_the_town_center_and_one_far_off_comes_after_the_first_army():
    def age_up(food, reason):
        req = stocked(frame(entities=town(8, building(3, "mill"), tc={"age_upgrade_reason": reason})), food=food, gold=100)
        req.observation.decision_context["catalog"]["age_upgrade"] = {
            "cost": {"food": 500}, "buildings": ["barracks", "mill", "lumber_camp"], "required_distinct_buildings": 2}
        return cabinet().tick(req)

    ready = age_up(500, "")                                  # not even the first army's militia comes before it
    assert bought(ready) == ["research_age"] and "villager" not in requests(ready, "economy")

    nearly = age_up(420, "资源不足")                          # past 80%: villagers stop so the queue can drain
    assert bought(nearly) == [] and requests(nearly, "tech")["age_1"]["held"] == {"food": 420.0}
    assert "villager" not in requests(nearly, "economy")

    far = age_up(200, "资源不足")
    assert bought(far) == ["militia", "villager"]            # the first army and growth come before its saving
    assert requests(far, "tech")["age_1"]["held"] == {"food": 90.0}


def test_an_age_still_far_off_puts_by_its_share_and_the_army_keeps_growing():
    runtime = cabinet()

    def tick(number, food):
        entities = town(16, building(3, "mill"), *army(6), tc={"age_upgrade_reason": "资源不足"})
        req = stocked(frame(number, entities=entities, time=number * 10), food=food, gold=100)
        req.observation.decision_context["catalog"]["age_upgrade"] = {
            "cost": {"food": 500}, "buildings": ["barracks", "mill", "lumber_camp"], "required_distinct_buildings": 2}
        return runtime.tick(req)

    def age(result):
        return requests(result, "tech")["age_1"]

    first = tick(1, 300)                                     # the first army is out: militia now are reinforcements
    assert requests(first, "general")["militia"]["tier"] == "later" and age(first)["tier"] == "next"
    assert age(first)["held"] == {"food": 150.0} and age(first)["price"] == {"food": 500.0}       # half of what is there
    assert bought(first) == ["militia"]
    second = tick(2, 340)                                    # what was put by, and half of what came in since
    assert age(second)["held"] == {"food": 245.0}
    assert requests(second, "general")["militia"]["gap"] == {}
    third = tick(3, 390)
    assert age(third)["held"] == {"food": 317.5} and bought(third) == ["militia"]
    close = tick(4, 420)                                     # within reach: now it takes everything
    assert age(close)["held"] == {"food": 420.0} and requests(close, "general")["militia"]["gap"] == {"food": 60.0}
    assert bought(close) == []


def test_an_age_the_game_keeps_refusing_gives_the_town_center_back():
    runtime = cabinet()

    def tick(number, now, events=()):
        tc = {"age_upgrade_reason": "需要两种已建成的当前时代建筑"}      # the catalog below says they are built
        req = stocked(frame(number, entities=town(8, building(3, "mill"), tc=tc), time=now, events=events), food=600, gold=100)
        req.observation.decision_context["catalog"]["age_upgrade"] = {
            "cost": {"food": 500}, "buildings": ["barracks", "mill", "lumber_camp"], "required_distinct_buildings": 2}
        return runtime.tick(req)

    first = tick(1, 0)
    assert requests(first, "tech")["age_1"]["gap"] == {} and "villager" not in bought(first)   # paid for: the queue is kept empty
    assert "villager" not in bought(tick(2, 60, accept(first)))
    stuck = tick(3, 100)                                     # ninety seconds and still refused
    assert requests(stuck, "tech")["age_1"]["yielding"] is True
    released = tick(4, 112)
    assert "villager" in bought(released) and "research_age" not in bought(released)


def test_a_builder_stuck_on_a_wall_section_does_not_hold_up_the_next_building():
    runtime = cabinet()

    def tick(number, now, house_progress):
        entities = [building(1, "town_center"),
                    building(300, "palisade_wall", [30, 0], complete=False, build_progress=0.0),
                    building(310, "house", [10, 0], complete=False, build_progress=house_progress),
                    *[unit(10 + i) for i in range(3)],
                    unit(13, pos=[20, 0], order="BUILD", target_id=300),         # never gets there
                    unit(14, pos=[9, 0], order="BUILD", target_id=310)]
        return runtime.tick(stocked(frame(number, entities=entities, time=now), food=500, wood=500))

    def construction(result):
        return result["agent_status"]["economy"]["roles"]["construction"]["reason"]

    waiting = tick(1, 0, .1)                                 # both builder places are taken
    assert "barracks" not in bought(waiting) and construction(waiting) == "complete_active_foundations"
    released = tick(2, 61, .7)
    assert "barracks" in bought(released) and construction(released) == "build_barracks"
    assert [c["op"] for c in released["commands"] if c.get("unit_id") == 13] in (["gather"], ["stop"])


def test_a_farm_nobody_can_reach_does_not_end_farming():
    runtime = cabinet()
    site = {"building_def_id": "farm", "builder_id": 16, "pos": [24, 24]}

    def tick(number, now, **builders):
        # A farm foundation in a place its builders cannot get to.
        field = building(4, "farm", [40, 40], complete=False, build_progress=0.0, amount=300, resource_type="FOOD")
        entities = town(8, building(3, "mill"), field)
        for uid, state in builders.items():
            next(e for e in entities if e["id"] == int(uid[1:])).update(**state)
        return runtime.tick(stocked(frame(number, entities=entities, time=now, construction_options=[site]), food=20, wood=400))

    def sent_to_build(result):
        return [c["unit_id"] for c in result["commands"] if c["op"] == "build" and c["building_id"] == 4]

    stuck = dict(pos=[38, 38], order="BUILD", target_id=4)
    tick(1, 0, u10=stuck)
    relieved = tick(2, 60, u10=stuck)                        # the villager next to the field gave up on it
    first_relief = sent_to_build(relieved)
    assert len(first_relief) == 1 and first_relief[0] != 10
    # One farm at a time still holds: someone is on the way to this one.
    assert "farm" not in requests(relieved, "economy")
    # The relief never set off, and the villager kept off building is the nearest free hand: it is not sent back.
    idle_beside_it = dict(pos=[38, 38], order="GATHER", target_id=100)
    resent = sent_to_build(tick(3, 75, u10=idle_beside_it))  # the economy's own short hold on it has run out by now
    assert len(resent) == 1 and resent[0] != 10

    second = {f"u{first_relief[0]}": dict(pos=[37, 37], order="BUILD", target_id=4)}
    tick(4, 76, **second)
    given_up = tick(5, 136, **second)                        # the second builder failed there too
    assert sent_to_build(given_up) == []
    # The field is set aside, and no longer stands in for the farm the economy needs.
    assert "farm" in bought(given_up) and requests(given_up, "economy")["farm"]["spent"] == {"wood": 60.0}


def test_a_site_paired_with_a_villager_kept_off_building_is_passed_over():
    runtime = cabinet()

    def tick(number, now, builder, sites, finished=False):
        entities = [building(1, "town_center"), building(310, "house", [40, 0], complete=finished, build_progress=.1),
                    *[unit(10 + i) for i in range(4)], builder]
        return runtime.tick(stocked(frame(number, entities=entities, time=now, construction_options=sites), food=500, wood=500))

    near = {"building_def_id": "barracks", "builder_id": 20, "pos": [24, 0]}
    far = {"building_def_id": "barracks", "builder_id": 11, "pos": [0, 24]}
    stuck = unit(20, pos=[30, 0], order="BUILD", target_id=310)
    tick(1, 0, stuck, [near])
    tick(2, 60, stuck, [near])                               # villager 20 is relieved and kept off building
    idle = unit(20, pos=[30, 0], order="GATHER", target_id=100)
    only_its_site = tick(3, 80, idle, [near], finished=True)  # long after the economy's own hold on it ran out
    assert "barracks" not in bought(only_its_site)
    other_site = tick(4, 81, idle, [near, far], finished=True)
    placed = [c for c in other_site["commands"] if c["op"] == "place_building"]
    assert [(c["building_def_id"], c["builder_id"]) for c in placed] == [("barracks", 11)]

    # With no villager kept off building, the nearer site is the one taken.
    runtime = cabinet()
    fresh = tick(1, 81, idle, [near, far], finished=True)
    assert [c["builder_id"] for c in fresh["commands"] if c["op"] == "place_building"] == [20]


def test_a_request_that_can_buy_nothing_does_not_take_a_place_from_one_that_can():
    dept = Department(SimpleNamespace(now=0.0), Treasury())
    dept.name = "economy"
    dept.begin()
    for name, priority in (("lumber_camp", 111), ("mill", 108), ("mining_camp", 58)):
        dept.want(("building", name), name, {"wood": 100}, capacity=0, urgency=2, rank=priority)     # no legal site
    dept.want(("building", "castle"), "castle", {"stone": 650}, needs=("需要城堡时代",), urgency=3)
    dept.want(("building", "farm"), "farm", {"wood": 60}, urgency=0, rank=45)
    dept.want(("unit", "villager"), "villager", {"food": 50}, count=4, urgency=2, rank=104)

    assert [r.item for r in dept.requests()] == ["villager", "farm", "castle"]


def test_a_building_asked_for_under_an_unlisted_reason_still_gets_a_request():
    runtime = cabinet()
    original = runtime.field._economy_requirements

    def with_another_house(f):
        original(f)
        runtime.field._request_building(f, "house", 70, "a_reason_added_later")
    runtime.field._economy_requirements = with_another_house
    result = runtime.tick(stocked(frame(entities=town(8)), food=500, wood=200))

    assert requests(result, "economy")["house"]["urgency"] == 1 and "house" in bought(result)


def test_requests_follow_what_can_actually_be_bought():
    # No town center: nobody asks for villagers, and the militia is not kept waiting behind them.
    lone = cabinet().tick(stocked(frame(entities=[building(2, "barracks")]), food=60, gold=20))
    assert bought(lone) == ["militia"] and "villager" not in requests(lone, "economy")

    # One farm at a time: while a foundation is open, the next farm is not requested.
    def farming(complete):
        farm = building(4, "farm", [12, 12], complete=complete, amount=300, resource_type="FOOD")
        req = frame(entities=town(8, building(3, "mill"), farm), construction_options=[{"building_def_id": "farm", "builder_id": 11, "pos": [24, 24]}])
        return cabinet().tick(stocked(req, food=20, wood=400))
    assert "farm" in requests(farming(True), "economy") and "farm" not in requests(farming(False), "economy")


def test_routine_upgrades_are_bought_from_plenty_only():
    def researched(gold):
        runtime = cabinet()
        plan(runtime.field, "technology", target_age=0)
        university = building(3, "university", technologies=[{"id": "chemistry", "reason": ""}])   # 300 food, 200 gold
        return runtime.tick(stocked(battle(town(16, university), age=0), food=1000, gold=gold))

    assert "chemistry" in bought(researched(1000))
    barely = researched(300)                                 # affordable, but not twice over as the plan's share asks
    assert "chemistry" not in bought(barely) and barely["agent_status"]["tech"]["requests"] == []


def test_a_saving_that_gets_no_closer_steps_back_for_a_cheaper_purchase():
    runtime = cabinet()
    first = runtime.tick(long_delivery_frame())              # 60 wood: a 100-wood camp outranks a 60-wood farm
    assert bought(first) == [] and requests(first, "economy")["lumber_camp"]["held"] == {"wood": 60.0}

    later = runtime.tick(long_delivery_frame(2, time=182, events=accept(first)))   # three minutes, no wood came in
    assert bought(later) == ["farm"]
    assert requests(later, "economy")["lumber_camp"]["yielding"] is True


def test_siege_money_is_not_spent_on_escorts():
    runtime = cabinet()
    plan(runtime.field, "combat", army_target=2)
    workshop = building(3, "siege_workshop", trainable=["battering_ram"], train_blocked_reasons={"battering_ram": "资源不足"})
    req = battle([*army(4), building(1, "town_center"), building(2, "barracks"), workshop, enemy_tc()])
    result = runtime.tick(stocked(req, food=500, wood=130, gold=50))

    assert bought(result) == ["villager"]                    # the ram keeps the gold a militia would have taken
    ram = requests(result, "general")["battering_ram"]
    assert ram["held"] == {"wood": 130.0, "gold": 50.0} and set(ram["gap"]) == {"wood", "gold"}


def test_routine_walls_are_built_from_surplus_wood_only():
    def walled(wood):
        runtime = cabinet()
        plan(runtime.field, "technology", target_age=0)
        plan(runtime.field, "defense", policy="reactive")
        return runtime.tick(stocked(defense_frame(), food=500, wood=wood, gold=400))

    assert "palisade_wall" in bought(walled(600))
    tight = walled(110)                                      # 16 wood for the line would break the 100-wood reserve
    assert "palisade_wall" not in bought(tight) and requests(tight, "defense") == {}
    # Not a matter of money: the department passes on the field role's own word.
    defense = tight["agent_status"]["defense"]
    assert (defense["status"], defense["reason"]) == ("waiting", "perimeter_budget_or_hidden_or_blocked_section")


def test_standing_mandates_come_from_the_profile_and_set_department_parameters():
    runtime = CabinetRuntime("teutons")
    runtime.tick(frame(1))
    assert [(m.dept, m.kind, m.amount) for m in runtime.mandates[:2]] == [("economy", "worker_target", 16), ("general", "stockpile", 6)]
    assert runtime.field.roles["economy"].plan["worker_target"] == 16 and runtime.field.goals["sortie_target"] == 6

    ordered = cabinet(mandates=[Mandate("economy", "worker_target", amount=30), Mandate("general", "stockpile", amount=10),
                                Mandate("general", "stockpile", subject="spearman", amount=2)])
    barracks = building(2, "barracks", trainable=["militia", "spearman"])
    req = stocked(frame(entities=[building(1, "town_center"), barracks] + [unit(10 + i) for i in range(8)]), each=2000)
    req.observation.decision_context["catalog"]["units"].append({"id": "spearman", "cost": {"food": 35, "wood": 25}, "train_at": "barracks"})
    result = ordered.tick(req)

    assert ordered.field.roles["economy"].plan["worker_target"] == 30
    assert ordered.field.goals["sortie_target"] == ordered.field.next_sortie_target == 10
    assert requests(result, "economy")["villager"]["item"] == "villager x22"
    assert "spearman" in bought(result) and "militia" not in bought(result)


def test_a_finished_match_closes_every_department():
    runtime = cabinet()
    runtime.tick(frame(entities=army() + [enemy_tc()]))
    req = frame(2, entities=army(), events=[{"seq": 1, "type": "entity_destroyed", "entity_id": 200}])
    req.observation.decision_context["victory_conditions"] = {"type": "destroy_any_enemy_town_center"}
    result = runtime.tick(req)

    assert result["goals"]["victory_confirmed"] and result["commands"] == []
    assert {status["status"] for status in result["agent_status"].values()} == {"complete"}
    assert not runtime.field.pending and runtime.match_summary["result"] == "victory"


def test_a_retried_tick_is_answered_from_the_cache_and_an_old_tick_changes_nothing():
    runtime = cabinet()
    first = runtime.tick(frame(1))
    assert runtime.tick(frame(1)) == first
    runtime.tick(frame(2, events=accept(first)))
    stale = runtime.tick(frame(1))
    assert stale["commands"] == [] and set(stale["agent_status"]) == DEPARTMENTS
    assert runtime.field.last_tick == 2


def test_cabinet_runtime_takes_cross_match_memory():
    runtime = CabinetRuntime("teutons")
    runtime.load_strategic_memory({"lessons": ["wall early"]})
    assert runtime.field.strategic_memory == {"lessons": ["wall early"]}
    assert runtime.field.validator.profile_id == "teutons"


def test_factory_follows_the_runtime_setting_for_each_new_session(monkeypatch):
    assert type(create_runtime("chinese")) is MultiAgentRuntime
    monkeypatch.setenv("AOE2_AI_RUNTIME", "cabinet")
    assert type(create_runtime("chinese")) is CabinetRuntime
    monkeypatch.setenv("AOE2_AI_RUNTIME", "multi_agent")
    assert type(create_runtime("chinese")) is MultiAgentRuntime
    monkeypatch.setenv("AOE2_AI_RUNTIME", "cabinnet")
    with pytest.raises(ValueError, match="Unknown AI runtime"):
        create_runtime("chinese")


def test_service_runs_the_cabinet_by_rule_without_calling_a_model(monkeypatch):
    monkeypatch.setenv("AOE2_AI_RUNTIME", "cabinet")
    monkeypatch.setenv("AOE2_AI_BACKEND", "openai")
    calls = []
    service = MultiAgentService(runtime_factory=create_runtime, forward=lambda req: calls.append(req))
    try:
        results = []
        for seq in (1, 2, 3):
            results.append(service.tick(tick_request(seq, backend="openai")))
            wait_idle(service)
    finally:
        service.shutdown()

    assert calls == []                                       # the premier has no model yet
    assert "villager" in bought(results[0]) and set(results[0]["agent_status"]) == DEPARTMENTS
    planning = results[-1]["planning"]
    assert planning["backend"] == "rules" and planning["premier"]["source"] == "rules" and "tiers" in planning
    assert all(c["session_epoch"] == "epoch-a" for result in results for c in result["commands"])
