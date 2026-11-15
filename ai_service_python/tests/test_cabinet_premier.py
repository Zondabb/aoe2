"""Phase 3 of the cabinet architecture: a model ranks the requests, the rule book stands behind it."""
from __future__ import annotations

import json
import math

from jsonschema import Draft202012Validator, ValidationError
import pytest

from brain.cabinet.models import IntelBrief, order_origin
from brain.cabinet.premier import (DECISION_LIFETIME, RANK_PROMPT, RERANK_PAUSE, RERANK_ROUTINE, Premier, clip, rank_context,
                                   rank_schema)
from brain.multi_agent.scheduler import MultiAgentService
from brain.runtime_factory import create_runtime
from test_cabinet_runtime import bought, cabinet, requests, stocked, town
from test_cabinet_treasury import req
from test_llm_commander import building
from test_multi_agent_runtime import army, enemy_tc, frame
from test_multi_agent_scheduler import ControlledPool, completion, tick_request

SAID = {"thinking": "敌人还没露面，粮食只够一样。", "decision": "先补民兵，村民和农田往后放。"}


def decision(tiers, posture="balanced", **texts):
    return {**SAID, **texts, "tiers": dict(tiers), "posture": posture}


# ---------------------------------------------------------------------------- the premier alone
def test_a_model_decision_ranks_what_it_named_and_the_rule_book_ranks_the_rest():
    premier, brief = Premier(), IntelBrief(threat_level=1)
    camp = req("economy-1", {"wood": 100}, urgency=2)
    militia = req("general-1", {"food": 60, "gold": 20}, urgency=1)
    loom = req("tech-1", {"gold": 50}, urgency=1)

    assert premier.rank([camp, militia, loom], brief, 0) == {"economy-1": "next", "general-1": "later", "tech-1": "later"}
    assert (premier.source, premier.posture, premier.reason) == ("rules", "balanced", "default_ranking_rules")

    # The model spoke about two requests, one of which closed while it was thinking.
    assert premier.decide(decision({"general-1": "now", "economy-1": "hold", "defense-4": "now"}, "pressure"), [camp, militia, loom], 10)
    assert premier.decision["ignored"] == ["defense-4"] and premier.version == 1
    wall = req("defense-5", {"stone": 100}, urgency=2)          # filed after the model was asked
    assert premier.rank([camp, militia, loom, wall], brief, 11) == {
        "economy-1": "hold", "general-1": "now", "tech-1": "later", "defense-5": "next"}
    assert (premier.source, premier.posture, premier.reason) == ("model", "pressure", "model_ranking")
    status = premier.status(now=11)
    assert (status["thinking"], status["decision"], status["decided_at"]) == (SAID["thinking"], SAID["decision"], 10.0)


def test_no_model_ranking_puts_a_protected_request_below_next():
    premier, attacked = Premier(), IntelBrief(threat_level=3)
    house = req("economy-1", {"wood": 30}, floor=True)
    guard = req("general-1", {"food": 60}, emergency=True)
    wall = req("defense-1", {"stone": 100})
    assert premier.decide(decision({"economy-1": "hold", "general-1": "later", "defense-1": "hold"}), [house, guard, wall], 0)

    assert premier.rank([house, guard, wall], attacked, 1) == {"economy-1": "next", "general-1": "next", "defense-1": "hold"}
    # Without the attack the guard is an ordinary request again.
    assert premier.rank([house, guard, wall], IntelBrief(threat_level=2), 2)["general-1"] == "later"


def test_a_decision_nobody_renews_hands_back_to_the_rule_book():
    premier, brief = Premier(), IntelBrief()
    militia = req("general-1", {"food": 60}, urgency=1)
    premier.decide(decision({"general-1": "now"}, "defend"), [militia], 100)

    assert premier.rank([militia], brief, 100 + DECISION_LIFETIME) == {"general-1": "now"} and premier.posture == "defend"
    assert premier.plan(100 + DECISION_LIFETIME)["tiers"] == {"general-1": "now"}
    assert premier.rank([militia], brief, 100.5 + DECISION_LIFETIME) == {"general-1": "later"}
    assert (premier.source, premier.posture, premier.reason) == ("rules", "balanced", "model_decision_expired")
    assert "thinking" not in premier.status(now=100.5 + DECISION_LIFETIME)
    assert premier.plan(100.5 + DECISION_LIFETIME) == {"tiers": {}, "posture": "balanced"}
    # A new decision is taken as readily as the first.
    assert premier.decide(decision({"general-1": "next"}), [militia], 400) and premier.rank([militia], brief, 401) == {"general-1": "next"}
    assert premier.version == 2


