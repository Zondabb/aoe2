#!/usr/bin/env python3
"""Put sample orders to the configured model as the cabinet's premier, and check the mandates that come out.

The service sends exactly this request when a player types an order
(brain/cabinet/premier.py, brain/cabinet/runtime.py): the order, the name
table of the catalog and the civilization. The answer goes through the same
catalog check, and a reading the catalog refuses is asked for once more with
the reason, as in a match. Run it against a model before relying on that
model to read orders in a game.

Usage, from ai_service_python:
  python tools/order_replay.py                        the sample orders in data/order_samples.json, 3 runs each
  python tools/order_replay.py --grade approx --runs 5
  python tools/order_replay.py --say "囤积50个游侠" --civ chinese --age 2
                                                      one order of your own; shows what would be carried out
  python tools/order_replay.py --json report.json --min-match 0.8

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
from brain.cabinet.ledger import MAX_TRIES, NEW, OrderLedger  # noqa: E402
from brain.cabinet.models import order_origin  # noqa: E402
from brain.cabinet.orders import GRASPS, KIND_DEPT, NAMES, ground_reading, name_of  # noqa: E402
from brain.cabinet.premier import (DECISION_LIMIT, INTERPRET_PROMPT, ORDERS_ROLE, OUTPUT_TOKENS, THINKING_LIMIT,  # noqa: E402
                                   interpret_context, interpret_schema, reading)
from brain.llm_proxy import forward_openai  # noqa: E402
from brain.multi_agent.scheduler import _decode_plan, plan_request  # noqa: E402
from protocol.models import ChatCompletionRequest  # noqa: E402

SAMPLES = Path(__file__).resolve().parents[1] / "data" / "order_samples.json"
DESCRIPTION = "Read the head of state's order into mandates for the departments."


def load_samples(path: Path = SAMPLES) -> list[dict]:
    samples = json.loads(path.read_text(encoding="utf-8"))["samples"]
    for sample in samples:
        if sample.get("grade") not in GRASPS or sample.get("civ") not in NAMES["civilizations"] or not str(sample.get("text", "")).strip():
            raise ValueError(f"order sample {sample!r}: needs a grade, a known civ and a text")
        for outcome in sample["accept"]:
            for kind, _subject, _amount in outcome:
                if kind not in KIND_DEPT:
                    raise ValueError(f"order sample {sample['text']!r}: {kind} is not a kind of mandate")
    return samples


def _chinese_share(text: str) -> float:
    letters = [ch for ch in text if not ch.isspace()]
    return sum("一" <= ch <= "鿿" for ch in letters) / len(letters) if letters else 0.0


def ask_once(context: dict, forward: Callable = forward_openai, clock: Callable = time.perf_counter) -> dict:
    """One call to read an order, decoded the way the service decodes it."""
    schema = interpret_schema()
    brief = {"system": INTERPRET_PROMPT, "context": context, "schema": schema, "description": DESCRIPTION,
             "output_tokens": OUTPUT_TOKENS, "orders": (), "statuses": []}
    base = ChatCompletionRequest.model_validate({"model": "replay", "messages": [{"role": "user", "content": "read"}],
                                                 "metadata": {"match_id": "order-replay", "team": 0, "tick": 0, "time_sec": 0}})
    plan_req, context_json = plan_request(base, ORDERS_ROLE, brief, "replay")
    started = clock()
    try:
        response, _, raw = forward(plan_req)
    except Exception as exc:  # the report names the failure; credentials and bodies are not kept
        return {"state": "call_failed", "reason": type(exc).__name__, "seconds": round(clock() - started, 3),
                "input_chars": len(context_json), "plan": None}
    first = response.choices[0] if response.choices else None
    plan, _output_format, parse_state = _decode_plan(first, schema)
    return {"state": parse_state, "seconds": round(clock() - started, 3), "input_chars": len(context_json), "plan": plan,
            "finish_reason": first.finish_reason if first else None}


def read_order(sample: dict, forward: Callable = forward_openai, clock: Callable = time.perf_counter) -> dict:
    """One order through the ledger, as in a match: read, checked against the catalog, sent back once if refused."""
    ledger = OrderLedger()
    order = ledger.intake([sample["text"]], 0.0)[0]
    calls, state = [], "unread"
    while order.status == NEW and len(calls) < MAX_TRIES:
        previous = {"mandates": order.refused, "problem": order.problem} if order.problem else None
        answer = ask_once(interpret_context(order.text, [], sample["civ"], sample["age"], previous), forward, clock)
        calls.append(answer)
        read = reading(answer["plan"]) if answer["plan"] is not None else None
        if read is None:
            # Nothing usable: in a match the order waits and is asked about again later.
            state = answer["state"] if answer["plan"] is None else "not_a_reading"
            break
        grasp, thinking, decision, raw = read
        state = ledger.accept(order, grasp, thinking, decision, ground_reading(grasp, raw, sample["civ"], sample["age"],
                                                                               order_origin(order.number)), raw)
    mandates = [[m.kind, m.subject, m.amount, m.urgency] for m in order.mandates]
    texts = (order.thinking + order.decision) if order.grasp else ""
    said = [c["plan"] for c in calls if isinstance(c["plan"], dict)]
    over_length = any(len(str(plan.get("thinking", "")).strip()) > THINKING_LIMIT or len(str(plan.get("decision", "")).strip()) > DECISION_LIMIT
                      for plan in said)
    return {"state": state if order.status == NEW else order.status, "grasp": order.grasp, "mandates": mandates,
            "named": [name_of(m.subject) for m in order.mandates if m.subject], "notes": list(order.notes),
            "thinking": order.thinking, "decision": order.decision, "calls": len(calls),
            "seconds": round(sum(c["seconds"] for c in calls), 3), "input_chars": calls[0]["input_chars"] if calls else 0,
            "usable": order.status != NEW, "sent_back": order.tries > 1,
            "over_length": over_length,
            "chinese": _chinese_share(texts) >= .5 if texts else None}


def matches(sample: dict, outcome: dict) -> bool:
    """Whether what came out is one of the outcomes the sample accepts."""
    if not sample["accept"]:
        return outcome["usable"] and not outcome["mandates"]
    fits = lambda want, got: want[0] == got[0] and (want[1] is None or want[1] == got[1]) and (want[2] is None or want[2] == got[2])
    return any(all(any(fits(want, got) for got in outcome["mandates"]) for want in accepted) for accepted in sample["accept"])


def replay(samples: list[dict], runs: int, forward: Callable = forward_openai, clock: Callable = time.perf_counter) -> dict:
    """Every sample `runs` times: how often the model's reading could be used, and how often it was the right one."""
    rows = []
    for sample in samples:
        outcomes = [read_order(sample, forward, clock) for _ in range(runs)]
        for outcome in outcomes:
            outcome["matched"] = matches(sample, outcome)
        rows.append({"text": sample["text"], "grade": sample["grade"], "civ": sample["civ"], "age": sample["age"], "runs": runs,
                     "usable": sum(o["usable"] for o in outcomes), "matched": sum(o["matched"] for o in outcomes), "outcomes": outcomes})
    outcomes = [o for row in rows for o in row["outcomes"]]
    share = lambda part, whole: round(part / whole, 3) if whole else 0.0
    grades = {}
    for grade in GRASPS:
        mine = [o for row in rows if row["grade"] == grade for o in row["outcomes"]]
        if mine:
            grades[grade] = {"orders": len(mine), "usable": sum(o["usable"] for o in mine), "matched": sum(o["matched"] for o in mine),
                             "same_grade": sum(o["grasp"] == grade for o in mine)}
    states: dict[str, int] = {}
    for outcome in outcomes:
        states[outcome["state"]] = states.get(outcome["state"], 0) + 1
    seconds = sorted(o["seconds"] for o in outcomes if o["calls"])
    usable = [o for o in outcomes if o["usable"]]
    return {"model": runtime_settings.llm_model(), "base_url": runtime_settings.llm_base_url(), "orders": len(outcomes),
            "calls": sum(o["calls"] for o in outcomes), "usable": len(usable), "usable_rate": share(len(usable), len(outcomes)),
            "matched": sum(o["matched"] for o in outcomes), "match_rate": share(sum(o["matched"] for o in outcomes), len(outcomes)),
            "states": states, "grades": grades, "sent_back": sum(o["sent_back"] for o in outcomes),
            "seconds_median": round(statistics.median(seconds), 3) if seconds else None, "seconds_max": seconds[-1] if seconds else None,
            "input_chars": max((o["input_chars"] for o in outcomes), default=0),
            "over_length": sum(o["over_length"] for o in usable), "not_chinese": sum(o["chinese"] is False for o in usable),
            "samples": rows}


