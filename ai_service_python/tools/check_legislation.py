"""Check whether the legislative council took effect for a match.
Usage: python check_legislation.py <match_id> [ai_service_python_dir]
Read-only: scans logs/multi_agent.jsonl* and legislation_data/sessions.sqlite3.
"""
from collections import Counter
import glob
import json
import os
from pathlib import Path
import sqlite3
import sys


def _step_target(plan: dict | None, parse_state: str | None) -> str:
    if not plan:
        return f"parse_state={parse_state}"
    action = plan.get("action")
    path = plan.get("path")
    if action == "read":
        return f"{path}:L{plan.get('start_line')}"
    if action in ("edit", "list"):
        return str(path)
    if action == "search":
        suffix = f" ({path})" if path else ""
        return f"query={plan.get('query')!r}{suffix}"
    if action == "finish":
        names = [f.get("name") for f in (plan.get("state_fields") or []) if isinstance(f, dict)]
        return f"state_fields={names}"
    if action == "blocked":
        return f"blocked: {str(plan.get('explanation') or '')[:80]}"
    return str(path)


def main() -> int:
    mid = sys.argv[1]
    root = sys.argv[2] if len(sys.argv) > 2 else str(Path(__file__).resolve().parents[1])
    logs = sorted(glob.glob(os.path.join(root, "logs", "multi_agent.jsonl*")), reverse=True)  # .3 .2 .1 then current

    print("== 1. 指令/法案台账 (event=order)")
    steps = []
    for path in logs:
        with open(path, encoding="utf-8") as f:
            for line in f:
                if mid not in line:
                    continue
                d = json.loads(line)
                ev = d.get("event")
                if ev == "order":
                    change = d.get("change")
                    if change != "legislation_progress":
                        print(f"  t={d['sim_time']:.0f}s team={d['team']} #{d['id']} {change:<22} {d['status']:<6} {d['text']}"
                              + (f"  reason={d.get('reason')}" if d.get("reason") else ""))
                    elif d.get("phase") == "retrying":
                        print(f"  t={d['sim_time']:.0f}s team={d['team']} #{d['id']} retrying               "
                              f"{d.get('proposal_id')} step={d.get('step')} reason={d.get('reason')}")
                elif ev in ("legislation_rollback", "legislation_failed", "legislation_revoked"):
                    print(f"  !! t={d.get('sim_time', 0):.0f}s team={d.get('team')} {ev} "
                          f"release={str(d.get('release') or '')[:12]} reason={d.get('reason')}")
                elif ev == "model_result" and d.get("agent") == "legislative_council":
                    p = d.get("plan") or {}
                    steps.append((
                        d["sim_time"],
                        p.get("proposal_id") or "unknown",
                        d.get("legislation_step"),
                        p.get("action"),
                        _step_target(p if p else None, d.get("parse_state")),
                        d.get("state"),
                    ))
                elif ev in ("cabinet_worker_start_failed",) or (ev == "model_failed" and d.get("agent") == "legislative_council"):
                    print("  !!", json.dumps(d, ensure_ascii=False)[:300])

    print("\n== 2. 立法会编程步骤 (agent=legislative_council)")
    print("  动作统计:", dict(Counter(s[3] for s in steps)))
    grouped: dict[str, list] = {}
    for s in steps:
        grouped.setdefault(s[1], []).append(s)
    for proposal_id, items in grouped.items():
        print(f"  [{proposal_id}] ({len(items)} steps)")
        for s in items[-10:]:
            print(f"    t={s[0]:.0f}s step={s[2]} {s[3]} {s[4]} -> {s[5]}")

    print("\n== 3. 会话当前源码版本 (sessions.sqlite3)")
    db = os.path.join(root, "legislation_data", "sessions.sqlite3")
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    for ident, payload in con.execute("select identity, payload from sessions where identity like ?", (f"%{mid}%",)):
        d = json.loads(payload)
        installed = d.get("release") != d.get("base")
        print(f"  {ident}\n    base   ={d.get('base')}\n    release={d.get('release')}\n"
              f"    => {'已安装新法案 (生效)' if installed else '仍是内建版本 (未生效)'}")
        coding = d.get("coding")
        if coding:
            cdata = coding.get("data") or {}
            fb = cdata.get("feedback") or {}
            msg = fb.get("error") or fb.get("reason") or ""
            print(f"    coding : proposal={coding.get('requirement', {}).get('proposal_id')} "
                  f"status={cdata.get('status')} steps={cdata.get('steps')} failures={cdata.get('failures')}"
                  + (f" feedback={msg[:160]}" if msg else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
