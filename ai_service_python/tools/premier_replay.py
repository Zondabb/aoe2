#!/usr/bin/env python3
"""Ask the configured model to rank requests as the cabinet's premier, and count how often its answer can be used.

The service sends exactly this request during a match (brain/cabinet/premier.py,
brain/multi_agent/scheduler.py). Run it against a model before relying on that
model in a game.

Usage, from ai_service_python:
  python tools/premier_replay.py                      built-in situations, 5 runs each
  python tools/premier_replay.py --log logs/multi_agent.jsonl
                                                      the rankings a match actually asked for
  python tools/premier_replay.py --runs 10 --json report.json --min-valid 0.9

The model, address and token come from config.toml / config.local.toml and the
AOE2_LLM_* variables, as for the service. Nothing is written but the report.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import statistics
import sys
import time
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from brain import runtime_settings  # noqa: E402
from brain.cabinet.models import IntelBrief, Request, order_origin  # noqa: E402
from brain.cabinet.premier import (DECISION_LIMIT, OUTPUT_TOKENS, RANK_PROMPT, ROLE, THINKING_LIMIT, Premier, rank_context,  # noqa: E402
                                   rank_schema)
from brain.llm_proxy import forward_openai  # noqa: E402
from brain.multi_agent.scheduler import _decode_plan, plan_request  # noqa: E402
from protocol.models import ChatCompletionRequest  # noqa: E402

DESCRIPTION = "Rank the departments' open requests and set the posture."


def _request(rid: str, item: str, remaining: dict, urgency: int = 1, count: int = 1, **extra) -> Request:
    return Request(id=rid, dept=rid.split("-")[0], key=(rid,), item=item, count=count, remaining=dict(remaining),
                   tranche=dict(remaining), urgency=urgency, **extra)


def sample_cases() -> list[dict]:
    """A few situations a premier meets, in the shape the runtime sends them."""
    def case(name, requests, tiers, brief, stock, income, posture="balanced", gaps=None, orders=None, age=1):
        context = rank_context(requests, tiers, brief, stock, income, posture, gaps or {}, orders, age)
        return {"name": name, "context": context}

    calm = IntelBrief(threat_level=0, forecast="unknown")
    return [
        case("food_for_one_purchase",
             [_request("economy-1", "villager", {"food": 200}, 2, count=4), _request("economy-2", "farm", {"wood": 60}, 3),
              _request("general-1", "militia", {"food": 60, "gold": 20})],
             {"economy-1": "next", "economy-2": "next", "general-1": "later"}, calm,
             {"food": 60, "wood": 0, "gold": 20, "stone": 0}, {"food": 180, "wood": 120, "gold": 0, "stone": 0},
             gaps={"general-1": {"food": 50}}, age=0),
        case("base_under_attack",
             [_request("general-3", "spearman", {"food": 105, "wood": 75}, 3, count=3, emergency=True),
              _request("tech-2", "age_3", {"food": 1000, "gold": 800}, 2), _request("defense-1", "stone_wall", {"stone": 240}, 1, count=48),
              _request("economy-4", "villager", {"food": 150}, 1, count=3)],
             {"general-3": "now", "tech-2": "next", "defense-1": "later", "economy-4": "later"},
             IntelBrief(threat_level=3, forecast="behind", enemy_army={"knight": 6, "crossbowman": 8}, counters=["spearman", "skirmisher"]),
             {"food": 430, "wood": 210, "gold": 520, "stone": 90}, {"food": 420, "wood": 260, "gold": 180, "stone": 40},
             gaps={"tech-2": {"food": 570, "gold": 280}, "defense-1": {"stone": 150}}, age=2),
        case("an_order_against_routine",
             [_request("general-7", "paladin", {"food": 2280, "gold": 2850}, 2, count=38, origin=order_origin(3)),
              _request("defense-2", "stone_wall", {"stone": 600}, 1, count=120, origin=order_origin(4)),
              _request("economy-5", "villager", {"food": 300}, 1, count=6)],
             {"general-7": "now", "defense-2": "later", "economy-5": "next"},
             IntelBrief(threat_level=1, forecast="even", enemy_army={"knight": 6, "crossbowman": 8}),
             {"food": 820, "wood": 410, "gold": 300, "stone": 150}, {"food": 520, "wood": 300, "gold": 240, "stone": 60},
             gaps={"general-7": {"gold": 75}, "defense-2": {"stone": 450}},
             orders=[{"id": 3, "text": "囤积50个游侠", "status": "执行中 12/50"}, {"id": 4, "text": "加速城墙建造", "status": "新下达"}], age=3),
        case("saving_for_the_next_age",
             [_request("tech-1", "age_2", {"food": 800, "gold": 200}, 2), _request("general-2", "man_at_arms", {"food": 60, "gold": 20}, 1),
              _request("general-4", "archer", {"wood": 25, "gold": 45}, 1), _request("economy-3", "house", {"wood": 30}, 3, floor=True),
              _request("economy-6", "mining_camp", {"wood": 100}, 2)],
             {"tech-1": "next", "general-2": "later", "general-4": "later", "economy-3": "now", "economy-6": "next"},
             IntelBrief(threat_level=1, forecast="even", enemy_army={"man_at_arms": 5}),
             {"food": 410, "wood": 95, "gold": 130, "stone": 0}, {"food": 380, "wood": 240, "gold": 90, "stone": 0},
             gaps={"tech-1": {"food": 390, "gold": 70}, "general-2": {"food": 60, "gold": 20}, "economy-6": {"wood": 35}}),
        case("many_requests_plenty_of_stock",
             [_request(f"{dept}-{n}", item, cost, urgency) for n, (dept, item, cost, urgency) in enumerate([
                 ("economy", "villager", {"food": 50}, 2), ("economy", "farm", {"wood": 60}, 1), ("economy", "lumber_camp", {"wood": 100}, 2),
                 ("general", "knight", {"food": 60, "gold": 75}, 2), ("general", "stable", {"wood": 175}, 1),
                 ("general", "battering_ram", {"wood": 160, "gold": 75}, 1), ("defense", "palisade_wall", {"wood": 60}, 0),
                 ("defense", "gate", {"wood": 30}, 0), ("tech", "age_3", {"food": 1000, "gold": 800}, 2),
                 ("tech", "forging", {"food": 150}, 1), ("tech", "university", {"wood": 200}, 1)], 1)],
             {}, IntelBrief(threat_level=2, forecast="ahead", enemy_army={"spearman": 9, "archer": 4}, counters=["knight"]),
             {"food": 1900, "wood": 1400, "gold": 1100, "stone": 300}, {"food": 700, "wood": 520, "gold": 380, "stone": 80},
             posture="pressure", age=2),
    ]


def cases_from_log(path: Path, limit: int) -> list[dict]:
    """The premier's rankings recorded in a match log, each distinct one once, newest last."""
    seen, cases = set(), []
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        payload = event.get("input")
        if event.get("event") != "llm_io" or event.get("agent") != ROLE or not isinstance(payload, dict):
            continue
        user = next((m.get("content") for m in payload.get("messages", []) if isinstance(m, dict) and m.get("role") == "user"), None)
        try:
            context = json.loads(user)
        except (TypeError, ValueError):
            continue
        if not isinstance(context, dict) or not isinstance(context.get("requests"), list) or not context["requests"] or user in seen:
            continue
        seen.add(user)
        cases.append({"name": f"{event.get('match_id', 'match')}@{event.get('sim_time', '?')}", "context": context})
    return cases[-limit:] if limit > 0 else cases