@pytest.mark.parametrize("plan", [
    None, [], {"tiers": {"general-1": "now"}, "posture": "balanced"},                       # no texts
    decision([("general-1", "now")]) | {"tiers": [["general-1", "now"]]},                   # tiers not an object
    decision({"general-1": "soon"}), decision({"general-1": "now"}, "attack"),              # unknown tier, unknown posture
    decision({"general-1": "now"}, thinking="  "), decision({"general-1": "now"}, decision=7),
    decision({"defense-9": "now"}), decision({}),                                           # names nothing that is open
])
def test_a_malformed_decision_is_refused_and_changes_nothing(plan):
    premier = Premier()
    militia = req("general-1", {"food": 60}, urgency=1)

    assert not premier.decide(plan, [militia], 5)
    assert premier.decision is None and premier.version == 0
    assert premier.rank([militia], IntelBrief(), 6) == {"general-1": "later"} and premier.source == "rules"


def test_the_texts_for_the_player_are_cut_to_what_can_be_read_out():
    assert clip("  敌军\n只有少量骑士。  ", 100) == "敌军 只有少量骑士。"
    long = "敌军只有少量骑士，短时间内打不到基地。" + "黄金是游侠的瓶颈，城墙用的是石头，两边不冲突。" * 6
    cut = clip(long, 100)
    assert len(cut) <= 100 and cut.endswith("。") and long.startswith(cut)             # ends on a sentence
    assert clip("一" * 150, 100) == "一" * 99 + "…"                                       # no sentence to end on
    premier = Premier()
    premier.decide(decision({"general-1": "now"}, thinking=long, decision="游侠优先，" * 30), [req("general-1", {"food": 60})], 0)
    assert len(premier.decision["thinking"]) <= 100 and len(premier.decision["decision"]) <= 60


def test_the_answer_must_rank_exactly_the_requests_that_were_shown():
    schema = rank_schema(["economy-1", "general-2"])
    valid = decision({"economy-1": "now", "general-2": "hold"}, "defend")

    Draft202012Validator(schema).validate(valid)
    assert list(schema["properties"])[:2] == ["thinking", "decision"]                   # the reason is written first
    for broken in (decision({"economy-1": "now"}), decision({"economy-1": "now", "general-2": "hold", "tech-1": "now"}),
                   decision({"economy-1": "now", "general-2": "soon"}), decision({"economy-1": "now", "general-2": "hold"}, "attack"),
                   {key: value for key, value in valid.items() if key != "thinking"}, {**valid, "commands": []},
                   {**valid, "thinking": "长" * 401}):
        with pytest.raises(ValidationError):
            Draft202012Validator(schema).validate(broken)


def test_the_model_sees_one_short_row_for_each_open_request():
    brief = IntelBrief(threat_level=3, forecast="behind", enemy_army={"knight": 6}, counters=["spearman"])
    guard = req("general-1", {"food": 60}, urgency=3, emergency=True)
    paladins = req("general-2", {"food": 60, "gold": 75}, origin=order_origin(3))
    castle = req("defense-1", {}, needs=("需要城堡时代",))
    castle.remaining = {"stone": 650.4}
    context = rank_context([guard, paladins, castle], {"general-1": "now", "general-2": "now"}, brief,
                           {"food": 820.7, "wood": 410, "gold": 300, "stone": 150}, {"food": 311.6, "wood": 0, "gold": 59.5, "stone": 0},
                           "defend", {"general-2": {"gold": 74.6, "food": 0.2}}, age=2)

    assert context["requests"] == [
        {"id": "general-1", "dept": "general", "item": "general-1", "remaining": {"food": 60}, "urgency": 3, "origin": "routine",
         "tier": "now", "floor": True},
        {"id": "general-2", "dept": "general", "item": "general-2", "remaining": {"food": 60, "gold": 75}, "urgency": 1,
         "origin": "order#3", "tier": "now", "short": {"gold": 75}},
        {"id": "defense-1", "dept": "defense", "item": "defense-1", "remaining": {"stone": 650}, "urgency": 1, "origin": "routine",
         "tier": "later", "needs": ["需要城堡时代"]}]
    assert context["intel"] == {"threat_level": 3, "forecast": "behind", "enemy_army": {"knight": 6}, "counters": ["spearman"]}
    assert (context["stock"], context["income_per_min"]) == ({"food": 820, "wood": 410, "gold": 300, "stone": 150},
                                                             {"food": 312, "wood": 0, "gold": 60, "stone": 0})
    assert (context["orders"], context["age"], context["posture"]) == ([], 2, "defend")
    # Sixteen requests could not all be shown; the model is asked about the first fifteen.
    many = [req(f"economy-{i}", {"wood": 10}) for i in range(16)]
    assert len(rank_context(many, {}, IntelBrief(), {}, {}, "balanced", {})["requests"]) == 15


