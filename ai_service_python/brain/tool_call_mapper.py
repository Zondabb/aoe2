from __future__ import annotations

import json
from typing import Any

from protocol.models import Command, CommandOp

TOOL_NAMES: tuple[str, ...] = (
    "gather",
    "train",
    "research_age",
    "cancel_research_age",
    "research_technology",
    "cancel_technology",
    "place_building",
    "build",
    "move",
    "attack",
    "stop",
    "noop",
)

_ARG_KEYS = (
    "command_id",
    "unit_id",
    "building_id",
    "target_id",
    "building_def_id",
    "unit_def_id",
    "technology_id",
    "pos",
    "builder_id",
)

_TOOL_DESCRIPTIONS: dict[str, str] = {
    "gather": "Send a villager to gather a resource node.",
    "train": "Queue a unit at a completed building.",
    "research_age": "Research the next age at an idle town center whose age_upgrade_reason is empty.",
    "cancel_research_age": "Cancel the town center's age research and refund its cost.",
    "research_technology": "Research an available technology whose observed reason is empty.",
    "cancel_technology": "Cancel a building's technology research and refund its cost.",
    "place_building": "Place a building foundation at pos.",
    "build": "Send a villager to construct a foundation.",
    "move": "Move a unit to pos.",
    "attack": "Order a unit to attack a target entity.",
    "stop": "Cancel a unit's current order.",
    "noop": "Do nothing this tick.",
}

_TOOL_PROPERTIES: dict[str, dict[str, Any]] = {
    "research_age": {"building_id": {"type": "integer"}, "command_id": {"type": "string"}},
    "cancel_research_age": {"building_id": {"type": "integer"}, "command_id": {"type": "string"}},
    "research_technology": {
        "building_id": {"type": "integer"},
        "technology_id": {"type": "string"},
        "command_id": {"type": "string"},
    },
    "cancel_technology": {"building_id": {"type": "integer"}, "command_id": {"type": "string"}},
    "gather": {
        "unit_id": {"type": "integer"},
        "target_id": {"type": "integer"},
        "command_id": {"type": "string"},
    },
    "train": {
        "building_id": {"type": "integer"},
        "unit_def_id": {"type": "string"},
        "command_id": {"type": "string"},
    },
    "place_building": {
        "builder_id": {"type": "integer"},
        "building_def_id": {"type": "string"},
        "pos": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2},
        "command_id": {"type": "string"},
    },
    "build": {
        "unit_id": {"type": "integer"},
        "building_id": {"type": "integer"},
        "command_id": {"type": "string"},
    },
    "move": {
        "unit_id": {"type": "integer"},
        "pos": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2},
        "command_id": {"type": "string"},
    },
    "attack": {
        "unit_id": {"type": "integer"},
        "target_id": {"type": "integer"},
        "command_id": {"type": "string"},
    },
    "stop": {
        "unit_id": {"type": "integer"},
        "command_id": {"type": "string"},
    },
    "noop": {
        "command_id": {"type": "string"},
    },
}


def tool_definitions() -> list[dict[str, Any]]:
    tools: list[dict[str, Any]] = []
    for name in TOOL_NAMES:
        tools.append(
            {
                "type": "function",
                "function": {
                    "name": name,
                    "description": _TOOL_DESCRIPTIONS[name],
                    "parameters": {
                        "type": "object",
                        "properties": _TOOL_PROPERTIES[name],
                    },
                },
            }
        )
    return tools


def command_to_tool_call(command: Command, index: int) -> dict[str, Any]:
    dumped = command.model_dump(exclude_none=True)
    dumped.pop("op", None)
    args = {key: dumped[key] for key in _ARG_KEYS if key in dumped}
    return {
        "id": f"call_{index + 1}",
        "type": "function",
        "function": {
            "name": command.op,
            "arguments": json.dumps(args, separators=(",", ":")),
        },
    }


def commands_to_tool_calls(commands: list[Command]) -> list[dict[str, Any]]:
    return [command_to_tool_call(cmd, i) for i, cmd in enumerate(commands)]


def parse_arguments(raw: Any) -> dict[str, Any]:
    if isinstance(raw, dict):
        return raw
    if not isinstance(raw, str) or not raw.strip():
        return {}
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def tool_call_to_command(tool_call: dict[str, Any], tick: int, seq: int) -> dict[str, Any] | None:
    fn = tool_call.get("function") if isinstance(tool_call.get("function"), dict) else {}
    name = str(fn.get("name", "")).strip()
    if name not in TOOL_NAMES:
        return None
    args = parse_arguments(fn.get("arguments"))
    cmd: dict[str, Any] = {"op": name}
    for key in _ARG_KEYS:
        if key in args and args[key] is not None:
            cmd[key] = args[key]
    if not str(cmd.get("command_id", "")).strip():
        cmd["command_id"] = f"c_{tick}_{seq}"
    return cmd


def is_command_op(name: str) -> bool:
    return name in TOOL_NAMES


def ensure_command_op(op: str) -> CommandOp | None:
    return op if op in TOOL_NAMES else None
