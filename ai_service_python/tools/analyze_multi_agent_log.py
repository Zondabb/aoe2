#!/usr/bin/env python3
"""Summarize multi-agent JSONL logs without conflating plan validity and expiry.

Usage: python tools/analyze_multi_agent_log.py [logs/*.jsonl ...] [--json]
Only request summaries are retained in memory; raw prompts/responses are not.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import json
import math
from pathlib import Path
import statistics
import sys


DEFAULT_LOG = Path(__file__).resolve().parents[1] / "logs" / "multi_agent.jsonl"
RESULT_EVENTS = {"model_result", "model_failed"}


def _baseline(messages: list) -> dict | None:
    for message in reversed(messages):
        if message.get("role") != "user":
            continue
        try:
            context = json.loads(message.get("content") or "")
        except (ValueError, TypeError):
            continue
        if isinstance(context, dict) and isinstance(context.get("plan"), dict):
            return context["plan"]
    return None


def _io_summary(row: dict) -> dict:
    outbound, inbound = row.get("input") or {}, row.get("output") or {}
    choices = inbound.get("choices") or []
    choice = choices[0] if choices and isinstance(choices[0], dict) else {}
    native = not choices and isinstance(inbound.get("message"), dict)
    message = inbound["message"] if native else choice.get("message") or {}
    calls = message.get("tool_calls") or []
    content = message.get("content") or ""
    form = "empty"
    if calls:
        form = "tool_calls"
    elif content:
        try:
            json.loads(content)
            form = "content_json"
        except (ValueError, TypeError):
            form = "content_text"
    usage = inbound.get("usage") or {}
    if native and not usage and any(key in inbound for key in ("prompt_eval_count", "eval_count")):
        usage = {"prompt_tokens": inbound.get("prompt_eval_count", 0),
                 "completion_tokens": inbound.get("eval_count", 0)}
        usage["total_tokens"] = sum(value for value in usage.values() if isinstance(value, int))
    return {"baseline": _baseline(outbound.get("messages") or []),
            "usage": usage, "form": form,
            "transport": "ollama_native" if native else "openai_compatible" if choices else "unknown",
            "reasoning_chars": len(message.get("reasoning") or message.get("reasoning_content")
                                   or message.get("thinking") or ""),
            "finish_reason": inbound.get("done_reason", "incomplete") if native else choice.get("finish_reason")}


def _latency(values: list[float]) -> dict:
    if not values:
        return {"samples": 0}
    values = sorted(values)
    return {"samples": len(values), "min_ms": round(values[0], 2),
            "median_ms": round(statistics.median(values), 2),
            "p95_ms": round(values[math.ceil(len(values) * .95) - 1], 2),
            "max_ms": round(values[-1], 2)}


def _validity(result: dict) -> str:
    # The scheduler validates and stores plan before applying TTL/goal guards.
    # Consequently plan_expired with plan=null is also an invalid model output.
    if result.get("event") == "model_failed":
        return "transport_failed"
    if result.get("parse_state"):
        return "valid" if result["parse_state"] == "valid" else "invalid"
    if "plan" in result:
        return "valid" if isinstance(result["plan"], dict) else "invalid"
    return "unknown"


def analyze(paths: list[Path]) -> dict:
    events, requests, ios, results = Counter(), {}, {}, {}
    issues, files = [], []
    for path in paths:
        lines = 0
        try:
            with path.open(encoding="utf-8-sig") as source:
                for lines, line in enumerate(source, 1):
                    if not line.strip():
                        continue
                    try:
                        row = json.loads(line)
                        if not isinstance(row, dict):
                            raise ValueError("expected an object")
                    except (ValueError, TypeError) as exc:
                        issues.append(f"{path}:{lines}: {exc}")
                        continue
                    event = row.get("event", "unknown")
                    events[event] += 1
                    request_id = row.get("request_id")
                    if not request_id:
                        continue
                    # Repeated request IDs across rotated/overlapping files count once.
                    if event == "model_request":
                        requests[request_id] = {"agent": row.get("agent", "unknown"),
                            "baseline": _baseline(row.get("messages") or [])}
                    elif event == "llm_io":
                        ios[request_id] = _io_summary(row)
                    elif event in RESULT_EVENTS:
                        results[request_id] = row
        except OSError as exc:
            issues.append(f"{path}: {exc}")
        files.append({"path": str(path.resolve()), "lines": lines})

    def bucket() -> dict:
        return {"requests": 0, "results": 0, "states": Counter(),
                "output_validity": Counter(), "parse_states": Counter(), "output_forms": Counter(),
                "transports": Counter(), "finish_reasons": Counter(),
                "applied_changes": Counter(), "latency": [], "tokens": Counter(),
                "usage_samples": 0, "prompt_token_counts": Counter(),
                "reasoning_samples": 0, "reasoning_chars": 0}

    overall, roles = bucket(), defaultdict(bucket)
    for request in requests.values():
        overall["requests"] += 1
        roles[request["agent"]]["requests"] += 1
    prior_plans = {}
    for request_id, result in sorted(results.items(), key=lambda item: item[1].get("wall_time", 0)):
        role = result.get("agent", requests.get(request_id, {}).get("agent", "unknown"))
        io = ios.get(request_id, {})
        usage = result.get("usage") or io.get("usage") or {}
        state = result.get("state") or result.get("reason") or "unknown"
        session_role = (result.get("match_id"), result.get("team"), result.get("session_epoch"), role)
        change = None
        if state in {"applied", "unchanged"} and isinstance(result.get("plan"), dict):
            previous = prior_plans.get(session_role)
            if previous is None:
                previous = io.get("baseline") or requests.get(request_id, {}).get("baseline")
            change = ("unknown" if previous is None else
                      "unchanged" if previous == result["plan"] else "changed")
            if isinstance(result.get("plan_changed"), bool):
                change = "changed" if result["plan_changed"] else "unchanged"
            prior_plans[session_role] = result["plan"]
        for target in (overall, roles[role]):
            target["results"] += 1
            target["states"][state] += 1
            target["output_validity"][_validity(result)] += 1
            if result.get("parse_state"):
                target["parse_states"][result["parse_state"]] += 1
            if result.get("output_format"):
                target["output_forms"][result["output_format"]] += 1
            elif io:
                target["output_forms"][io["form"]] += 1
            if io:
                target["transports"][io["transport"]] += 1
                if io.get("finish_reason"):
                    target["finish_reasons"][io["finish_reason"]] += 1
            elapsed = result.get("elapsed_ms")
            if isinstance(elapsed, (int, float)) and math.isfinite(elapsed):
                target["latency"].append(elapsed)
            if usage:
                target["usage_samples"] += 1
                for name in ("prompt_tokens", "completion_tokens", "total_tokens"):
                    value = usage.get(name)
                    if isinstance(value, int):
                        target["tokens"][name] += value
                prompt_tokens = usage.get("prompt_tokens")
                if isinstance(prompt_tokens, int):
                    target["prompt_token_counts"][str(prompt_tokens)] += 1
            if io.get("reasoning_chars", 0):
                target["reasoning_samples"] += 1
                target["reasoning_chars"] += io["reasoning_chars"]
            if change:
                target["applied_changes"][change] += 1

    def finish(target: dict) -> dict:
        target["latency"] = _latency(target["latency"])
        target["applied_percent"] = round(100 * sum(target["states"].get(s, 0)
            for s in ("applied", "unchanged")) / target["results"], 2) if target["results"] else 0
        return {key: dict(value) if isinstance(value, Counter) else value for key, value in target.items()}

    warnings = []
    count = overall["prompt_token_counts"].get("2050", 0)
    if count >= 2:
        warnings.append(f"{count} results report exactly 2050 prompt tokens; repeated clipping near "
                        "2048 is a context-truncation signal, not proof. Check Ollama context size "
                        "and compare full input sizes; max_tokens is an output budget.")
    if overall["applied_changes"].get("unknown"):
        warnings.append("Initial applied plans without logged request context have an unknown baseline; "
                        "they are not counted as changed or unchanged.")
    if events["model_result"] + events["model_failed"] > len(results):
        warnings.append("Overlapping result request IDs were deduplicated; event counts include all rows.")
    return {"files": files, "events": dict(events), "overall": finish(overall),
            "roles": {role: finish(value) for role, value in sorted(roles.items())},
            "warnings": warnings, "read_errors": issues}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", type=Path, help="JSONL logs; defaults to logs/multi_agent.jsonl")
    parser.add_argument("--json", action="store_true", help="Emit a machine-readable report")
    args = parser.parse_args()
    report = analyze(args.paths or [DEFAULT_LOG])
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        for name, stats in [("overall", report["overall"]), *report["roles"].items()]:
            print(f"{name}: requests={stats['requests']} results={stats['results']} "
                  f"applied={stats['applied_percent']}%")
            for key in ("states", "output_validity", "parse_states", "output_forms", "transports", "finish_reasons", "applied_changes", "latency", "tokens"):
                print(f"  {key}: {json.dumps(stats[key], ensure_ascii=False)}")
        for warning in report["warnings"]:
            print(f"WARNING: {warning}")
        for error in report["read_errors"]:
            print(f"ERROR: {error}", file=sys.stderr)
    return 1 if report["read_errors"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
