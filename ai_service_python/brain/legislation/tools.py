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
    "list": "List .py files under a directory prefix (use read, not list, for a .py file).",
    "search": "Find literal query; active cabinet code is searched first.",
    "read": "Read source lines of path from start_line. Continue at next_line only when truncated is true (stop when eof is true).",
    "edit": "Replace unique old_text in the just-read writable file at sha256 (clears read view; call finish next, or read again before another edit).",
    "finish": "Validate drafts; pass state_fields=[] unless your code assigns new self.<attr> on the department (never list methods or option keys).",
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
    """Each union branch is a complete object led by its action discriminator.

    Putting ``action`` first lets grammar-constrained decoders (such as Ollama's
    GBNF generator) select the intended branch before emitting ``note`` or
    branch-specific arguments, instead of collapsing into ``list`` after ``note``.
    """
    branches = []
    for tool in tools:
        schema = copy.deepcopy(tool.function.parameters)
        props = schema["properties"]
        ordered = {"action": {"type": "string", "enum": [TOOL_ACTIONS[tool.function.name]]}}
        if "note" in props:
            ordered["note"] = props.pop("note")
        ordered.update(props)
        schema["properties"] = ordered
        schema["required"] = ["action"] + schema.get("required", [])
        branches.append(schema)
    return {"oneOf": branches}
