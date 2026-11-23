"""A frozen algorithm gap travels separately from executable ordinary mandates."""
import copy

from jsonschema import Draft202012Validator, ValidationError
import pytest

from brain.cabinet.ledger import ACTIVE, NEW, WAITING_LEGISLATION
from brain.cabinet.premier import ORDERS_ROLE, interpret_schema
from brain.cabinet.runtime import CabinetRuntime
from brain.legislation.planning import proposal_brief, proposal_schema
from test_multi_agent_runtime import frame


def gap():
    return {"kind": "algorithm_gap", "departments": ["economy"],
            "evidence": ["boost_resource applies a fixed boost, without hysteresis"],
            "acceptance": {"positive": ["wood 199 then 250 keeps priority on"],
                           "negative": ["wood 320 then 250 keeps priority off; preserve food demand"]},
            "revoke_when": "player clears or supersedes this instruction"}


def reading(mandates=()):
    return {"grasp": "exact", "thinking": "需要记住上轮采集状态。", "decision": "提交经济部立法。",
            "mandates": list(mandates), "legislation": gap()}


def runtime(enabled=True):
    result = CabinetRuntime("chinese")
    result.legislative_enabled = enabled
    req = frame(1)
    req.observation.player_instructions = ["木材低于200开始优先采集，到320停止"]
    result.tick(req)
    return result


def test_schema_only_offers_code_gaps_when_host_enabled_it():
    with pytest.raises(ValidationError):
        Draft202012Validator(interpret_schema()).validate(reading())
    check = Draft202012Validator(interpret_schema(True)).validate
    check(reading())
    for field, value in (("kind", "waiting_funds"), ("departments", ["runtime"]), ("evidence", [])):
        bad = reading()
        bad["legislation"][field] = value
        with pytest.raises(ValidationError):
            check(bad)
    bad = reading()
    bad["legislation"]["acceptance"]["negative"] = []
    with pytest.raises(ValidationError):
        check(bad)


def test_gap_is_frozen_skips_interpretation_and_installation_does_not_complete_goal():
    r = runtime()
    r.planning_brief(ORDERS_ROLE)
    plan = reading()
    assert r.apply_plan(ORDERS_ROLE, plan)
    order = r.ledger.find(1)
    assert order.status == WAITING_LEGISLATION
    assert r.ledger.pending() is None
    request = r.legislative_requests()[0]
    assert request["proposal_id"] == "order-1" and request["instruction"] == order.text
    plan["legislation"]["acceptance"]["positive"].clear()
    request["evidence"].clear()
    assert order.legislation["acceptance"]["positive"] and order.legislation["evidence"]
    assert r.legislation_result("order-1", "installed")
    assert order.status == ACTIVE
    assert r.legislative_requests() == []
    assert not r.legislation_result("unknown", "installed")
    assert not r.legislation_result("order-1", "done")


def test_ordinary_subtasks_continue_and_new_orders_still_get_read():
    r = runtime()
    r.planning_brief(ORDERS_ROLE)
    ordinary = {"kind": "boost_resource", "subject": "food", "amount": 0, "urgency": "normal"}
    assert r.apply_plan(ORDERS_ROLE, reading([ordinary]))
    order = r.ledger.find(1)
    assert r.ledger.mandates()[0].subject == "food"
    r.ledger.record(order, order.mandates[0], True, "完成")
    assert order.status == WAITING_LEGISLATION  # ordinary completion cannot finish the code goal
    r.ledger.intake([order.text, "加强侦察"], 2)
    assert r.ledger.pending().number == 2
    assert r.planning_brief(ORDERS_ROLE)["context"]["order"] == "加强侦察"


def test_disabled_invalid_and_cancelled_requests_cannot_install():
    r = runtime(False)
    r.planning_brief(ORDERS_ROLE)
    assert not r.apply_plan(ORDERS_ROLE, reading())
    assert r.ledger.find(1).status == NEW
    r.legislative_enabled = True
    bad = reading()
    bad["legislation"]["kind"] = "waiting_receipt"
    assert not r.apply_plan(ORDERS_ROLE, bad)
    assert r.apply_plan(ORDERS_ROLE, reading())
    r.ledger.intake([], 2)
    assert r.legislative_requests() == []
    assert not r.legislation_result("order-1", "installed")


def test_failure_is_visible_and_does_not_repeatedly_submit_same_request():
    r = runtime()
    r.planning_brief(ORDERS_ROLE)
    assert r.apply_plan(ORDERS_ROLE, reading())
    assert r.legislation_result("order-1", "failed", "patch verification failed")
    assert r.legislative_requests() == [] and r.ledger.pending() is None
    assert r.ledger.details()[0]["waiting"] == "patch verification failed"


def test_source_proposal_is_pinned_to_the_host_selected_identity():
    schema = proposal_schema("order-1", "abc")
    check = Draft202012Validator(schema).validate
    proposal = {"proposal_id": "order-1", "base_release": "abc", "unified_diff": "patch",
                "state_fields": [{"department": "economy", "name": "wood_priority", "type": "bool", "default": False}],
                "explanation": "remember the threshold state"}
    check(proposal)
    for key in ("proposal_id", "base_release"):
        with pytest.raises(ValidationError):
            check({**proposal, key: "other"})
    request = {"proposal_id": "order-1", **gap()}
    brief = proposal_brief(request, "abc", {"files": {"economy.py": "source"}})
    assert brief["output_tokens"] == 8192 and brief["player_orders"] is False
    request["evidence"].clear()
    assert brief["context"]["legislation"]["evidence"]
