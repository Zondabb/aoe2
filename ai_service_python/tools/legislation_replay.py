"""Replay a frozen bill in memory; never install code or alter match sessions.

Default is offline inspection. --live explicitly enables bounded model calls.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from brain import runtime_settings
from brain.legislation.agent import CodingSession
from brain.legislation.releases import ReleaseStore, apply_diff
from brain.llm_proxy import forward_openai
from brain.multi_agent.scheduler import plan_request, _decode_plan
from protocol.models import ChatCompletionRequest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="")
    parser.add_argument("--log", default="logs/multi_agent.jsonl")
    parser.add_argument("--match", required=True)
    parser.add_argument("--team", type=int, default=0)
    parser.add_argument("--max-steps", type=int, default=12)
    parser.add_argument("--live", action="store_true")
    args = parser.parse_args()
    if not 1 <= args.max_steps <= 24:
        parser.error("--max-steps must be 1..24")
    runtime_settings.load_config(args.config or None)
    context = None
    with Path(args.log).open(encoding="utf-8") as stream:
        for line in stream:
            row = json.loads(line)
            if (row.get("match_id") == args.match and row.get("team") == args.team
                    and row.get("agent") == "legislative_council" and row.get("event") == "llm_io"):
                context = json.loads(row["input"]["messages"][1]["content"])
                break
    if context is None:
        raise ValueError("No frozen legislative request in this match")
    store = ReleaseStore(Path(runtime_settings.legislation_options()["root"]) / "source")
    session = CodingSession(store, context["legislation"], context["base_release"])
    base = ChatCompletionRequest(model="replay", messages=[], metadata={"match_id": "isolated-replay", "team": args.team})
    if not args.live:
        brief = session.brief()
        print(json.dumps({"mode": "offline", "source_map": brief["context"]["source_map"],
                          "tools": {t["name"]: t["schema"]["required"] for t in brief["tools"]}}, ensure_ascii=False))
        return 0
    for index in range(args.max_steps):
        brief = session.brief()
        brief.update(orders=(), statuses=[])
        req, _ = plan_request(base, "legislative_council", brief, f"replay-{index}")
        started = time.monotonic()
        try:
            response, _, _ = forward_openai(req)
        except Exception as exc:
            print(json.dumps({"step": index, "transport_error": type(exc).__name__, "stopped": True}), flush=True)
            return 2  # No automatic network retry, and no URL/credentials in output.
        diagnostics = {}
        plan, _, state = _decode_plan(response.choices[0] if response.choices else None, brief["schema"],
            diagnostics=diagnostics, tool_schemas={t.function.name: t.function.parameters for t in req.tools})
        proposal = None
        if plan is None:
            session.reject(state + ": " + diagnostics.get("problem", ""))
        else:
            proposal = session.apply(plan)
            if diagnostics.get("tool_selection") and not session.data["failures"]:
                notice = diagnostics["tool_selection"]
                notice.update(executed=True, message="Only the selected read-only call was executed; other calls were not executed.")
                notice["unexecuted_calls"] = [i for i in range(1, notice["received_calls"] + 1) if i != notice["selected_call"]]
                session.data["feedback"]["tool_selection"] = notice
        print(json.dumps({"step": index, "action": plan.get("action") if plan else None,
            "parse_state": state, "status": session.status, "elapsed_sec": round(time.monotonic()-started, 2),
            "reason": session.data["feedback"].get("error", session.data["feedback"].get("reason")),
            "changed_files": list(session.data["drafts"])}, ensure_ascii=False), flush=True)
        if proposal:
            originals = {p: (session.root / p).read_text(encoding="utf-8") for p in session.data["drafts"]}
            assert apply_diff(originals, proposal["unified_diff"]) == session.data["drafts"]
            print(json.dumps({"patch_validated": True, "installed": False}), flush=True)
            return 0
        if session.status != "coding":
            return 0 if session.status == "blocked" else 1
    print(json.dumps({"stopped": True, "reason": "replay_call_limit", "installed": False}), flush=True)
    return 1


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    raise SystemExit(main())
