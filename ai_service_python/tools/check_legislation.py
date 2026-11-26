"""Check whether the legislative council took effect for a match.
Usage: python check_legislation.py <match_id> [ai_service_python_dir]
Read-only: scans logs/multi_agent.jsonl* and legislation_data/sessions.sqlite3.
"""
import glob, json, os, sqlite3, sys
from pathlib import Path

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
            if ev == "order" and d.get("change") != "legislation_progress":
                print(f"  t={d['sim_time']:.0f}s team={d['team']} #{d['id']} {d['change']:<22} {d['status']:<6} {d['text']}"
                      + (f"  reason={d.get('reason')}" if d.get("reason") else ""))
            elif ev == "model_result" and d.get("agent") == "legislative_council":
                p = d.get("plan") or {}
                steps.append((d["sim_time"], d.get("legislation_step"), p.get("action"), p.get("path"), d.get("state")))
            elif ev in ("cabinet_worker_start_failed",) or (ev == "model_failed" and d.get("agent") == "legislative_council"):
                print("  !!", json.dumps(d, ensure_ascii=False)[:300])

print("\n== 2. 立法会编程步骤 (agent=legislative_council)")
from collections import Counter
print("  动作统计:", dict(Counter(s[2] for s in steps)))
for s in steps[-5:]:
    print(f"  t={s[0]:.0f}s step={s[1]} {s[2]} {s[3]} -> {s[4]}")

print("\n== 3. 会话当前源码版本 (sessions.sqlite3)")
db = os.path.join(root, "legislation_data", "sessions.sqlite3")
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
for ident, payload in con.execute("select identity, payload from sessions where identity like ?", (f"%{mid}%",)):
    d = json.loads(payload)
    installed = d.get("release") != d.get("base")
    print(f"  {ident}\n    base   ={d.get('base')}\n    release={d.get('release')}\n    => {'已安装新法案 (生效)' if installed else '仍是内建版本 (未生效)'}")
