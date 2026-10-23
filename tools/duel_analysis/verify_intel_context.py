"""One-off verification: context size per role and schema validity of defaults."""
import json

from jsonschema import Draft202012Validator

import brain.multi_agent.runtime as rt
from test_llm_commander import building, unit
from test_siege_strategy import battle

types = ["militia", "archer", "knight", "spearman", "skirmisher", "man_at_arms"]
entities = ([building(1, "town_center"), building(2, "barracks")]
            + [unit(1000 + i, types[i % 6], [30 + i % 10, 30 + i // 10]) for i in range(60)]
            + [unit(2000 + i) for i in range(30)]
            + [unit(3000 + i, types[(i + 2) % 6], [45 + i % 8, 40 + i // 8], team=1) for i in range(40)])
runtime = rt.MultiAgentRuntime("chinese")
runtime.tick(battle(entities, age=2))
for role in runtime.roles:
    context = runtime.planning_context(role)
    size = len(json.dumps(context, ensure_ascii=False, separators=(",", ":")))
    Draft202012Validator(rt.ROLE_SCHEMAS[role]).validate(runtime.roles[role].plan)
    print(f"{role:<13} context_chars={size:>6} has_intel={'intel' in context} schema_ok")
print(json.dumps(runtime.planning_context("commander")["intel"], ensure_ascii=False)[:1200])