def _stub_requests(context: dict) -> list[Request]:
    return [Request(id=row["id"], dept=str(row.get("dept", "")), key=(row["id"],), item=str(row.get("item", row["id"])))
            for row in context["requests"]]


def _chinese_share(text: str) -> float:
    letters = [ch for ch in text if not ch.isspace()]
    return sum("一" <= ch <= "鿿" for ch in letters) / len(letters) if letters else 0.0


def ask_once(context: dict, forward: Callable = forward_openai, clock: Callable = time.perf_counter) -> dict:
    """One ranking call, judged the way the service judges it."""
    schema = rank_schema([row["id"] for row in context["requests"]])
    brief = {"system": RANK_PROMPT, "context": context, "schema": schema, "description": DESCRIPTION,
             "output_tokens": OUTPUT_TOKENS, "orders": (), "statuses": []}
    base = ChatCompletionRequest.model_validate({"model": "replay", "messages": [{"role": "user", "content": "rank"}],
                                                 "metadata": {"match_id": "premier-replay", "team": 0, "tick": 0, "time_sec": 0}})
    plan_req, context_json = plan_request(base, ROLE, brief, "replay")
    started = clock()
    try:
        response, _, raw = forward(plan_req)
    except Exception as exc:  # the report names the failure; credentials and bodies are not kept
        return {"state": "call_failed", "reason": type(exc).__name__, "seconds": round(clock() - started, 3), "input_chars": len(context_json)}
    seconds = round(clock() - started, 3)
    first = response.choices[0] if response.choices else None
    plan, output_format, parse_state = _decode_plan(first, schema)
    usage = raw.get("usage") if isinstance(raw, dict) and isinstance(raw.get("usage"), dict) else {}
    result = {"state": parse_state, "output_format": output_format, "seconds": seconds, "input_chars": len(context_json),
              "completion_tokens": usage.get("completion_tokens"), "finish_reason": first.finish_reason if first else None}
    if plan is None:
        return result
    premier = Premier()
    if not premier.decide(plan, _stub_requests(context), 0.0):
        return {**result, "state": "refused_by_premier"}
    current = {row["id"]: row.get("tier") for row in context["requests"]}
    floors = {row["id"] for row in context["requests"] if row.get("floor")}
    thinking, decision = str(plan["thinking"]).strip(), str(plan["decision"]).strip()
    return {**result, "state": "valid", "posture": plan["posture"], "tiers": plan["tiers"],
            "moved": sum(current.get(rid) != tier for rid, tier in plan["tiers"].items()),
            "floor_overruled": sorted(rid for rid in floors if plan["tiers"].get(rid) in ("later", "hold")),
            "thinking": thinking, "decision": decision,
            "over_length": len(thinking) > THINKING_LIMIT or len(decision) > DECISION_LIMIT,
            "chinese": _chinese_share(thinking + decision) >= .5}


