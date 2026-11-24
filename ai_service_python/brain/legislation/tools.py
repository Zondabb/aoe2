"""Flat, action-specific model contracts; identity is bound by the host."""
import copy

TOOL_ACTIONS = {"legislative_" + action: action for action in ("list", "search", "read", "edit", "finish", "blocked")}
ACTION_TOOLS = {action: name for name, action in TOOL_ACTIONS.items()}
ARGUMENTS = {
    "list": ([], ["path", "offset"]),
    "search": (["query"], ["path", "offset"]),
    "read": (["path", "start_line"], ["max_lines"]),
    "edit": (["path", "sha256", "old_text", "new_text"], []),
    "finish": (["state_fields", "explanation"], []),
    "blocked": (["explanation"], []),
}
DESCRIPTIONS = {
    "list": "List files under an optional path prefix.",
    "search": "Find literal query; active cabinet code is searched first.",
    "read": "Read path from start_line. Continue at next_line.",
    "edit": "Replace unique old_text in the read file at sha256.",
    "finish": "Validate drafts; declare new state_fields (or []).",
    "blocked": "Report the specific capability missing for the goal.",
}


def action_tools(schema):
    result = []
    for name, action in TOOL_ACTIONS.items():
        required, optional = ARGUMENTS[action]
        properties = {key: copy.deepcopy(schema["properties"][key]) for key in required + optional + ["note"]}
        properties["note"]["minLength"] = 1
        result.append({"name": name, "description": DESCRIPTIONS[action], "schema": {
            "type": "object", "additionalProperties": False, "properties": properties,
            "required": required + ["note"]}})
    return result


def is_action_tools(names):
    names = list(names)
    return bool(names) and len(set(names)) == len(names) and all(name in TOOL_ACTIONS for name in names)


def native_schema(tools):
    """Each union branch is a complete object, never a partial refinement."""
    branches = []
    for tool in tools:
        schema = copy.deepcopy(tool.function.parameters)
        schema["properties"]["action"] = {"type": "string", "enum": [TOOL_ACTIONS[tool.function.name]]}
        schema["required"] = schema.get("required", []) + ["action"]
        branches.append(schema)
    return {"oneOf": branches}
