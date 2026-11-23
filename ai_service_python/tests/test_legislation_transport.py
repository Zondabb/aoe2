"""Source generation has its own tool name and output budget on both backends."""
import json

from brain import llm_proxy
from brain.multi_agent.scheduler import _decode_plan, plan_request
from brain.legislation.planning import proposal_brief
from test_multi_agent_scheduler import tick_request


def test_source_tool_has_dedicated_budget_and_ollama_schema(monkeypatch):
    monkeypatch.setenv("AOE2_LLM_BASE_URL", "http://127.0.0.1:11434/v1")
    brief = proposal_brief({"proposal_id": "order-1"}, "base", {})
    brief.update(orders=(), statuses=[])
    req, _ = plan_request(tick_request(), "legislative_council", brief, "request-1")
    assert req.tools[0].function.name == "propose_source_patch"
    assert req.max_tokens == 8192
    payload = llm_proxy.build_openai_payload(req)
    assert payload["options"]["num_predict"] == 8192
    assert payload["options"]["num_ctx"] >= 32768
    assert payload["format"] == brief["schema"]
    plan = {"proposal_id": "order-1", "base_release": "base", "unified_diff": "patch",
            "state_fields": [], "explanation": "bounded source edit"}
    response = llm_proxy._normalize_ollama_plan_response(
        {"message": {"content": json.dumps(plan)}, "done": True, "usage": {}}, "model", "propose_source_patch")
    assert _decode_plan(response.choices[0], brief["schema"], "propose_source_patch")[0] == plan
    assert _decode_plan(response.choices[0], brief["schema"])[0] is None
