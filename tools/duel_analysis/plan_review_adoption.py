"""How often the model adopts plan_review suggestions, per duel service.

Usage: python tools/duel_analysis/plan_review_adoption.py DUEL_DIR [DUEL_DIR ...]

Reads llm_io (the context sent to the model) and model_result (the plan it
returned) from each service's multi_agent.jsonl and matches them by request_id.
A suggestion counts as adopted when the returned plan sets that field to the
suggested value. Services without plan_review in their context report only
how often their plans changed.
"""
import json
import sys
from collections import Counter
from pathlib import Path


def events(log: Path):
    for path in sorted(log.parent.glob(log.name + "*")):
        for line in path.read_text(encoding="utf-8").splitlines():
            try:
                yield json.loads(line)
            except ValueError:
                continue


def analyze(service: Path) -> dict:
    log = service / "logs" / "multi_agent.jsonl"
    reviews, results = {}, {}
    for event in events(log):
        kind, rid = event.get("event"), event.get("request_id")
        if kind == "llm_io" and rid:
            messages = (event.get("input") or {}).get("messages") or []
            user = next((m.get("content") for m in messages if m.get("role") == "user"), None)
            try:
                context = json.loads(user) if user else {}
            except ValueError:
                context = {}
            reviews[rid] = context.get("plan_review")
        elif kind == "model_result" and rid:
            results[rid] = event
    with_review = notes = adopted = changed = applied = 0
    by_field, adopted_by_field = Counter(), Counter()
    for rid, result in results.items():
        if result.get("state") != "applied":
            continue
        applied += 1
        changed += bool(result.get("plan_changed"))
        review = reviews.get(rid)
        if not review:
            continue
        with_review += 1
        plan = result.get("plan") or {}
        for note in review:
            notes += 1
            by_field[note["field"]] += 1
            if plan.get(note["field"]) == note.get("suggested"):
                adopted += 1
                adopted_by_field[note["field"]] += 1
    has_review = any(value is not None for value in reviews.values())
    return {"applied": applied, "changed": changed, "has_plan_review": has_review, "requests_with_notes": with_review,
            "notes": notes, "adopted": adopted, "by_field": {k: f"{adopted_by_field[k]}/{v}" for k, v in by_field.most_common()}}


def main() -> None:
    for folder in sys.argv[1:]:
        root = Path(folder)
        for service in sorted(p for p in root.iterdir() if p.is_dir() and p.name.startswith("m") and "-team" in p.name):
            row = analyze(service)
            print(f"{root.name} {service.name}: " + " ".join(f"{k}={v}" for k, v in row.items()))


if __name__ == "__main__":
    main()