def test_a_changed_picture_is_worth_asking_about_sooner():
    premier = Premier()
    militia, farm = req("general-1", {"food": 60}), req("economy-1", {"wood": 60})
    calm = premier.picture([militia], IntelBrief(threat_level=1), 3)

    assert premier.interval(calm) == RERANK_PAUSE == 20                                   # never asked yet
    premier.asked = calm
    assert premier.interval(premier.picture([militia], IntelBrief(threat_level=1, forecast="behind"), 3)) == RERANK_ROUTINE == 45
    for changed in (premier.picture([militia, farm], IntelBrief(threat_level=1), 3),      # a request was filed
                    premier.picture([militia], IntelBrief(threat_level=2), 3),            # the enemy is approaching
                    premier.picture([militia], IntelBrief(threat_level=1), 4)):           # a new mandate
        assert premier.interval(changed) == RERANK_PAUSE


# ---------------------------------------------------------------------------- inside the runtime
def contested(runtime, villagers=12):
    """Sixty food and twenty gold: one villager or one militia, not both."""
    def tick(number, now=None):
        entities = town(villagers, building(3, "mill"), *army(6))
        return runtime.tick(stocked(frame(number, entities=entities, time=number * 10 if now is None else now), food=60, gold=20))
    return tick


def ids(result):
    return {name: row["id"] for dept in ("economy", "general") for name, row in requests(result, dept).items()}


def test_the_models_ranking_moves_the_money_and_its_posture_reaches_the_field():
    runtime = cabinet()
    tick = contested(runtime)
    first = tick(1)
    assert bought(first) == ["villager"] and first["planning"]["premier"] == {"source": "rules", "posture": "balanced"}
    rid = ids(first)

    assert runtime.apply_plan("premier", decision({rid["militia"]: "now", rid["villager"]: "later", rid["farm"]: "later", "tech-9": "now"},
                                                  "pressure"))
    assert runtime.planning_context("premier")["plan"] == decision({rid["militia"]: "now", rid["villager"]: "later", rid["farm"]: "later"},
                                                                   "pressure")
    second = tick(2)
    assert bought(second) == ["militia"]
    assert second["planning"]["tiers"] == {rid["militia"]: "now", rid["villager"]: "later", rid["farm"]: "later"}
    assert second["planning"]["premier"] == {"source": "model", "posture": "pressure", "thinking": SAID["thinking"],
                                             "decision": SAID["decision"], "decided_at": 10.0}
    assert second["agent_status"]["premier"]["reason"] == "model_ranking"
    assert requests(second, "economy")["villager"]["gap"] == {"food": 50.0}
    assert runtime.field.roles["commander"].plan["stance"] == "pressure"
    assert any(entry["message"] == f"cabinet: {rid['militia']} moved from later to now" for entry in second["debug"])

    # Nobody renews it: three minutes on the rule book is back, and so is the default stance.
    assert tick(3, now=190)["planning"]["premier"]["source"] == "model"
    late = tick(4, now=191)
    assert late["planning"]["premier"] == {"source": "rules", "posture": "balanced"}
    assert late["planning"]["tiers"] == first["planning"]["tiers"] and requests(late, "general")["militia"]["gap"] == {"food": 50.0}
    assert late["agent_status"]["premier"]["reason"] == "model_decision_expired"
    assert runtime.field.roles["commander"].plan["stance"] == "balanced"


def test_the_villager_floor_holds_against_the_model():
    runtime = cabinet()
    tick = contested(runtime, villagers=10)                  # below the floor of twelve for this age
    rid = ids(tick(1))
    runtime.apply_plan("premier", decision({rid["villager"]: "hold", rid["militia"]: "later", rid["farm"]: "hold"}))

    second = tick(2)
    assert second["planning"]["tiers"] == {rid["villager"]: "next", rid["militia"]: "later", rid["farm"]: "hold"}
    assert requests(second, "economy")["villager"]["held"] == {"food": 50.0} and requests(second, "general")["militia"]["gap"]


