"""Phase 4 of the cabinet architecture: the head of state's orders become mandates the departments carry out."""
from __future__ import annotations

import json
import math
from pathlib import Path
from types import SimpleNamespace

from jsonschema import Draft202012Validator, ValidationError
import pytest

from brain.cabinet.departments.base import Department
from brain.cabinet.ledger import ACTIVE, DONE, IMPOSSIBLE, NEW, REFUSED, SUPERSEDED, UNANSWERED, UNREAD, OrderLedger
from brain.cabinet.models import IntelBrief, Mandate, Request, order_origin
from brain.cabinet.orders import (BUILD, NAMES, STOCKPILE_CAP, Grounding, default_mandates, derive, ground, later_forms, load_policy,
                                  name_table, needs_of, policy_entries, progress, slot, subject_ids)
from brain.cabinet.premier import INTERPRET_PROMPT, default_tiers, interpret_context, interpret_schema, reading
from brain.cabinet.runtime import CabinetRuntime
from brain.cabinet.treasury import Treasury
from brain.land_progression import CATALOG
from brain.multi_agent.scheduler import MultiAgentService
from brain import profile_loader
from brain.profile_loader import CivAiProfile, profile_for_id
from brain.runtime_factory import create_runtime
from protocol.models import Progression
from test_cabinet_premier import cabinet_service
from test_cabinet_runtime import bought, cabinet, requests, stocked, town
from test_llm_commander import building, unit
from test_multi_agent_runtime import army, enemy_tc, frame, issued
from test_multi_agent_scheduler import completion, tick_request
from test_wall_defense import defense_frame
from tools.export_land_catalog import project_name_catalog

ROOT = Path(__file__).resolve().parents[2]
SAID = {"thinking": "元首要一支游侠。", "decision": "囤积五十个游侠。"}


def m(kind, subject="", amount=0, urgency="normal"):
    return {"kind": kind, "subject": subject, "amount": amount, "urgency": urgency}


def read(*mandates, grasp="exact", **texts):
    return {**SAID, **texts, "grasp": grasp, "mandates": list(mandates)}


def flat(mandates):
    return [(x.dept, x.kind, x.subject, x.amount, x.urgency) for x in mandates]


# ---------------------------------------------------------------------------- the catalog the model is shown
def test_the_name_catalog_is_the_games_own():
    source = json.loads((ROOT / "data/civilization_catalog.json").read_text(encoding="utf8"))
    assert NAMES == project_name_catalog(source)
    assert NAMES["units"]["paladin"] == {"zh": "游侠", "en": "Paladin"} and NAMES["civilizations"] == {"chinese": "中国", "teutons": "条顿"}
    assert NAMES["technologies"]["paladin"]["prerequisite_technology"] == "cavalier"


def test_the_model_is_shown_every_unit_and_technology_and_what_this_civilization_may_use():
    table = name_table("chinese")
    assert (len(table["units"]), len(table["techs"])) == (41, 26)
    units = {row[0]: row for row in table["units"]}
    assert units["paladin"] == ["paladin", "游侠", "Paladin", 3, 0] and units["cavalier"][4] == 1
    assert {row[0]: row[4] for row in name_table("teutons")["units"]}["paladin"] == 1
    assert all(row[4] == 1 for row in name_table("default")["units"])      # an unknown civilization is not second-guessed
    ids = subject_ids()
    assert len(ids) == len(set(ids)) and {"", "food", "stone", "paladin", "chemistry", "villager"} <= set(ids)

    context = interpret_context("囤积50个游侠", [{"id": 1, "text": "多采黄金", "status": "执行中"}], "teutons", 2)
    assert (context["order"], context["civilization"], context["age"]) == ("囤积50个游侠", "teutons", 2) and "previous" not in context
    assert len(json.dumps(context, ensure_ascii=False, separators=(",", ":"))) < 3500
    again = interpret_context("x", [], "teutons", 2, {"mandates": [m("research", "knight")], "problem": "不是科技"})
    assert again["previous"]["problem"] == "不是科技"
    for kind in ("boost_resource", "worker_target", "stockpile", "attack", "hold", "fortify", "advance_age", "research", "scout"):
        assert kind in INTERPRET_PROMPT


def test_an_answer_can_only_name_what_the_catalog_holds():
    schema = interpret_schema()
    Draft202012Validator.check_schema(schema)
    check = Draft202012Validator(schema).validate
    check(read(m("stockpile", "paladin", 50)))
    check(read(grasp="none"))
    for bad in (read(m("stockpile", "aircraft_carrier", 10)), read(m("conquer")), read(*[m("scout")] * 4), read(m("scout"), grasp="sure"),
                {**read(), "tiers": {}}, {k: v for k, v in read().items() if k != "thinking"}, read({"kind": "scout"})):
        with pytest.raises(ValidationError):
            check(bad)

    assert reading(read(m("scout"), thinking="想" * 150)) == ("exact", "想" * 99 + "…", SAID["decision"], [m("scout")])
    for unusable in ({}, read(grasp="sure"), {**read(), "mandates": None}, read(thinking=" "), None):
        assert reading(unusable) is None


