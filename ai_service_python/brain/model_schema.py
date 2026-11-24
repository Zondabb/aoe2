"""Provider-facing planner schemas; full validation stays in the scheduler.

Some tool renderers treat a partial oneOf branch as the entire function
signature and lose the root fields. Keep a single complete object signature
on the wire, while retaining the original cross-field rules for local checks.
"""
from __future__ import annotations

import copy


def planner_tool_schema(schema: dict) -> dict:
    result = copy.deepcopy(schema)

    def lower(node):
        if not isinstance(node, dict):
            return
        variants = node.get("anyOf")
        if isinstance(variants, list) and len(variants) == 2:
            null = next((v for v in variants if v == {"type": "null"}), None)
            obj = next((v for v in variants if v.get("type") == "object"), None)
            if null is not None and obj is not None:
                node.pop("anyOf")
                node.update(copy.deepcopy(obj))
                node["type"] = ["object", "null"]
        # These are refinements of root properties, not alternative complete
        # function signatures. Their constraints remain in the host schema.
        branches = node.get("oneOf")
        if (node.get("type") == "object" and node.get("properties") and branches
                and all(set(branch) <= {"properties", "required"} for branch in branches)):
            node.pop("oneOf")
        conditions = node.get("allOf")
        if conditions and all(set(rule) == {"if", "then"} for rule in conditions):
            for rule in conditions:
                for name, condition in rule["if"].get("properties", {}).items():
                    if name in node.get("properties", {}) and "const" in condition:
                        prop = node["properties"][name]
                        required = rule["then"].get("required", [])
                        if required:
                            prop["description"] = (prop.get("description", "") +
                                f" For {condition['const']}, also supply: {', '.join(required)}.").strip()
            node.pop("allOf")
        if "const" in node:
            value = node.pop("const")
            node["enum"] = [value]
            if "type" not in node:
                kind = {str: "string", int: "integer", float: "number", bool: "boolean", type(None): "null"}.get(type(value))
                if kind:
                    node["type"] = kind
        for prop in node.get("properties", {}).values():
            lower(prop)
        lower(node.get("items"))
        for key in ("anyOf", "oneOf", "allOf"):
            for child in node.get(key, []):
                lower(child)

    lower(result)
    return result