def test_the_runtime_writes_one_ranking_call_and_takes_only_its_own_answer():
    runtime = cabinet()
    assert runtime.planning_roles[0] == "premier"
    assert runtime.planning_interval("premier") == math.inf and runtime.planning_brief("premier") is None    # nothing filed yet
    tick = contested(runtime)
    rid = ids(tick(1))

    assert runtime.planning_interval("premier") == 20
    brief = runtime.planning_brief("premier")
    assert (brief["system"], brief["output_tokens"], brief["player_orders"]) == (RANK_PROMPT, 512, False)
    shown = brief["context"]["requests"]
    # In funding order: the first in line for money is shown first.
    assert [(row["id"], row["tier"]) for row in shown] == [(rid["farm"], "next"), (rid["villager"], "next"), (rid["militia"], "later")]
    assert shown[2]["short"] == {"food": 50} and brief["context"]["stock"] == {"food": 60, "wood": 0, "gold": 20, "stone": 0}
    assert brief["schema"] == rank_schema([rid["farm"], rid["villager"], rid["militia"]])
    json.dumps(brief["context"], allow_nan=False)
    assert len(json.dumps(brief["context"], ensure_ascii=False)) < 1500
    # Asked: the same picture can now wait for the routine second look.
    assert runtime.planning_interval("premier") == 45

    assert runtime.planning_brief("commander") is None and not runtime.apply_plan("commander", decision({rid["militia"]: "now"}))
    with pytest.raises(ValueError):
        runtime.planning_context("commander")
    context = runtime.planning_context("premier")
    assert context["plan"] == {"tiers": {}, "posture": "balanced"} and context["plan_version"] == 0
    assert context["goals"] == runtime.goals and context["goals"] is not runtime.goals

    # A request on hold still has to be shown, or it could never be taken off hold.
    runtime.apply_plan("premier", decision({rid["militia"]: "hold", rid["villager"]: "now", rid["farm"]: "now"}))
    tick(2)
    assert [(row["id"], row["tier"]) for row in runtime.planning_brief("premier")["context"]["requests"]][-1] == (rid["militia"], "hold")


def test_the_model_is_shown_what_came_in_over_the_last_minute():
    runtime = cabinet()

    def tick(number, now, food):
        return runtime.tick(stocked(frame(number, entities=town(12, building(3, "mill")), time=now), food=food))

    tick(1, 0, 0)
    tick(2, 30, 30)                                          # thirty food in thirty seconds, too little to buy a villager
    context = runtime.planning_brief("premier")["context"]
    assert context["income_per_min"] == {"food": 60, "wood": 0, "gold": 0, "stone": 0} and context["stock"]["food"] == 30


def test_a_finished_match_asks_for_and_takes_no_more_rankings():
    runtime = cabinet()
    rid = ids(contested(runtime)(1))
    assert runtime.planning_brief("premier") is not None
    runtime.field.goals["match_over"] = True

    assert runtime.planning_brief("premier") is None
    assert not runtime.apply_plan("premier", decision({rid["militia"]: "now"})) and runtime.premier.decision is None