# ---------------------------------------------------------------------------- grounding: exact, approximate, guessed, impossible
@pytest.mark.parametrize("civ, age, said, mandates, notes", [
    # exact: the wording matches the catalog
    ("teutons", 2, [m("stockpile", "paladin", 50)], [("general", "stockpile", "paladin", 50, "normal")], []),
    ("chinese", 1, [m("worker_target", amount=40)], [("economy", "worker_target", None, 40, "normal")], []),
    ("chinese", 1, [m("boost_resource", "food", urgency="rush")], [("economy", "boost_resource", "food", None, "rush")], []),
    ("teutons", 2, [m("advance_age", amount=3, urgency="rush"), m("research", "cavalier")],
     [("tech", "advance_age", None, 3, "rush"), ("tech", "research", "cavalier", None, "normal")], []),
    ("chinese", 1, [m("fortify", urgency="rush"), m("scout"), m("attack")],
     [("defense", "fortify", None, None, "rush"), ("intel", "scout", None, None, "normal"), ("general", "attack", None, None, "normal")], []),
    # approximate: what this civilization cannot build becomes the nearest thing it can
    ("chinese", 2, [m("stockpile", "paladin", 50)], [("general", "stockpile", "cavalier", 50, "normal")], ["中国造不了游侠，改为重装骑士"]),
    ("chinese", 2, [m("stockpile", "teutonic_knight", 8)], [("general", "stockpile", "champion", 8, "normal")], ["中国造不了条顿武士，改为冠军剑士"]),
    ("teutons", 2, [m("stockpile", "arbalest", 12)], [("general", "stockpile", "crossbowman", 12, "normal")], ["条顿造不了劲弩手，改为弩手"]),
    ("chinese", 2, [m("research", "paladin")], [("tech", "research", "cavalier", None, "normal")], ["中国不能研究游侠，改为重装骑士"]),
    ("teutons", 2, [m("stockpile", "knight", 5000)], [("general", "stockpile", "knight", STOCKPILE_CAP, "normal")],
     [f"5000 个超过一次指令的上限，按 {STOCKPILE_CAP} 个执行"]),
    ("chinese", 1, [m("worker_target", amount=500)], [("economy", "worker_target", None, 60, "normal")], ["村民目标 500 超出范围，按 60 个执行"]),
    ("chinese", 1, [m("advance_age", amount=7)], [("tech", "advance_age", None, 3, "normal")], ["时代只到帝王时代，按帝王时代执行"]),
    # guessed: the model left the amount open
    ("teutons", 2, [m("stockpile", "knight")], [("general", "stockpile", "knight", 10, "normal")], ["没有说数量，先按 10 个"]),
    ("chinese", 1, [m("advance_age")], [("tech", "advance_age", None, 2, "normal")], []),
    # villagers are counted as a total, whatever kind the model chose
    ("chinese", 1, [m("stockpile", "villager", 30)], [("economy", "worker_target", None, 30, "normal")], []),
    # said twice in one order: the later wording stands
    ("teutons", 2, [m("hold"), m("stockpile", "knight", 5), m("attack"), m("stockpile", "knight", 9)],
     [("general", "attack", None, None, "normal"), ("general", "stockpile", "knight", 9, "normal")], []),
    ("teutons", 2, [m("stockpile", "knight", 5), m("hold"), m("stockpile", "knight", 9)],
     [("general", "hold", None, None, "normal"), ("general", "stockpile", "knight", 9, "normal")], []),
])
def test_an_interpretation_is_checked_against_the_catalog_and_repaired(civ, age, said, mandates, notes):
    grounded = ground(said, civ, age, order_origin(7))
    assert flat(grounded.mandates) == mandates and grounded.notes == notes and grounded.problems == []
    assert all(x.origin == "order#7" for x in grounded.mandates)


@pytest.mark.parametrize("civ, said, problem", [
    ("teutons", [m("stockpile", "chemistry", 5)], "stockpile 的 subject 必须是 names.units 里的 id，不能是 chemistry"),
    ("teutons", [m("stockpile", "", 5)], "stockpile 的 subject 必须是 names.units 里的 id，不能是 空"),
    ("teutons", [m("research", "knight")], "research 的 subject 必须是 names.techs 里的 id，不能是 knight"),
    ("teutons", [m("boost_resource", "knight")], "boost_resource 的 subject 必须是 food、wood、gold、stone 之一，不能是 knight"),
    ("teutons", [m("worker_target")], "worker_target 需要 amount：村民总数"),
    ("teutons", [m("stockpile", "camel", 5)], "条顿造不了 camel，也没有相近的兵种"),
    ("teutons", [m("research", "elite_chu_ko_nu")], "条顿不能研究 elite_chu_ko_nu，这条升级线上也没有能研究的"),
    ("teutons", [m("conquer")], "kind 'conquer' 不在允许的任务类型里"),
    ("teutons", ["attack"], "kind 'attack' 不在允许的任务类型里"),
])
def test_what_cannot_be_repaired_is_named_for_the_model(civ, said, problem):
    grounded = ground(said, civ, 2)
    assert grounded.mandates == [] and grounded.problems == [problem]


def test_at_most_three_mandates_and_an_upgrade_line_is_followed_to_its_end():
    said = [m("scout"), m("fortify"), m("attack"), m("advance_age", amount=2)]
    assert [x.kind for x in ground(said, "teutons", 1).mandates] == ["scout", "fortify", "attack"]
    assert ground("nonsense", "teutons", 1).mandates == []
    assert later_forms("knight") == {"cavalier", "paladin"} and later_forms("paladin") == set()
    assert later_forms("militia") == {"man_at_arms", "long_swordsman", "two_handed_swordsman", "champion"}


# ---------------------------------------------------------------------------- the ledger
def accepted(ledger, text, *mandates, now=0.0, window=None):
    """File an order and take a reading of it."""
    order = ledger.intake(window if window is not None else [*ledger.window, text][-4:], now)[-1]
    grounding = ground(list(mandates), "teutons", 2, ledger.origin(order))
    assert ledger.accept(order, "exact", "想", "办", grounding) == ACTIVE
    return order


def test_the_window_of_instructions_is_only_how_orders_arrive():
    ledger = OrderLedger()
    assert ledger.intake([], 0) == [] and ledger.pending() is None
    first, = ledger.intake(["多采黄金"], 1)
    assert (first.number, first.text, first.status, first.received_at) == (1, "多采黄金", NEW, 1.0) and ledger.pending() is first
    assert ledger.intake(["多采黄金"], 2) == []                                   # the same window again
    second, third = ledger.intake(["多采黄金", "造骑士", "造骑士"], 3)            # the same words twice are two orders
    assert (second.number, third.number) == (2, 3)
    fourth, fifth = ledger.intake(["造骑士", "造骑士", "进攻", "按兵不动"], 4)    # the first has slid out of the window
    assert [o.number for o in ledger.orders] == [1, 2, 3, 4, 5] and ledger.find(1) is first
    assert ledger.intake(["造骑士", "进攻", "按兵不动"], 5) == []                 # one dropped, none added
    assert [e["change"] for e in ledger.take_events()] == ["received"] * 5 and ledger.take_events() == []

    # The player clears the instructions: every order is cancelled.
    revision = ledger.revision
    assert ledger.intake([], 6) == [] and ledger.orders == [] and ledger.revision == revision + 1
    assert [(e["change"], e["reason"]) for e in ledger.take_events()] == [("cancelled", "cleared_by_player")] * 5
    again, = ledger.intake(["进攻"], 7)
    assert again.number == 6                                                      # numbers are never reused


