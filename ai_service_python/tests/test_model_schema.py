"""Provider signatures stay complete; host-only routing checks remain strict."""
import copy
import json

from jsonschema import Draft202012Validator, ValidationError
import pytest

from brain.cabinet.premier import interpret_schema
from brain.legislation.agent import CodingSession
from brain.model_schema import planner_tool_schema
from brain.multi_agent.scheduler import plan_request, _decode_plan
from protocol.models import ChatCompletionRequest, ChatCompletionResponse
from test_legislation_planning import reading


def test_legislative_intake_wire_signature_has_all_six_fields_in_one_object():
    schema = interpret_schema(True)
    saved = copy.deepcopy(schema)
    wire = planner_tool_schema(schema)
    assert "oneOf" not in wire and "oneOf" in schema
    assert set(wire["required"]) == {"thinking", "decision", "grasp", "mandates", "resolution", "legislation"}
    assert set(wire["properties"]) == set(wire["required"])
    gap = wire["properties"]["legislation"]
    assert gap["type"] == ["object", "null"]
    assert set(gap["required"]) == {"kind", "departments", "evidence", "acceptance", "revoke_when"}
    Draft202012Validator(wire).validate(reading())
    with pytest.raises(ValidationError):
        Draft202012Validator(wire).validate({"grasp": "exact", "resolution": "legislation"})
    assert schema == saved


def test_null_and_complete_legislation_remain_valid_and_cross_field_mismatch_is_rejected_locally():
    schema = interpret_schema(True)
    wire = planner_tool_schema(schema)
    unsupported = {**reading(), "resolution": "unsupported", "grasp": "none", "legislation": None}
    for plan in (reading(), unsupported):
        Draft202012Validator(wire).validate(plan)
        Draft202012Validator(schema).validate(plan)
    bad = {**reading(), "resolution": "mandates"}
    Draft202012Validator(wire).validate(bad)
    with pytest.raises(ValidationError):
        Draft202012Validator(schema).validate(bad)


def test_wire_projection_is_used_by_requests_but_not_the_host_decoder():
    schema = interpret_schema(True)
    brief = {"system": "Read the order", "context": {}, "schema": schema,
             "description": "Interpret", "output_tokens": 1024, "orders": (), "statuses": []}
    req, _ = plan_request(ChatCompletionRequest(model="test", messages=[]), "premier_orders", brief, "test")
    assert "oneOf" not in req.tools[0].function.parameters
    bad = {**reading(), "resolution": "unsupported"}
    Draft202012Validator(req.tools[0].function.parameters).validate(bad)
    response = ChatCompletionResponse.model_validate({"id": "schema-test", "choices": [{"finish_reason": "stop", "message": {
        "role": "assistant", "content": json.dumps(bad)}}]})
    assert _decode_plan(response.choices[0], schema)[2] == "schema_validation_error"


def test_coding_actions_expose_fields_and_explain_conditional_requirements_without_partial_branches():
    session = object.__new__(CodingSession)
    session.requirement, session.base, session.data = {"proposal_id": "order-1"}, "a" * 64, {"steps": 0}
    schema = session.schema()
    wire = planner_tool_schema(schema)
    assert "allOf" not in wire and "allOf" in schema
    assert "read" in wire["properties"]["action"]["description"]
    assert "start_line" in wire["properties"]["action"]["description"]
    assert wire["properties"]["proposal_id"] == {"enum": ["order-1"], "type": "string"}
    assert wire["properties"]["step"] == {"enum": [0], "type": "integer"}
    incomplete = {"proposal_id": "order-1", "base_release": session.base, "step": 0, "action": "read"}
    Draft202012Validator(wire).validate(incomplete)
    with pytest.raises(ValidationError):
        Draft202012Validator(schema).validate(incomplete)
    complete = {**incomplete, "path": "brain/cabinet/departments/economy.py", "start_line": 1}
    Draft202012Validator(wire).validate(complete)
    Draft202012Validator(schema).validate(complete)


def test_disabled_intake_schema_stays_unchanged():
    original = interpret_schema(False)
    assert planner_tool_schema(original) == original
