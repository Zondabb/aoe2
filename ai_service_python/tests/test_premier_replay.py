"""tools/premier_replay.py: the premier's ranking call sent to a model outside a match, and its answers counted."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path

from brain.cabinet.premier import RANK_PROMPT, rank_schema
from test_multi_agent_scheduler import completion

SPEC = importlib.util.spec_from_file_location("premier_replay", Path(__file__).resolve().parents[1] / "tools" / "premier_replay.py")
premier_replay = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(premier_replay)

SAID = {"thinking": "敌人还没露面，粮食只够一样。", "decision": "先补民兵，村民往后放。"}


def shown(plan_req) -> list[str]:
    return plan_req.tools[0].function.parameters["properties"]["tiers"]["required"]


def good(plan_req, tier="next", **override):
    return completion(json.dumps({**SAID, "tiers": {rid: tier for rid in shown(plan_req)}, "posture": "balanced", **override},
                                 ensure_ascii=False))


def test_the_replay_sends_what_the_service_sends_and_counts_usable_answers():
    sent = []

    def forward(plan_req):
        sent.append(plan_req)
        turn = len(sent)
        if turn == 1:
            raise TimeoutError("model unavailable")
        if turn == 2:
            return completion(json.dumps({**SAID, "tiers": {rid: "next" for rid in shown(plan_req)[1:]}, "posture": "balanced"}))
        if turn == 3:
            return good(plan_req, thinking="The enemy is far away and we have enough food.", decision="Train more soldiers first.")
        if turn == 4:
            return good(plan_req, tier="hold", thinking="想" * 101)
        return good(plan_req)

    cases = premier_replay.sample_cases()
    report = premier_replay.replay(cases, 1, forward, clock=lambda: 0.0)

    first = sent[0]
    context = json.loads(first.messages[1].content)
    assert first.metadata.agent == "premier" and first.metadata.plan_output_tokens == 512 and first.observation is None
    assert first.messages[0].content.startswith(RANK_PROMPT) and context == cases[0]["context"]
    assert first.tools[0].function.parameters == rank_schema([row["id"] for row in context["requests"]])

    assert len(sent) == len(cases) == report["calls"] == 5
    assert report["states"] == {"call_failed": 1, "schema_validation_error": 1, "valid": 3} and report["valid_rate"] == .6
    assert (report["not_chinese"], report["over_length"]) == (1, 1)
    # The fourth situation holds a population floor; putting everything on hold overrules it, which the report counts.
    assert report["floor_overruled"] == 1 and report["cases"][3]["answers"][0]["floor_overruled"] == ["economy-3"]
    assert [case["valid"] for case in report["cases"]] == [0, 0, 1, 1, 1]
    assert report["cases"][0]["answers"][0] == {"state": "call_failed", "reason": "TimeoutError", "seconds": 0.0,
                                                "input_chars": len(first.messages[1].content)}


def test_rankings_are_taken_from_a_match_log_each_distinct_one_once(tmp_path):
    def entry(agent, context, sim_time):
        return json.dumps({"event": "llm_io", "agent": agent, "match_id": "m1", "sim_time": sim_time,
                           "input": {"messages": [{"role": "system", "content": "s"},
                                                  {"role": "user", "content": json.dumps(context, ensure_ascii=False)}]}}, ensure_ascii=False)

    one = {"requests": [{"id": "economy-1", "item": "villager", "tier": "next"}], "stock": {"food": 10}}
    two = {"requests": [{"id": "general-1", "item": "militia", "tier": "later"}], "stock": {"food": 90}}
    log = tmp_path / "multi_agent.jsonl"
    log.write_text("\n".join([
        entry("premier", one, 10), entry("premier", one, 11),                  # the same picture twice
        entry("economy", {"requests": [{"id": "x"}]}, 12),                      # another planner's call
        entry("premier", {"requests": []}, 13),                                 # nothing to rank
        "not json", json.dumps({"event": "tick"}),
        entry("premier", two, 20)]), encoding="utf-8")

    cases = premier_replay.cases_from_log(log, 0)
    assert [(case["name"], case["context"]) for case in cases] == [("m1@10", one), ("m1@20", two)]
    assert premier_replay.cases_from_log(log, 1) == cases[1:]

    report = premier_replay.replay(cases, 2, good, clock=lambda: 0.0)
    assert (report["calls"], report["valid"], report["kept_every_tier"]) == (4, 4, 2)   # "next" keeps the first picture's tier


def test_the_command_reports_and_fails_below_the_asked_share(tmp_path, monkeypatch, capsys):
    calls = []

    def forward(plan_req):
        calls.append(plan_req)
        if len(calls) % 5 == 1:
            raise ConnectionError("model unavailable")
        return good(plan_req)

    original = premier_replay.replay
    monkeypatch.setattr(premier_replay.runtime_settings, "load_config", lambda path=None: None)
    monkeypatch.setattr(premier_replay, "replay", lambda cases, runs: original(cases, runs, forward, lambda: 0.0))
    out = tmp_path / "report.json"

    assert premier_replay.main(["--runs", "1", "--json", str(out), "--min-valid", "0.9"]) == 1
    summary = json.loads(capsys.readouterr().out)
    assert (summary["calls"], summary["valid"], summary["valid_rate"]) == (5, 4, .8)
    assert summary["cases"][0] == {"name": "food_for_one_purchase", "requests": 3, "valid": "0/1"}
    assert summary["example"]["thinking"] == SAID["thinking"] and summary["example"]["posture"] == "balanced"
    report = json.loads(out.read_text(encoding="utf-8"))
    assert report["cases"][0]["answers"][0]["reason"] == "ConnectionError" and len(report["cases"]) == 5

    assert premier_replay.main(["--runs", "1", "--min-valid", "0.8"]) == 0
    capsys.readouterr()
    empty = tmp_path / "empty.jsonl"
    empty.write_text("", encoding="utf-8")
    assert premier_replay.main(["--log", str(empty)]) == 2      # a log without rankings is said so, not reported as 0 %