def test_a_later_order_takes_the_place_of_an_earlier_one_where_they_conflict():
    ledger = OrderLedger()
    knights = accepted(ledger, "囤积十个骑士，先别出兵", m("stockpile", "knight", 10), m("hold"))
    swords = accepted(ledger, "再来八个长剑士", m("stockpile", "long_swordsman", 8))
    assert flat(ledger.mandates()) == [("general", "stockpile", "knight", 10, "normal"), ("general", "hold", None, None, "normal"),
                                       ("general", "stockpile", "long_swordsman", 8, "normal")]
    assert [x.origin for x in ledger.mandates()] == ["order#1", "order#1", "order#2"]

    attack = accepted(ledger, "进攻", m("attack"))
    assert [x.kind for x in knights.mandates] == ["stockpile"] and knights.status == ACTIVE     # only the halt was replaced
    more = accepted(ledger, "骑士要二十个", m("stockpile", "knight", 20))
    assert knights.status == SUPERSEDED and knights.mandates == [] and knights.label() == "已取代"
    assert flat(ledger.mandates()) == [("general", "stockpile", "long_swordsman", 8, "normal"), ("general", "attack", None, None, "normal"),
                                       ("general", "stockpile", "knight", 20, "normal")]
    assert [o.number for o in ledger.active()] == [swords.number, attack.number, more.number]
    assert ledger.rows() == [{"id": 2, "text": "再来八个长剑士", "status": "执行中"}, {"id": 3, "text": "进攻", "status": "执行中"},
                             {"id": 4, "text": "骑士要二十个", "status": "执行中"}]
    changes = [(e["change"], e["id"]) for e in ledger.take_events()]
    assert (SUPERSEDED, 1) in changes and changes.count(("interpreted", 4)) == 1
    assert slot(Mandate("general", "attack")) == slot(Mandate("general", "hold")) != slot(Mandate("general", "stockpile", "knight"))


def test_progress_is_kept_per_mandate_and_closes_the_order():
    ledger = OrderLedger()
    order = accepted(ledger, "囤积五十个游侠，升到帝王时代", m("stockpile", "paladin", 50), m("advance_age", amount=3))
    stockpile, age = order.mandates
    revision = ledger.revision
    ledger.record(order, stockpile, False, "12/50")
    ledger.record(order, age, False, "城堡时代")
    assert order.label() == "执行中 12/50" and ledger.revision == revision
    ledger.record(order, age, True, "帝王时代")
    assert order.status == ACTIVE and flat(ledger.mandates()) == [("general", "stockpile", "paladin", 50, "normal")]
    assert ledger.revision == revision + 1 and order.detail()["mandates"][1]["done"] is True
    ledger.record(order, stockpile, True, "50/50")
    assert order.status == DONE and ledger.mandates() == [] and ledger.rows() == [] and order.label() == "已完成"
    assert order.detail() == {"id": 1, "text": "囤积五十个游侠，升到帝王时代", "status": "已完成", "state": "done", "grasp": "exact",
                              "thinking": "想", "decision": "办", "mandates": [
                                  {"dept": "general", "kind": "stockpile", "urgency": "normal", "done": True, "subject": "paladin",
                                   "name": "游侠", "amount": 50},
                                  {"dept": "tech", "kind": "advance_age", "urgency": "normal", "done": True, "amount": 3}]}
    assert ledger.take_events()[-1]["change"] == DONE

    # Closed orders are kept for the panel, but not without end.
    for n in range(15):
        ledger.record(extra := accepted(ledger, f"升级{n}", m("advance_age", amount=3)), extra.mandates[0], True, "")
    ledger.prune()
    assert len(ledger.orders) == 12 and ledger.orders[-1].text == "升级14"


def test_a_reading_the_catalog_refuses_is_asked_for_once_more_and_then_given_up():
    ledger = OrderLedger()
    order, = ledger.intake(["造十个骆驼"], 0)
    refused = ground([m("stockpile", "camel", 10)], "teutons", 2, ledger.origin(order))
    assert ledger.accept(order, "exact", "想", "办", refused, [m("stockpile", "camel", 10)]) == "retry"
    assert order.status == NEW and ledger.pending() is order and order.grasp is None
    assert order.problem == "条顿造不了 camel，也没有相近的兵种" and order.refused == [m("stockpile", "camel", 10)]
    assert order.detail()["waiting"] == order.problem
    assert ledger.accept(order, "approx", "想", "办", refused) == IMPOSSIBLE
    assert (order.status, order.grasp, order.decision, order.notes) == (IMPOSSIBLE, "none", REFUSED, refused.problems)
    assert ledger.pending() is None and ledger.mandates() == [] and order.label() == "无法执行"

    # The model itself says it cannot be done: its words are kept, nothing is asked again.
    carrier, = ledger.intake(["造十个骆驼", "造10艘航母"], 1)
    assert ledger.accept(carrier, "none", "游戏里没有航母。", "这条办不了。", Grounding()) == IMPOSSIBLE
    assert (carrier.thinking, carrier.decision, carrier.tries) == ("游戏里没有航母。", "这条办不了。", 1)
    # A repaired reading is taken at the second try.
    knights, = ledger.intake(["造十个骆驼", "造10艘航母", "来点骑士"], 2)
    assert ledger.accept(knights, "guess", "想", "办", ground([m("research", "knight")], "teutons", 2)) == "retry"
    assert ledger.accept(knights, "guess", "想", "办", ground([m("stockpile", "knight")], "teutons", 2, "order#3")) == ACTIVE
    assert knights.notes == ["没有说数量，先按 10 个"] and knights.problem == "" and "waiting" not in knights.detail()


# ---------------------------------------------------------------------------- what an order needs first
def field(age=2, researched=(), buildings=("town_center", "barracks")):
    return SimpleNamespace(age=age, progression_enabled=True, buildings=[{"def_id": name, "is_complete": True} for name in buildings],
                           obs=SimpleNamespace(progression=Progression(age=age, researched_technologies={t: True for t in researched})))


