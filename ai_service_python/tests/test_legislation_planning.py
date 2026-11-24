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
            "mandates": list(mandates), "resolution": "legislation", "legislation": gap()}


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
    assert r.ledger.details()[0]["status"] == "立法失败"
    assert r.ledger.rows()[0]["status"] == "立法失败"
    assert r.ledger.take_events()[-1]["status"] == "立法失败"


def test_failed_bill_keeps_independent_mandates_and_its_display_survives_checkpoint_restore():
    from brain.legislation.checkpoint import export_checkpoint, restore_checkpoint

    r = runtime()
    r.planning_brief(ORDERS_ROLE)
    ordinary = {"kind": "boost_resource", "subject": "food", "amount": 0, "urgency": "normal"}
    assert r.apply_plan(ORDERS_ROLE, reading([ordinary]))
    assert r.legislation_result("order-1", "failed", "invalid_tool_calls")
    restored = restore_checkpoint(export_checkpoint(r), CabinetRuntime("chinese"))
    order = restored.ledger.find(1)
    assert order.status == WAITING_LEGISLATION
    assert order.label() == "立法失败"
    assert restored.ledger.details()[0]["waiting"] == "invalid_tool_calls"
    assert restored.ledger.mandates()[0].subject == "food"
    assert not restored.legislative_requests() and restored.ledger.pending() is None
    assert not restored.legislation_progress("order-1", "retrying")
    assert order.label() == "立法失败"
    restored.ledger.intake([], 2)
    assert not restored.ledger.mandates() and not restored.ledger.details()
    assert not restored.legislation_result("order-1", "installed")


def test_revoking_failed_bill_replaces_its_failure_label():
    r = runtime()
    r.planning_brief(ORDERS_ROLE)
    assert r.apply_plan(ORDERS_ROLE, reading())
    assert r.legislation_result("order-1", "failed", "invalid_tool_calls")
    assert r.legislation_result("order-1", "revoked", "instruction_window_changed")
    assert r.ledger.details()[0]["status"] == "已取代"
    assert not r.legislative_requests()


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


def test_missing_legislation_retries_routing_instead_of_demanding_unrelated_mandates():
    r = runtime()
    order = r.ledger.find(1)
    order.text = "让农田贴在一起"
    r.planning_brief(ORDERS_ROLE)
    failed = {"grasp": "guess", "mandates": [],
              "thinking": "没有农田布局任务书，转成经济部立法需求。",
              "decision": "按立法程序补一条农田选址算法。"}
    with pytest.raises(ValidationError):
        Draft202012Validator(interpret_schema(True)).validate(failed)
    assert not r.apply_plan(ORDERS_ROLE, failed)
    assert order.status == NEW and not order.mandates and order.legislation is None
    retry = r.planning_brief(ORDERS_ROLE)["context"]
    assert retry["order"] == "让农田贴在一起"
    assert retry["previous"]["response"] == failed
    assert "mandates 可以为空" in retry["previous"]["problem"]
    assert "不要用无关的普通任务替换" in retry["previous"]["problem"]
    fixed = reading()
    assert r.apply_plan(ORDERS_ROLE, fixed)
    assert order.status == WAITING_LEGISLATION and order.rejected_reading is None


@pytest.mark.parametrize("change", [
    {"resolution": "mandates"},
    {"resolution": "unsupported", "grasp": "none"},
    {"resolution": "legislation", "legislation": None},
    {"resolution": "legislation", "grasp": "none"},
])
def test_resolution_branch_mismatch_stops_after_bounded_retries_without_changing_the_goal(change):
    r = runtime()
    plan = {**reading(), **change}
    for _ in range(3):
        r.planning_brief(ORDERS_ROLE)
        assert not r.apply_plan(ORDERS_ROLE, plan)
    order = r.ledger.find(1)
    assert order.status == "reading_failed"
    assert r.planning_brief(ORDERS_ROLE) is None
    assert r.ledger.details()[0]["status"] == "解读失败"
    assert "停止自动重试" in r.ledger.details()[0]["waiting"]
    assert not r.legislative_requests() and not r.ledger.mandates()
    # Reissuing the command creates a fresh reading; the failed entry stays honest.
    r.ledger.intake([order.text, order.text], 3)
    assert r.planning_brief(ORDERS_ROLE) is not None
    assert r.apply_plan(ORDERS_ROLE, reading())
    assert r.ledger.find(2).status == WAITING_LEGISLATION
    assert order.status == "reading_failed"


