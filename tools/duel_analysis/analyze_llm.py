"""LLM planning health per duel service: validity, adoption, latency and choices."""
import json
import statistics
import sys
from collections import Counter
from pathlib import Path

root = Path(sys.argv[1])
for service in sorted(p for p in root.iterdir() if p.is_dir() and p.name.startswith("m")):
    log = service / "logs" / "multi_agent.jsonl"
    if not log.exists():
        continue
    states, parse, roles, choices = Counter(), Counter(), Counter(), Counter()
    elapsed, changed, failed, requests = [], 0, Counter(), 0
    for line in log.read_text(encoding="utf-8").splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        kind = event.get("event")
        if kind == "model_request":
            requests += 1
        elif kind == "model_failed":
            failed[event.get("reason")] += 1
        elif kind == "model_result":
            states[event.get("state")] += 1
            parse[event.get("parse_state")] += 1
            roles[event.get("agent")] += 1
            if event.get("elapsed_ms") is not None:
                elapsed.append(float(event["elapsed_ms"]))
            if event.get("plan_changed"):
                changed += 1
            plan = event.get("plan") or {}
            if event.get("state") == "applied":
                for key in ("strategy", "composition", "target_priority", "stance"):
                    if key in plan:
                        choices[f"{key}={plan[key]}"] += 1
    total = sum(states.values())
    median = statistics.median(elapsed) / 1000 if elapsed else 0
    p90 = sorted(elapsed)[int(len(elapsed) * .9) - 1] / 1000 if len(elapsed) >= 10 else max(elapsed or [0]) / 1000
    print(f"{service.name}: requests={requests} results={total} applied={states['applied']} "
          f"changed={changed} valid={parse['valid']} failed={sum(failed.values())} "
          f"latency_s median={median:.1f} p90={p90:.1f}")
    print(f"    states={dict(states)} failures={dict(failed)}")
    print(f"    roles={dict(roles)}")
    if choices:
        print(f"    applied choices={dict(choices.most_common(10))}")