def test_an_order_is_followed_by_what_it_needs_first():
    paladins = Mandate("general", "stockpile", "paladin", 50, "rush", "order#3")
    derived = derive([Mandate("economy", "worker_target", amount=30), paladins], field())
    assert [(x.dept, x.kind, x.subject, x.amount) for x in derived] == [
        ("economy", "worker_target", None, 30), ("general", "stockpile", "paladin", 50),
        ("tech", "advance_age", None, 3), ("tech", "research", "paladin", None), ("tech", "research", "cavalier", None),
        ("general", BUILD, "stable", None)]
    assert all((x.origin, x.urgency) == ("order#3", "rush") for x in derived[1:])
    assert needs_of(paladins, field()) == ("age_3", "research:paladin", "build:stable")
    # Each need falls away as it is met.
    ready = field(3, ("cavalier", "paladin"), ("town_center", "stable"))
    assert derive([paladins], ready) == [paladins] and needs_of(paladins, ready) == ()
    assert needs_of(paladins, field(3, ("cavalier",), ("stable",))) == ("research:paladin",)

    chemistry = Mandate("tech", "research", "bombard_tower", origin="order#4")
    assert [(x.dept, x.kind, x.subject or x.amount) for x in derive([chemistry], field())] == [
        ("tech", "research", "bombard_tower"), ("tech", "advance_age", 3), ("tech", "research", "chemistry"), ("tech", BUILD, "university")]
    # Two orders that need the same thing ask for it once; standing mandates are left to the departments.
    both = derive([paladins, Mandate("general", "stockpile", "cavalier", 5, origin="order#5")], field())
    assert [x.kind for x in both].count("advance_age") == 1 and [x.subject for x in both].count("stable") == 1
    standing = Mandate("general", "stockpile", "paladin", 6)
    assert derive([standing], field()) == [standing]
    unknown = Mandate("general", "stockpile", "swordsman", 3, origin="policy#1")       # a profile's name the catalog does not know
    assert derive([unknown], field()) == [unknown]


def test_how_far_a_mandate_has_got():
    f = field(2, ("cavalier",))
    f.units = [unit(1), unit(2), unit(3, "knight"), unit(4, "cavalier"), unit(5, "paladin"), unit(6, "militia")]
    engine = SimpleNamespace(goals={"sortie_departed": None})
    assert progress(Mandate("general", "stockpile", "knight", 3), f, engine) == (True, "3/3")       # its later forms count too
    assert progress(Mandate("general", "stockpile", "cavalier", 3), f, engine) == (False, "2/3")    # its earlier form does not
    assert progress(Mandate("general", "stockpile", None, 5), f, engine) == (False, "4/5")          # any soldier, no villager
    assert progress(Mandate("economy", "worker_target", None, 2), f, engine) == (True, "2/2")
    assert progress(Mandate("tech", "advance_age", None, 3), f, engine) == (False, "城堡时代")
    assert progress(Mandate("tech", "advance_age", None, 2), f, engine)[0]
    assert progress(Mandate("tech", "research", "cavalier"), f, engine)[0] and not progress(Mandate("tech", "research", "paladin"), f, engine)[0]
    assert progress(Mandate("general", BUILD, "barracks"), f, engine)[0] and not progress(Mandate("general", BUILD, "stable"), f, engine)[0]
    for standing in ("hold", "fortify", "scout", "boost_resource"):
        assert progress(Mandate("x", standing), f, engine) == (False, "")
    # An attack is carried out by a sortie that left after it was ordered, not by one already out.
    attack = Mandate("general", "attack")
    assert not progress(attack, f, engine, since=10)[0]
    engine.goals["sortie_departed"] = 5.0
    assert not progress(attack, f, engine, since=10)[0] and progress(attack, f, engine, since=5)[0]


def test_a_request_carries_the_origin_of_the_mandate_it_serves():
    dept = Department(SimpleNamespace(now=0.0, roles={}), Treasury())
    dept.name = "economy"
    order = Mandate("economy", "worker_target", amount=40, urgency="rush", origin="order#2")
    standing = Mandate("economy", "worker_target", amount=20)
    assert dept.mine([order, standing, Mandate("tech", "research", "cavalier")]) == [order, standing]
    dept.serve(("unit", "villager"), order)
    dept.serve(("building", "house"), standing)              # a standing mandate marks nothing
    assert dept.served == {("unit", "villager"): order}
    dept.begin()
    villager = dept.want(("unit", "villager"), "villager", {"food": 50}, urgency=1)
    house = dept.want(("building", "house"), "house", {"wood": 30}, urgency=1)
    assert (villager.origin, villager.urgency) == ("order#2", 3) and (house.origin, house.urgency) == ("routine", 1)
    # The next tick starts from nothing: an order that has gone no longer marks the request.
    dept.mine([standing])
    dept.begin()
    assert dept.served == {} and dept.want(("unit", "villager"), "villager", {"food": 50}, urgency=1).origin == "routine"


# ---------------------------------------------------------------------------- the policy script
def test_a_policy_script_is_checked_when_it_is_loaded():
    script = load_policy([{"when": "start", "dept": "economy", "kind": "worker_target", "amount": 24},
                          {"when": "age>=2", "dept": "general", "kind": "stockpile", "subject": "knight", "amount": 12},
                          {"when": "done:2", "kind": "attack"}], "teutons")
    assert [(e["when"], e["number"], e["mandate"].origin) for e in script] == [("start", 1, "policy#1"), ("age>=2", 2, "policy#2"),
                                                                              ("done:2", 3, "policy#3")]
    assert flat([e["mandate"] for e in script])[1] == ("general", "stockpile", "knight", 12, "normal")
    assert load_policy([], "teutons") == load_policy(None, "teutons") == []

    for bad, why in [({"when": "soon", "kind": "attack"}, "when must be"), ({"kind": "attack"}, "when must be"),
                     ({"when": "done:1", "kind": "attack"}, "must name an earlier entry"),
                     ({"when": "start", "dept": "economy", "kind": "attack"}, "attack is not a task of economy"),
                     ({"when": "start", "kind": "stockpile", "subject": "paladin", "amount": 5}, "改为"),
                     ({"when": "start", "kind": "stockpile", "subject": "dragon", "amount": 5}, "names.units"),
                     ({"when": "start", "kind": "worker_target", "amount": 500}, "超出范围"), ("attack", "when must be")]:
        with pytest.raises(ValueError, match=why):
            load_policy([bad], "chinese")


def test_policy_entries_come_due_at_the_start_at_an_age_and_after_another():
    script = load_policy([{"when": "start", "kind": "worker_target", "amount": 24},
                          {"when": "age>=2", "kind": "stockpile", "subject": "knight", "amount": 12},
                          {"when": "done:2", "kind": "attack"}], "teutons")
    due = lambda age, done: [e["number"] for e in policy_entries(script, age, done)]
    assert due(0, set()) == [1] and due(2, set()) == [1, 2] and due(3, {1}) == [2]
    assert due(2, {2}) == [1, 3] and due(1, {2}) == [1, 3] and due(3, {1, 2, 3}) == []