def replay(cases: list[dict], runs: int, forward: Callable = forward_openai, clock: Callable = time.perf_counter) -> dict:
    """Every case `runs` times; the share of answers the service would have applied, and how long they took."""
    results = []
    for case in cases:
        answers = [ask_once(case["context"], forward, clock) for _ in range(runs)]
        results.append({"name": case["name"], "requests": len(case["context"]["requests"]),
                        "valid": sum(a["state"] == "valid" for a in answers), "runs": runs, "answers": answers})
    answers = [a for case in results for a in case["answers"]]
    valid = [a for a in answers if a["state"] == "valid"]
    states: dict[str, int] = {}
    for a in answers:
        states[a["state"]] = states.get(a["state"], 0) + 1
    seconds = sorted(a["seconds"] for a in answers if a["state"] != "call_failed")
    return {"model": runtime_settings.llm_model(), "base_url": runtime_settings.llm_base_url(), "calls": len(answers),
            "valid": len(valid), "valid_rate": round(len(valid) / len(answers), 3) if answers else 0.0, "states": states,
            "seconds_median": round(statistics.median(seconds), 3) if seconds else None, "seconds_max": seconds[-1] if seconds else None,
            "over_length": sum(a["over_length"] for a in valid), "not_chinese": sum(not a["chinese"] for a in valid),
            "floor_overruled": sum(bool(a["floor_overruled"]) for a in valid),
            "kept_every_tier": sum(a["moved"] == 0 for a in valid), "cases": results}


def main(argv: list[str] | None = None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Measure how often a model's premier ranking can be used.")
    parser.add_argument("--log", type=Path, help="take the rankings from this multi_agent.jsonl instead of the built-in situations")
    parser.add_argument("--limit", type=int, default=20, help="newest rankings to take from the log (0 = all)")
    parser.add_argument("--runs", type=int, default=5, help="calls per situation")
    parser.add_argument("--json", type=Path, help="write the full report here")
    parser.add_argument("--min-valid", type=float, default=0.0, help="exit with 1 below this share of usable answers")
    parser.add_argument("--config", default="", help="service config file (default: config.toml beside the service)")
    args = parser.parse_args(argv)
    runtime_settings.load_config(args.config or None)
    cases = cases_from_log(args.log, args.limit) if args.log else sample_cases()
    if not cases:
        print("No premier rankings found.", file=sys.stderr)
        return 2
    report = replay(cases, max(1, args.runs))
    if args.json:
        args.json.write_text(json.dumps(report, ensure_ascii=False, indent=1), encoding="utf-8")
    summary = {key: value for key, value in report.items() if key != "cases"}
    summary["cases"] = [{"name": case["name"], "requests": case["requests"], "valid": f"{case['valid']}/{case['runs']}"} for case in report["cases"]]
    example = next((a for case in report["cases"] for a in case["answers"] if a["state"] == "valid"), None)
    if example:
        summary["example"] = {key: example[key] for key in ("thinking", "decision", "posture", "tiers")}
    print(json.dumps(summary, ensure_ascii=False, indent=1))
    return 0 if report["valid_rate"] >= args.min_valid else 1


if __name__ == "__main__":
    raise SystemExit(main())
