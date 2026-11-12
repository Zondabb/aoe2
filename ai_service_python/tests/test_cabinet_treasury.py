"""The treasury ledger and the premier's rule book (docs/cabinet_ai_design.md, phase 2)."""
from types import SimpleNamespace

import pytest

from brain.cabinet.models import IntelBrief, Request, order_origin
from brain.cabinet.orders import default_mandates
from brain.cabinet.premier import Premier, apply_floors, default_tiers
from brain.cabinet.treasury import Treasury
from brain.profile_loader import profile_for_id


def req(rid, tranche, urgency=1, rank=50, created=0.0, **extra):
    return Request(id=rid, dept=rid.split("-")[0], key=(rid,), item=rid, remaining=dict(tranche), tranche=dict(tranche),
                   urgency=urgency, rank=rank, created_at=created, **extra)


def stock(food=0, wood=0, gold=0, stone=0):
    return {"food": food, "wood": wood, "gold": gold, "stone": stone}


def total(treasury, resource):
    return sum(held.get(resource, 0) for held in treasury.escrow.values())


def test_tiers_are_funded_in_order_and_earmarks_never_exceed_the_stock():
    treasury = Treasury()
    army, wall, tech = req("general-1", {"food": 300, "gold": 200}), req("defense-1", {"stone": 100, "food": 50}), req("tech-1", {"food": 200})
    treasury.allocate(stock(food=400, gold=120, stone=500), [tech, wall, army],
                      {"general-1": "now", "defense-1": "next", "tech-1": "later"})

    assert treasury.held("general-1") == {"food": 300, "gold": 120}
    assert treasury.held("defense-1") == {"stone": 100, "food": 50}
    assert treasury.held("tech-1") == {"food": 50}
    assert treasury.unallocated == stock(stone=400)
    assert treasury.gap(army) == {"gold": 80} and treasury.gap(wall) == {}
    assert not treasury.covers("general-1", army.tranche) and treasury.covers("defense-1", wall.tranche)


def test_same_tier_goes_by_urgency_then_department_rank_then_age():
    treasury = Treasury()
    requests = [req("economy-1", {"food": 100}, urgency=1, created=1), req("economy-2", {"food": 100}, urgency=3, created=9),
                req("general-1", {"food": 100}, urgency=3, rank=90, created=9), req("tech-1", {"food": 100}, urgency=1, created=0)]
    treasury.allocate(stock(food=250), requests, {})

    assert [rid for rid in ("general-1", "economy-2", "tech-1", "economy-1") if treasury.held(rid)] == ["general-1", "economy-2", "tech-1"]
    assert treasury.held("tech-1") == {"food": 50}


def test_a_request_on_hold_gets_nothing_and_gives_back_what_it_held():
    treasury = Treasury()
    wall, army = req("defense-1", {"stone": 300}), req("general-1", {"stone": 200})
    treasury.allocate(stock(stone=300), [wall, army], {"defense-1": "now", "general-1": "next"})
    assert treasury.held("defense-1") == {"stone": 300} and treasury.held("general-1") == {}

    treasury.allocate(stock(stone=300), [wall, army], {"defense-1": "hold", "general-1": "next"})
    assert treasury.held("defense-1") == {} and treasury.held("general-1") == {"stone": 200}
    assert treasury.unallocated["stone"] == 100


def test_a_one_off_purchase_accumulates_across_ticks_and_batches_hold_one_tranche():
    treasury = Treasury()
    age = req("tech-1", {"food": 500}, urgency=2)
    militia = req("general-1", {"food": 60}, urgency=1)
    tiers = {"tech-1": "next", "general-1": "later"}
    held = []
    for food in (120, 380, 540, 2000):
        treasury.allocate(stock(food=food), [age, militia], tiers)
        held.append((treasury.held("tech-1").get("food", 0), treasury.held("general-1").get("food", 0)))

    # Nothing behind the age-up is funded until its whole price is set aside,
    # and the batch never hoards more than it can spend at once.
    assert held == [(120, 0), (380, 0), (500, 40), (500, 60)]
    assert treasury.unallocated["food"] == 1440


def test_stock_spent_by_hand_is_lost_by_the_back_of_the_line_first():
    treasury = Treasury()
    requests = [req("economy-1", {"wood": 100}, urgency=3), req("general-1", {"wood": 175}, urgency=2), req("defense-1", {"wood": 80})]
    tiers = {"economy-1": "now", "general-1": "next", "defense-1": "later"}
    treasury.allocate(stock(wood=355), requests, tiers)
    assert [treasury.held(r.id).get("wood", 0) for r in requests] == [100, 175, 80]

    treasury.allocate(stock(wood=200), requests, tiers)   # the player built something
    assert [treasury.held(r.id).get("wood", 0) for r in requests] == [100, 100, 0]
    assert total(treasury, "wood") == 200