POLICY = ({"when": "start", "kind": "worker_target", "amount": 24},
          {"when": "age>=1", "kind": "stockpile", "subject": "militia", "amount": 4},
          {"when": "done:2", "kind": "attack"})


def scripted(policy=POLICY, civ="teutons"):
    """A cabinet whose profile carries a policy script."""
    runtime = CabinetRuntime(civ)
    runtime.field.validator.profile = CivAiProfile(civ_id=civ, national_policy=tuple(policy))
    return runtime


def test_a_team_without_a_player_follows_its_policy_script():
    runtime = scripted()

    def tick(number, age, soldiers):
        req = stocked(frame(number, entities=town(12, building(3, "mill"), *army(soldiers)), time=number * 10), food=400, gold=200)
        req.observation.progression = Progression(age=age)
        return runtime.tick(req)

    dark = tick(1, 0, 0)
    assert runtime.mandates == []                            # the script stands in for the profile's old targets
    assert flat(runtime.in_force) == [("economy", "worker_target", None, 24, "normal")]
    assert runtime.field.roles["economy"].plan["worker_target"] == 24
    villagers = requests(dark, "economy")["villager"]
    assert villagers["origin"] == "policy#1" and villagers["tier"] != "now"     # the script is standing policy, not a player's order

    feudal = tick(2, 1, 2)
    assert [x.kind for x in runtime.in_force] == ["worker_target", "stockpile"]
    militia = requests(feudal, "general")["militia"]
    assert militia["origin"] == "policy#2" and militia["tier"] != "now"
    # Four militia stand: the second entry is carried out, and the third comes due.
    tick(3, 1, 4)
    assert runtime.policy_done == {2}
    tick(4, 1, 4)
    assert [x.kind for x in runtime.in_force] == ["worker_target", "attack"] and runtime.general.stance == "attack"
    assert runtime.field.roles["commander"].plan["stance"] == "pressure"


def test_a_script_is_read_from_the_civilization_profile(tmp_path, monkeypatch):
    policy = [{"when": "start", "dept": "economy", "kind": "worker_target", "amount": 16},
              {"when": "done:1", "dept": "general", "kind": "attack"}]
    (tmp_path / "profile_teutons.json").write_text(json.dumps({"civ_id": "teutons", "national_policy": policy}), encoding="utf-8")
    monkeypatch.setattr(profile_loader, "_DATA_DIR", tmp_path)
    monkeypatch.setattr(profile_loader, "_CACHE", {})
    runtime = CabinetRuntime("teutons")
    runtime.tick(frame(1))
    assert [(entry["when"], entry["mandate"].kind, entry["mandate"].origin) for entry in runtime.policy] == [
        ("start", "worker_target", "policy#1"), ("done:1", "attack", "policy#2")]
    assert runtime.mandates == [] and flat(runtime.in_force) == [("economy", "worker_target", None, 16, "normal")]


def test_a_profile_without_a_script_keeps_its_old_targets_and_a_bad_script_stops_the_match_at_once():
    assert profile_for_id("teutons").national_policy == ()
    plain = CabinetRuntime("teutons")
    plain.tick(frame(1))
    assert plain.policy == [] and plain.mandates == default_mandates(plain.field.validator.profile)

    with pytest.raises(ValueError, match="national_policy entry 1"):
        scripted(({"when": "start", "kind": "stockpile", "subject": "dragon", "amount": 5},)).tick(frame(1))


# ---------------------------------------------------------------------------- inside the runtime
PALADINS = read(m("stockpile", "paladin", 50, "rush"))


def castle_town(runtime, extra=(), technologies=("cavalier",)):
    """A castle-age Teuton town with a stable; `tick(number, orders, ...)` sends one observation."""
    def tick(number, orders=(), age=2, researched=(), soldiers=3, now=None, stable=True, **stock):
        stables = [building(4, "stable", technologies=[{"id": name, "reason": ""} for name in technologies])] if stable else []
        entities = town(30, building(3, "mill"), *stables, *army(soldiers), *extra, tc={"age_upgrade_reason": ""})
        req = stocked(frame(number, entities=entities, time=number * 10 if now is None else now), **(stock or {"each": 400}))
        req.observation.decision_context["catalog"]["buildings"] += [
            {"id": name, **CATALOG["buildings"][name], "available": True} for name in ("stable", "university")]
        req.observation.player_instructions = list(orders)
        req.observation.progression = Progression(age=age, researched_technologies={t: True for t in researched})
        req.observation.decision_context["catalog"]["age_upgrade"] = {"cost": {"food": 1000, "gold": 800}, "buildings": ["mill", "stable"],
                                                                     "required_distinct_buildings": 2}
        return runtime.tick(req)
    return tick


def ordered(runtime, tick, text, answer, number=1, **town_state):
    """Send an order, let the model's reading in, and return the next tick's result."""
    tick(number, [text], **town_state)
    assert runtime.planning_brief("premier_orders")["context"]["order"] == text
    assert runtime.apply_plan("premier_orders", answer)
    return tick(number + 1, [text], **town_state)