def test_the_match_log_gets_rankings_requests_and_grants():
    runtime = cabinet()

    def tick(number, now, food=0):
        return runtime.tick(stocked(frame(number, entities=town(12, building(3, "mill")), time=now), food=food))

    rid = ids(tick(1, 0))
    assert set(rid) == {"villager", "farm"}
    first = runtime.take_journal()
    assert runtime.take_journal() == []                      # handed over once
    assert first[0] == ("premier_decision", {"source": "rules", "reason": "default_ranking_rules", "posture": "balanced", "moved": {},
                                             "requests": 2, "threat_level": 0})
    assert ("request", {"change": "opened", "id": rid["villager"], "dept": "economy", "item": "villager x4",
                        "remaining": {"food": 200.0}, "urgency": 2, "origin": "routine", "tier": "next"}) in first
    assert [kind for kind, _ in first] == ["premier_decision", "request", "request", "grant"]
    assert first[-1][1] == {"grants": {rid["villager"]: {"state": "none", "tier": "next", "held": {}},
                                       rid["farm"]: {"state": "none", "tier": "next", "held": {}}},
                            "unallocated": {"food": 0.0, "wood": 0.0, "gold": 0.0, "stone": 0.0}}

    tick(2, 1)
    assert runtime.take_journal() == []                      # nothing changed: nothing written

    runtime.apply_plan("premier", decision({rid["villager"]: "later", rid["farm"]: "now", "tech-9": "now"}))
    tick(3, 2)
    assert runtime.take_journal() == [
        ("premier_decision", {"source": "model", "reason": "model_ranking", "posture": "balanced", "requests": 2, "threat_level": 0,
                              "moved": {rid["villager"]: ["next", "later"], rid["farm"]: ["next", "now"]},
                              "thinking": SAID["thinking"], "decision": SAID["decision"], "ignored": ["tech-9"], "version": 1,
                              "decided_at": 1.0}),
        ("request", {"change": "retiered", "id": rid["villager"], "from": "next", "to": "later", "by": "model"}),
        ("request", {"change": "retiered", "id": rid["farm"], "from": "next", "to": "now", "by": "model"})]

    # Twenty food arrives: the villagers are now paid in part, but the last summary is only five seconds old.
    tick(4, 5, food=20)
    assert runtime.take_journal() == []
    tick(5, 10, food=20)
    (kind, grant), = runtime.take_journal()
    assert kind == "grant" and grant["grants"][rid["villager"]] == {"state": "part", "tier": "later", "held": {"food": 20.0}}
    tick(6, 21, food=20)
    assert runtime.take_journal() == []                      # the pause is over, but who is paid has not changed

    # The model's word runs out, and requests nobody asks for again are closed in the log as well.
    farms = [building(40 + i, "farm", [12 + 3 * i, 12], amount=300, resource_type="FOOD") for i in range(8)]
    grown = town(20, building(3, "mill"), *farms)
    runtime.tick(stocked(frame(7, entities=grown, time=200), food=0))
    last = runtime.take_journal()
    assert last[0][0] == "premier_decision" and (last[0][1]["source"], last[0][1]["reason"]) == ("rules", "model_decision_expired")
    assert ("request", {"change": "closed", "id": rid["villager"], "dept": "economy", "item": "villager x4"}) in last
    assert ("request", {"change": "closed", "id": rid["farm"], "dept": "economy", "item": "farm"}) in last
    runtime.tick(stocked(frame(8, entities=grown, time=201), food=0))
    assert not [entry for kind, entry in runtime.take_journal() if entry.get("change") == "closed"]    # closed once, logged once


# ---------------------------------------------------------------------------- through the service
def answer(plan_req, tier="hold", posture="pressure", **override):
    shown = plan_req.tools[0].function.parameters["properties"]["tiers"]["required"]
    return completion(json.dumps({**SAID, "tiers": {rid: tier for rid in shown}, "posture": posture, **override}, ensure_ascii=False))


def cabinet_service(monkeypatch, forward, **options):
    monkeypatch.setenv("AOE2_AI_RUNTIME", "cabinet")
    monkeypatch.setenv("AOE2_AI_BACKEND", "openai")
    service = MultiAgentService(runtime_factory=create_runtime, forward=forward, max_workers=1, **options)
    service._pool.shutdown()
    service._pool = ControlledPool()
    return service