def test_a_department_can_spend_only_its_own_earmark():
    treasury = Treasury()
    villager, militia = req("economy-1", {"food": 50}), req("general-1", {"food": 60, "gold": 20})
    treasury.allocate(stock(food=100, gold=500), [villager, militia], {"economy-1": "now", "general-1": "next"})
    frame = SimpleNamespace(budget=stock(food=100, gold=500))

    def buy(cost):
        if any(frame.budget[r] < amount for r, amount in cost.items()):
            return False
        for r, amount in cost.items():
            frame.budget[r] -= amount
        return True

    with treasury.purse(frame, "general-1"):
        assert frame.budget == stock(food=50, gold=20)       # only what was set aside for it
        assert not buy({"food": 60, "gold": 20})
    assert frame.budget == stock(food=100, gold=500) and treasury.held("general-1") == {"food": 50, "gold": 20}

    with treasury.purse(frame, "economy-1"):
        assert buy({"food": 50}) and not buy({"food": 50})
    # The order's price left both the earmark and the real stock; it is not clawed back.
    assert frame.budget == stock(food=50, gold=500) and treasury.held("economy-1") == {"food": 0}

    treasury.allocate(frame.budget, [villager, militia], {"economy-1": "now", "general-1": "next"})
    assert treasury.held("economy-1") == {"food": 50} and total(treasury, "food") == 50


def test_waiting_time_comes_from_the_last_minute_of_deliveries():
    treasury = Treasury()
    for second, food in enumerate((100, 110, 60, 80, 90)):       # 40 delivered, 50 spent
        treasury.observe(float(second), stock(food=food, gold=30))
    age = req("tech-1", {"food": 500, "gold": 200})
    treasury.allocate(stock(food=90, gold=30), [age], {"tech-1": "now"})

    assert treasury.income()["food"] == pytest.approx(10.0) and treasury.income()["gold"] == 0
    assert treasury.gap(age) == {"food": 410, "gold": 170}
    assert treasury.eta(age) is None                            # no gold is coming in at all
    assert treasury.eta(req("tech-2", {"food": 100})) == pytest.approx(10.0)
    treasury.observe(200.0, stock(food=90, gold=30))
    assert treasury.income()["food"] == 0                       # deliveries older than a minute are forgotten


def test_rule_book_tiers_floor_orders_and_urgency():
    calm, attacked = IntelBrief(threat_level=1), IntelBrief(threat_level=3)
    house = req("economy-1", {"wood": 30}, urgency=3, floor=True)
    guard = req("general-1", {"food": 60}, urgency=3, emergency=True)
    paladins = req("general-2", {"food": 60, "gold": 75}, origin=order_origin(3))
    camp = req("economy-2", {"wood": 100}, urgency=2)
    loom = req("tech-1", {"gold": 50}, urgency=1)
    requests = [house, guard, paladins, camp, loom]

    assert default_tiers(requests, calm) == {"economy-1": "now", "general-1": "next", "general-2": "now", "economy-2": "next", "tech-1": "later"}
    assert default_tiers(requests, attacked)["general-1"] == "now"


def test_the_latest_of_two_orders_competing_for_a_resource_keeps_now():
    brief = IntelBrief()
    paladins = req("general-1", {"food": 60, "gold": 75}, origin=order_origin(3))
    age = req("tech-1", {"food": 1000, "gold": 800}, origin=order_origin(5))
    wall = req("defense-1", {"stone": 100}, origin=order_origin(4))

    tiers = default_tiers([paladins, age, wall], brief)
    assert tiers == {"general-1": "next", "tech-1": "now", "defense-1": "now"}   # stone competes with nobody


def test_no_ranking_can_push_a_protected_request_below_next():
    attacked = IntelBrief(threat_level=3)
    house = req("economy-1", {"wood": 30}, floor=True)
    guard = req("general-1", {"food": 60}, emergency=True)
    wall = req("defense-1", {"stone": 100})
    model_said = {"economy-1": "hold", "general-1": "later", "defense-1": "hold"}

    assert apply_floors(model_said, [house, guard, wall], attacked) == {"economy-1": "next", "general-1": "next", "defense-1": "hold"}
    assert apply_floors(model_said, [guard], IntelBrief(threat_level=2)) == {"general-1": "later"}
    assert Premier().rank([house, guard, wall], attacked) == {"economy-1": "now", "general-1": "now", "defense-1": "later"}


def test_the_civilization_profile_becomes_the_standing_mandates():
    mandates = default_mandates(profile_for_id("teutons"))

    assert [(m.dept, m.kind, m.subject, m.amount) for m in mandates] == [
        ("economy", "worker_target", None, 16), ("general", "stockpile", None, 6),
        ("general", "stockpile", "swordsman", 3), ("general", "stockpile", "teutonic_knight", 3)]
    assert all(m.origin == "routine" for m in mandates)