def test_a_new_order_is_put_to_the_model_at_once_and_its_reading_becomes_mandates():
    runtime = cabinet("teutons")
    tick = castle_town(runtime)
    assert runtime.planning_roles == ("premier", "premier_orders")
    tick(1)
    assert runtime.planning_interval("premier_orders") == math.inf and runtime.planning_brief("premier_orders") is None

    waiting = tick(2, ["囤积50个游侠"])
    assert runtime.planning_interval("premier_orders") == 0  # not asked yet: no pause at all
    assert waiting["planning"]["orders"] == [{"id": 1, "text": "囤积50个游侠", "status": "新下达"}]
    assert waiting["agent_status"]["premier"]["orders"] == [{"id": 1, "text": "囤积50个游侠", "status": "新下达", "state": "new"}]
    brief = runtime.planning_brief("premier_orders")
    assert (brief["system"], brief["schema"], brief["output_tokens"], brief["player_orders"]) == (INTERPRET_PROMPT, interpret_schema(), 512, False)
    assert brief["context"] == interpret_context("囤积50个游侠", [], "teutons", 2)
    context = runtime.planning_context("premier_orders")
    assert context["plan"] == {} and context["plan_version"] == runtime.ledger.revision

    assert not runtime.apply_plan("premier_orders", {"grasp": "exact"})          # not a reading at all
    assert runtime.apply_plan("premier_orders", PALADINS)
    assert not runtime.apply_plan("premier_orders", PALADINS)                    # the same answer twice changes nothing
    assert runtime.planning_interval("premier_orders") == math.inf and runtime.planning_context("premier_orders")["plan_version"] == 1

    result = tick(3, ["囤积50个游侠"])
    assert [(x.dept, x.kind, x.subject or x.amount, x.origin, x.urgency) for x in runtime.in_force] == [
        ("general", "stockpile", "paladin", "order#1", "rush"), ("tech", "advance_age", 3, "order#1", "rush"),
        ("tech", "research", "paladin", "order#1", "rush"), ("tech", "research", "cavalier", "order#1", "rush")]
    # The unit nothing can train yet stays on the books, blocked; what it needs is asked for under the same order.
    parent, age, cavalier = requests(result, "general")["paladin"], requests(result, "tech")["age_3"], requests(result, "tech")["cavalier"]
    assert (parent["needs"], parent["origin"], parent["tier"], parent["item"]) == (["age_3", "research:paladin"], "order#1", "now", "paladin x50")
    assert parent["held"] == {} and parent["price"] == {"food": 3000.0, "gold": 3750.0}
    assert (age["origin"], age["tier"], age["urgency"]) == ("order#1", "now", 3) and (cavalier["origin"], cavalier["tier"]) == ("order#1", "now")
    assert "cavalier" in bought(result)                      # research an order asked for is not held to the rule of plenty
    assert result["planning"]["orders"] == [{"id": 1, "text": "囤积50个游侠", "status": "执行中 0/50"}]
    detail, = result["agent_status"]["premier"]["orders"]
    assert (detail["grasp"], detail["thinking"], detail["decision"]) == ("exact", SAID["thinking"], SAID["decision"])
    assert detail["mandates"] == [{"dept": "general", "kind": "stockpile", "urgency": "rush", "done": False, "subject": "paladin",
                                   "name": "游侠", "amount": 50}]
    # The ranking call is told about the order, and a change in the ledger is worth asking about sooner.
    assert runtime.planning_brief("premier")["context"]["orders"] == [{"id": 1, "text": "囤积50个游侠", "status": "执行中 0/50"}]
    assert runtime.planning_interval("premier") == 45
    runtime.ledger.revision += 1                             # as when a mandate is carried out or an order replaced
    assert runtime.planning_interval("premier") == 20
    journal = [entry for kind, entry in runtime.take_journal() if kind == "order"]
    assert [(e["change"], e["id"]) for e in journal] == [("received", 1), ("interpreted", 1)]


def test_research_an_order_asked_for_goes_before_the_routine_upgrade():
    grown = dict(soldiers=24, each=5000, age=3)              # the last age, an army in the field, plenty in stock: routine research is on
    routine = cabinet("teutons")
    assert "long_swordsman" in bought(castle_town(routine, technologies=("long_swordsman", "pikeman"))(1, **grown))

    runtime = cabinet("teutons")
    tick = castle_town(runtime, technologies=("long_swordsman", "pikeman"))
    tick(1, ["研究长枪兵"], soldiers=24, each=10, age=3)      # too poor for anything while the order is read
    runtime.planning_brief("premier_orders")
    assert runtime.apply_plan("premier_orders", read(m("research", "pikeman")))
    result = tick(2, ["研究长枪兵"], **grown)
    assert "pikeman" in bought(result) and "long_swordsman" not in bought(result)
    assert requests(result, "tech")["pikeman"]["origin"] == "order#1" and "long_swordsman" not in requests(result, "tech")


def test_two_orders_after_the_same_resource_the_later_one_goes_first():
    ask = lambda rid, number, **price: Request(rid, "general", ("unit", rid), rid, remaining=price, tranche=price, origin=order_origin(number))
    knights, wall, scouts = ask("knights", 1, food=600, gold=750), ask("wall", 2, wood=40), ask("camels", 3, food=550, gold=600)
    routine = Request("militia", "general", ("unit", "militia"), "militia", remaining={"food": 60}, tranche={"food": 60})
    tiers = default_tiers([knights, wall, scouts, routine], IntelBrief())
    # The first order shares food and gold with the third; the second wants only wood and competes with nobody.
    assert tiers == {"knights": "next", "wall": "now", "camels": "now", "militia": "later"}


def test_an_order_for_an_age_takes_its_whole_price_and_is_done_when_the_age_is_reached():
    runtime = cabinet("teutons")
    tick = castle_town(runtime, technologies=())
    saving = ordered(runtime, tick, "尽快升帝王时代", read(m("advance_age", amount=3, urgency="rush")))
    age = requests(saving, "tech")["age_3"]
    assert (age["origin"], age["tier"], age["held"]) == ("order#1", "now", {"food": 400.0, "gold": 400.0})   # no instalments: all there is
    assert runtime.field.roles["technology"].plan["target_age"] == 3
    reached = tick(3, ["尽快升帝王时代"], age=3)
    assert reached["planning"]["orders"] == [] and runtime.ledger.orders[0].status == DONE
    assert reached["agent_status"]["premier"]["orders"][0]["status"] == "已完成"

    # An order for an age never lowers how far the plan means to go: not while it is carried out,
    feudal = cabinet("teutons")
    ordered(feudal, castle_town(feudal, technologies=()), "升到城堡时代", read(m("advance_age", amount=2)), age=1)
    assert feudal.field.roles["technology"].plan["target_age"] == 3 and feudal.ledger.orders[0].status == ACTIVE
    # and not when the age it names is already behind.
    tick(4, ["尽快升帝王时代", "升到封建时代"], age=3)
    runtime.planning_brief("premier_orders")
    assert runtime.apply_plan("premier_orders", read(m("advance_age", amount=1)))
    tick(5, ["尽快升帝王时代", "升到封建时代"], age=3)
    assert runtime.field.roles["technology"].plan["target_age"] == 3 and runtime.ledger.orders[1].status == DONE