def test_the_service_asks_the_premiers_model_and_its_ranking_takes_effect(monkeypatch):
    from brain.llm_proxy import build_openai_payload
    monkeypatch.setenv("AOE2_LLM_BASE_URL", "http://127.0.0.1:11434/v1")
    sent, logs = [], []

    def forward(plan_req):
        sent.append(plan_req)
        return answer(plan_req)

    service = cabinet_service(monkeypatch, forward, log=lambda event, data: logs.append((event, data)))
    try:
        first = service.tick(tick_request(1, backend="openai"))
        assert first["planning"]["premier"]["source"] == "rules" and first["planning"]["premier"]["state"] == "planning"
        assert len(service._pool.jobs) == 1 and sent == []   # the tick did not wait for the model
        service._pool.finish()
        second = service.tick(tick_request(2, backend="openai"))
    finally:
        service.shutdown()

    plan_req = sent[0]
    assert plan_req.metadata.agent == "premier" and plan_req.metadata.plan_output_tokens == 512 and plan_req.observation is None
    system, context = plan_req.messages
    assert system.content.startswith(RANK_PROMPT) and len(plan_req.messages) == 2
    shown = json.loads(context.content)
    rows = {row["id"]: row for row in shown["requests"]}
    assert set(rows) == set(first["planning"]["tiers"]) and all(rows[rid]["tier"] == tier for rid, tier in first["planning"]["tiers"].items())
    assert plan_req.tools[0].function.parameters == rank_schema([row["id"] for row in shown["requests"]])
    assert plan_req.tools[0].function.description == "Rank the departments' open requests and set the posture."
    # The local model gets the larger output budget the two spoken texts need.
    assert build_openai_payload(plan_req)["options"]["num_predict"] == 512

    premier = second["planning"]["premier"]
    assert (premier["source"], premier["posture"], premier["state"], premier["parse_state"]) == ("model", "pressure", "applied", "valid")
    assert premier["thinking"] == SAID["thinking"] and premier["decision"] == SAID["decision"]
    # Everything was put on hold; the villagers below the floor stay at "next" all the same.
    floor = requests(second, "economy")["villager"]["id"]
    ranked = {rid: tier for rid, tier in second["planning"]["tiers"].items() if rid in rows}
    assert ranked and all(tier == ("next" if rid == floor else "hold") for rid, tier in ranked.items())

    events = [event for event, _ in logs]
    assert events.count("model_request") == 1 and events.count("model_result") == 1
    result = next(data for event, data in logs if event == "model_result")
    assert (result["agent"], result["state"]) == ("premier", "applied") and result["plan"]["posture"] == "pressure"
    decisions = [data for event, data in logs if event == "premier_decision"]
    assert [d["source"] for d in decisions] == ["rules", "model"] and decisions[1]["thinking"] == SAID["thinking"]
    assert (decisions[1]["match_id"], decisions[1]["team"], decisions[1]["observation_seq"]) == ("multi-test", 0, 2)
    assert {"request", "grant"} <= set(events)
    assert events.index("tick") < events.index("premier_decision")       # a tick's entries follow its tick line


@pytest.mark.parametrize("failure, state", [
    ("missing_request", "invalid_plan"), ("unknown_tier", "invalid_plan"), ("truncated", "invalid_plan"),
    ("expired", "plan_expired"), ("orders_changed", "player_instructions_changed"), ("model_down", "fallback")])
def test_a_bad_or_late_answer_leaves_the_rule_book_in_charge(monkeypatch, failure, state):
    def forward(plan_req):
        shown = plan_req.tools[0].function.parameters["properties"]["tiers"]["required"]
        if failure == "model_down":
            raise TimeoutError("model unavailable")
        if failure == "missing_request":
            return completion(json.dumps({**SAID, "tiers": {rid: "hold" for rid in shown[1:]}, "posture": "pressure"}))
        if failure == "unknown_tier":
            return answer(plan_req, tier="soon")
        if failure == "truncated":
            return completion(json.dumps({**SAID, "tiers": {rid: "hold" for rid in shown}, "posture": "pressure"}), finish="length")
        return answer(plan_req)

    service = cabinet_service(monkeypatch, forward)
    try:
        first = service.tick(tick_request(1, backend="openai"))
        session = service._sessions[("multi-test", 0)]
        if failure == "expired":
            with session.lock:
                session.last_sim_time += 181
        if failure == "orders_changed":
            ordered = tick_request(2, backend="openai")
            ordered.observation.player_instructions = ["囤积五十个游侠"]
            service._pool.jobs, held = [], service._pool.jobs       # the new order must not start a second call here
            service.tick(ordered)
            service._pool.jobs = held
        service._pool.finish()
        assert session.plan_status["premier"]["state"] == state
        assert session.runtime.premier.decision is None
        later = tick_request(3, backend="openai")
        later.metadata.time_sec = session.last_sim_time + 1
        service._pool.jobs = []
        after = service.tick(later)
    finally:
        service.shutdown()

    assert after["planning"]["premier"]["source"] == "rules" and after["planning"]["premier"]["posture"] == "balanced"
    assert all(after["planning"]["tiers"][rid] == tier for rid, tier in first["planning"]["tiers"].items() if rid in after["planning"]["tiers"])


def test_the_premier_is_asked_again_only_after_its_pause(monkeypatch):
    now, sent = [0.0], []

    def forward(plan_req):
        sent.append(plan_req)
        return answer(plan_req, tier="later", posture="balanced")

    service = cabinet_service(monkeypatch, forward, clock=lambda: now[0])
    try:
        service.tick(tick_request(1, backend="openai"))
        service._pool.finish()
        now[0] = 19                                          # too soon, whatever has changed
        service.tick(tick_request(2, backend="openai"))
        assert service._pool.jobs == [] and len(sent) == 1
        now[0] = 46                                          # the routine second look is due at the latest
        service.tick(tick_request(3, backend="openai"))
        service._pool.finish()
    finally:
        service.shutdown()
    assert len(sent) == 2