def test_explicit_ordinary_and_unsupported_routes_work_without_creating_bills():
    r = runtime()
    r.ledger.find(1).text = "多采木材"
    r.planning_brief(ORDERS_ROLE)
    plan = {"resolution": "mandates", "legislation": None, "grasp": "exact",
            "thinking": "现有采集任务可以满足要求。", "decision": "提高木材采集优先级。",
            "mandates": [{"kind": "boost_resource", "subject": "wood", "amount": 0, "urgency": "normal"}]}
    Draft202012Validator(interpret_schema(True)).validate(plan)
    assert r.apply_plan(ORDERS_ROLE, plan)
    assert r.ledger.find(1).status == ACTIVE and not r.legislative_requests()
    assert r.ledger.mandates()[0].subject == "wood"
    r.ledger.intake(["多采木材", "创建游戏不存在的星际舰队"], 2)
    r.planning_brief(ORDERS_ROLE)
    plan.update(resolution="unsupported", grasp="none", mandates=[], decision="游戏没有这种单位。")
    Draft202012Validator(interpret_schema(True)).validate(plan)
    assert r.apply_plan(ORDERS_ROLE, plan)
    assert r.ledger.find(2).status == "impossible" and not r.legislative_requests()


def test_host_schema_rejection_keeps_order_visible_and_pending():
    r = runtime()
    r.planning_brief(ORDERS_ROLE)
    assert r.plan_rejected(ORDERS_ROLE, "schema_validation_error")
    assert r.ledger.pending().number == 1
    assert "原指令尚未执行" in r.ledger.details()[0]["waiting"]
    assert "schema_validation_error" in r.planning_brief(ORDERS_ROLE)["context"]["previous"]["problem"]
    assert not r.plan_rejected("premier", "invalid ranking")
    r.ledger.intake([], 2)
    assert not r.plan_rejected(ORDERS_ROLE, "late response")


def test_agent_progress_is_visible_without_changing_frozen_goal_or_reviving_installed_bill():
    r = runtime()
    r.planning_brief(ORDERS_ROLE)
    assert r.apply_plan(ORDERS_ROLE, reading())
    order = r.ledger.find(1)
    revision, target = r.ledger.revision, order.legislation["target_revision"]
    for phase in ("coding", "retrying", "validating", "ready"):
        assert r.legislation_progress("order-1", phase, "context", step=2)
        assert order.status == WAITING_LEGISLATION and order.legislation["status"] == "waiting"
        assert order.legislation["phase"] == phase and order.legislation["step"] == 2
        assert "context" in order.waiting
        assert r.ledger.revision == revision and order.legislation["target_revision"] == target
    assert not r.legislation_progress("order-1", "unknown")
    assert r.legislation_result("order-1", "installed")
    assert order.legislation["phase"] == "installed"
    assert not r.legislation_progress("order-1", "retrying")
    assert order.status == ACTIVE


def test_legislation_lifecycle_emits_premier_broadcasts_for_player():
    r = runtime()
    r.planning_brief(ORDERS_ROLE)
    assert r.apply_plan(ORDERS_ROLE, reading())
    req = frame(2, time=2.0)
    req.observation.player_instructions = ["木材低于200开始优先采集，到320停止"]
    requested = r.tick(req)["planning"].get("broadcasts", [])
    assert any("等待立法会" in line["text"] for line in requested)

    assert r.legislation_result("order-1", "installed")
    req3 = frame(3, time=3.0)
    req3.observation.player_instructions = ["木材低于200开始优先采集，到320停止"]
    installed = r.tick(req3)["planning"].get("broadcasts", [])
    assert any("安装生效" in line["text"] for line in installed)