def test_villagers_a_resource_walls_and_scouting_can_be_ordered_and_given_back():
    runtime = cabinet("teutons", mandates=[Mandate("economy", "worker_target", amount=20)])
    tick = castle_town(runtime)
    plans = runtime.field.roles
    tick(1)
    before = (plans["economy"].plan["worker_target"], plans["defense"].plan["policy"], dict(plans["scout"].plan))
    assert before[:2] == (20, "balanced")

    said = read(m("worker_target", amount=40), m("boost_resource", "gold", urgency="rush"), m("fortify"))
    result = ordered(runtime, tick, "村民补到40个，多采黄金，加紧修墙", said, number=2)
    villagers = requests(result, "economy")["villager"]
    assert (villagers["origin"], villagers["tier"], villagers["item"]) == ("order#1", "now", "villager x10")
    assert plans["economy"].plan["worker_target"] == 40 and plans["defense"].plan["policy"] == "fortify"
    assert runtime.field.demands["gold"] >= 1500             # the gatherers are pointed at what was asked for
    assert flat(runtime.in_force) == [("economy", "worker_target", None, 40, "normal"), ("economy", "boost_resource", "gold", None, "rush"),
                                      ("defense", "fortify", None, None, "normal")]       # the standing target gave way
    text = "村民补到40个，多采黄金，加紧修墙"
    tick(4, [text, "查清敌人兵力"])
    assert runtime.planning_brief("premier_orders")["context"]["orders"] == [{"id": 1, "text": text, "status": "执行中 30/40"}]
    assert runtime.apply_plan("premier_orders", read(m("scout")))
    tick(5, [text, "查清敌人兵力"])
    assert (plans["scout"].plan["scout_count"], plans["scout"].plan["revisit_seconds"]) == (2, 30)

    # The player clears the instructions: the orders are gone and what they changed is given back.
    cleared = tick(6, [])
    assert cleared["planning"]["orders"] == [] and cleared["agent_status"]["premier"]["orders"] == []
    assert (plans["economy"].plan["worker_target"], plans["defense"].plan["policy"], dict(plans["scout"].plan)) == before
    assert flat(runtime.in_force) == [("economy", "worker_target", None, 20, "normal")]
    assert requests(cleared, "economy").get("villager", {"origin": "routine"})["origin"] == "routine"
    assert runtime.field.demands["gold"] < 1500


def test_a_building_an_order_needs_is_asked_for_by_the_department_that_builds_it():
    runtime = cabinet("teutons")
    tick = castle_town(runtime)
    result = ordered(runtime, tick, "造十个骑士", read(m("stockpile", "knight", 10)), stable=False)
    assert ("general", BUILD, "stable", "order#1") in [(x.dept, x.kind, x.subject, x.origin) for x in runtime.in_force]
    stable, knights = requests(result, "general")["stable"], requests(result, "general")["knight"]
    assert (stable["origin"], stable["tier"], stable["urgency"]) == ("order#1", "now", 2)
    assert (knights["needs"], knights["origin"], knights["item"]) == (["build:stable"], "order#1", "knight x10")

    study = cabinet("teutons")
    result = ordered(study, castle_town(study), "研究化学", read(m("research", "chemistry", urgency="rush")), age=3)
    assert ("tech", BUILD, "university", "order#1") in [(x.dept, x.kind, x.subject, x.origin) for x in study.in_force]
    university = requests(result, "tech")["university"]
    assert (university["origin"], university["tier"], university["urgency"]) == ("order#1", "now", 3) and "university" not in requests(result, "general")


def test_an_order_to_fortify_marks_the_wall_request():
    def town_of(runtime):
        def tick(number, orders=(), wood=500):
            req = stocked(defense_frame(number, threat=False), food=500, wood=wood)
            req.observation.player_instructions = list(orders)
            return runtime.tick(req)
        return tick

    routine, = town_of(cabinet("chinese"))(1)["agent_status"]["defense"]["requests"]
    assert (routine["origin"], routine["tier"], routine["urgency"]) == ("routine", "later", 1)

    runtime = cabinet("chinese")
    tick = town_of(runtime)
    tick(1, ["加紧修墙"], wood=0)                              # no wood yet: nothing is laid before the order is read
    runtime.planning_brief("premier_orders")
    assert runtime.apply_plan("premier_orders", read(m("fortify", urgency="rush")))
    wall, = tick(2, ["加紧修墙"])["agent_status"]["defense"]["requests"]
    assert (wall["origin"], wall["tier"], wall["urgency"], wall["item"]) == ("order#1", "now", 3, routine["item"])


def test_an_order_to_hold_keeps_the_army_home_and_an_order_to_attack_sends_it():
    runtime = cabinet("teutons")
    tick = castle_town(runtime, extra=[enemy_tc()])
    engine = runtime.field
    tick(1)                                                  # three soldiers: too few to leave on their own
    halted = ordered(runtime, tick, "按兵不动", read(m("hold")), number=2)
    assert engine.hold_army and runtime.general.stance == "hold" and engine.roles["commander"].plan["stance"] == "defend"
    for number in range(4, 30):                              # far past any muster timeout, with more soldiers than a sortie needs
        tick(number, ["按兵不动"], soldiers=8, now=number * 10)
    assert engine.goals["sortie_departed"] is None and halted["planning"]["orders"] == [{"id": 1, "text": "按兵不动", "status": "执行中"}]

    tick(30, ["按兵不动", "进攻"], soldiers=8, now=300)
    runtime.planning_brief("premier_orders")
    assert runtime.apply_plan("premier_orders", read(m("attack")))
    tick(31, ["按兵不动", "进攻"], soldiers=8, now=310)
    assert not engine.hold_army and runtime.general.stance == "attack" and engine.roles["commander"].plan["stance"] == "pressure"
    assert runtime.ledger.orders[0].status == SUPERSEDED
    tick(32, ["按兵不动", "进攻"], soldiers=8, now=320)
    assert engine.goals["sortie_departed"] is not None
    # The army has left: the order is carried out, and the stance is the premier's again.
    done = tick(33, ["按兵不动", "进攻"], soldiers=8, now=330)
    assert runtime.ledger.orders[1].status == DONE and runtime.general.stance is None
    assert done["planning"]["orders"] == [] and engine.roles["commander"].plan["stance"] == "balanced"

    # A halt while the army is out calls it back.
    tick(34, ["按兵不动", "进攻", "撤回来"], soldiers=8, now=340)
    runtime.planning_brief("premier_orders")
    assert runtime.apply_plan("premier_orders", read(m("hold")))
    tick(35, ["按兵不动", "进攻", "撤回来"], soldiers=8, now=350)
    assert engine.goals["phase"] == "retreat" and engine.roles["combat"].memory["retreat_until"] > 350