def main(argv: list[str] | None = None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Check how a model reads the head of state's orders.")
    parser.add_argument("--samples", type=Path, default=SAMPLES, help="the sample orders (default: data/order_samples.json)")
    parser.add_argument("--grade", choices=GRASPS, help="only the samples of this grade")
    parser.add_argument("--say", help="read this one order instead of the samples")
    parser.add_argument("--civ", default="teutons", choices=sorted(NAMES["civilizations"]), help="civilization for --say")
    parser.add_argument("--age", type=int, default=2, choices=range(4), help="age for --say: 0 dark, 1 feudal, 2 castle, 3 imperial")
    parser.add_argument("--runs", type=int, default=3, help="readings per order")
    parser.add_argument("--json", type=Path, help="write the full report here")
    parser.add_argument("--min-match", type=float, default=0.0, help="exit with 1 below this share of orders read as the samples accept")
    parser.add_argument("--config", default="", help="service config file (default: config.toml beside the service)")
    args = parser.parse_args(argv)
    runtime_settings.load_config(args.config or None)
    if args.say:
        outcome = read_order({"text": args.say, "civ": args.civ, "age": args.age})
        print(json.dumps({key: outcome[key] for key in ("state", "grasp", "mandates", "named", "notes", "thinking", "decision", "calls", "seconds")},
                         ensure_ascii=False, indent=1))
        return 0 if outcome["usable"] else 1
    samples = [sample for sample in load_samples(args.samples) if args.grade in (None, sample["grade"])]
    if not samples:
        print("No sample orders.", file=sys.stderr)
        return 2
    report = replay(samples, max(1, args.runs))
    if args.json:
        args.json.write_text(json.dumps(report, ensure_ascii=False, indent=1), encoding="utf-8")
    summary = {key: value for key, value in report.items() if key != "samples"}
    summary["samples"] = [{"text": row["text"], "grade": row["grade"], "civ": row["civ"], "matched": f"{row['matched']}/{row['runs']}",
                           "last": [row["outcomes"][-1]["grasp"] or row["outcomes"][-1]["state"], *row["outcomes"][-1]["mandates"]]}
                          for row in report["samples"]]
    print(json.dumps(summary, ensure_ascii=False, indent=1))
    return 0 if report["match_rate"] >= args.min_match else 1


if __name__ == "__main__":
    raise SystemExit(main())