def test_an_attack_order_leaves_with_what_is_ready():
    runtime = cabinet("teutons")
    tick = castle_town(runtime, extra=[enemy_tc()])
    tick(1, soldiers=3)
    assert runtime.field.goals["sortie_target"] > 3
    ordered(runtime, tick, "进攻", read(m("attack")), number=2)
    tick(4, ["进攻"], soldiers=3)
    assert runtime.field.goals["sortie_target"] == 2 and runtime.field.goals["sortie_departed"] is not None


def test_a_reading_the_catalog_refuses_is_put_to_the_model_again_with_the_reason():
    runtime = cabinet("teutons")
    tick = castle_town(runtime)
    tick(1, ["造十个骆驼"])
    runtime.planning_brief("premier_orders")
    assert not runtime.apply_plan("premier_orders", read(m("stockpile", "camel", 10)))
    assert runtime.planning_interval("premier_orders") == 5
    again = runtime.planning_brief("premier_orders")["context"]
    assert runtime.planning_interval("premier_orders") == 10
    assert again["previous"] == {"mandates": [m("stockpile", "camel", 10)], "problem": "条顿造不了 camel，也没有相近的兵种"}
    # No mandate at all is a problem too, unless the model says the order cannot be carried out.
    assert runtime.apply_plan("premier_orders", read())
    refused = tick(2, ["造十个骆驼"])["agent_status"]["premier"]["orders"][0]
    assert (refused["state"], refused["grasp"], refused["decision"]) == ("impossible", "none", REFUSED)
    assert refused["notes"] == ["grasp 不是 none 时，mandates 里至少要有一条任务书"] and runtime.in_force == []

    tick(3, ["造十个骆驼", "今天天气怎么样"])
    runtime.planning_brief("premier_orders")
    assert runtime.apply_plan("premier_orders", read(m("attack"), grasp="none", thinking="这和对局无关。", decision="这条不执行。"))
    chat = tick(4, ["造十个骆驼", "今天天气怎么样"])["agent_status"]["premier"]["orders"][1]
    assert (chat["state"], chat["decision"]) == ("impossible", "这条不执行。") and "mandates" not in chat and runtime.in_force == []


def test_an_order_nobody_reads_says_why_and_is_asked_about_less_and_less_often():
    runtime = cabinet("teutons")
    tick = castle_town(runtime)
    entry = lambda result: result["agent_status"]["premier"]["orders"][0]
    tick(1, ["进攻"], now=100)
    assert "waiting" not in entry(tick(2, ["进攻"], now=114))
    unread = entry(tick(3, ["进攻"], now=115))
    assert (unread["state"], unread["waiting"]) == ("new", UNREAD)                 # no model was ever asked
    pauses = []
    for _ in range(6):
        runtime.planning_brief("premier_orders")
        assert not runtime.apply_plan("premier_orders", {"nonsense": True})       # asked, and nothing usable came back
        pauses.append(runtime.planning_interval("premier_orders"))
    assert pauses == [5, 10, 20, 40, 60, 60]
    assert entry(tick(4, ["进攻"], now=120))["waiting"] == UNANSWERED
    runtime.planning_brief("premier_orders")
    assert runtime.apply_plan("premier_orders", read(m("attack")))
    read_now = entry(tick(5, ["进攻"], now=130))
    assert read_now["state"] == "active" and "waiting" not in read_now


def test_a_finished_match_reads_no_more_orders():
    runtime = cabinet("teutons")
    castle_town(runtime)(1, ["进攻"])
    runtime.field.goals["match_over"] = True
    assert runtime.planning_brief("premier_orders") is None and not runtime.apply_plan("premier_orders", read(m("attack")))


# ---------------------------------------------------------------------------- through the service
def test_the_service_has_the_model_read_an_order_while_the_ranking_goes_on(monkeypatch):
    sent, logs = [], []

    def forward(plan_req):
        sent.append(plan_req)
        if plan_req.metadata.agent == "premier_orders":
            return completion(json.dumps(read(m("worker_target", amount=40)), ensure_ascii=False))
        shown = plan_req.tools[0].function.parameters["properties"]["tiers"]["required"]
        return completion(json.dumps({"thinking": "想", "decision": "办", "tiers": {rid: "next" for rid in shown}, "posture": "balanced"}))

    service = cabinet_service(monkeypatch, forward, log=lambda event, data: logs.append((event, data)))

    def tick(seq, orders):
        req = tick_request(seq, backend="openai")
        req.observation.player_instructions = list(orders)
        return service.tick(req)

    try:
        tick(1, [])
        assert [job[1][2] for job in service._pool.jobs] == ["premier"]          # no order, nothing to read
        service._pool.finish()
        waiting = tick(2, ["村民补到40个"])
        assert waiting["planning"]["premier_orders"]["state"] == "planning"
        service._pool.finish()
        taken = tick(3, ["村民补到40个"])
        retried = tick(3, ["村民补到40个"])
        after = tick(4, ["村民补到40个"])
    finally:
        service.shutdown()

    call = next(req for req in sent if req.metadata.agent == "premier_orders")
    assert call.messages[0].content.startswith(INTERPRET_PROMPT) and len(call.messages) == 2      # the order travels in the context
    assert json.loads(call.messages[1].content)["order"] == "村民补到40个" and call.metadata.plan_output_tokens == 512
    assert call.tools[0].function.parameters == interpret_schema()
    assert taken["planning"]["premier_orders"]["state"] == "applied"
    assert taken["planning"]["orders"] == [{"id": 1, "text": "村民补到40个", "status": "执行中 3/40"}]
    assert requests(taken, "economy")["villager"]["origin"] == "order#1"
    changes = [data["change"] for event, data in logs if event == "order"]
    assert changes == ["received", "interpreted"]
    result = next(data for event, data in logs if event == "model_result" and data["agent"] == "premier_orders")
    assert result["state"] == "applied" and result["plan"]["grasp"] == "exact"
    # The premier's answer travels to the game with the response that follows the reading, and only with that one.
    answer = [line for line in taken["planning"]["broadcasts"] if line["trigger"] == "order"]
    assert [(line["kind"], line["text"], line["order"], line["about"]) for line in answer] == [
        ("thinking", SAID["thinking"], 1, "村民补到40个"), ("decision", SAID["decision"], 1, "村民补到40个")]
    assert retried["planning"]["broadcasts"] == taken["planning"]["broadcasts"] and "broadcasts" not in after["planning"]
    said = [data for event, data in logs if event == "broadcast" and data["trigger"] == "order"]
    assert len(said) == 1 and said[0]["order"] == 1 and said[0]["after_wall_sec"] >= 0 and said[0]["lines"] == 2
