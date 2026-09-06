class_name AiToolCatalog
extends RefCounted

## Chat Completions tool names — must match v1 command ops and Python mapper.

const TOOL_GATHER := "gather"
const TOOL_TRAIN := "train"
const TOOL_PLACE_BUILDING := "place_building"
const TOOL_BUILD := "build"
const TOOL_MOVE := "move"
const TOOL_ATTACK := "attack"
const TOOL_STOP := "stop"
const TOOL_NOOP := "noop"

const TOOL_NAMES := [
	TOOL_GATHER,
	TOOL_TRAIN,
	TOOL_PLACE_BUILDING,
	TOOL_BUILD,
	TOOL_MOVE,
	TOOL_ATTACK,
	TOOL_STOP,
	TOOL_NOOP,
]


static func is_known(name: String) -> bool:
	return name in TOOL_NAMES


static func tools_payload() -> Array:
	return [
		_fn(
			TOOL_GATHER,
			"Send a villager to gather a resource node.",
			{"unit_id": {"type": "integer"}, "target_id": {"type": "integer"}},
		),
		_fn(
			TOOL_TRAIN,
			"Queue a unit at a completed building.",
			{"building_id": {"type": "integer"}, "unit_def_id": {"type": "string"}},
		),
		_fn(
			TOOL_PLACE_BUILDING,
			"Place a building foundation at pos.",
			{
				"builder_id": {"type": "integer"},
				"building_def_id": {"type": "string"},
				"pos": {"type": "array", "items": {"type": "number"}},
			},
		),
		_fn(
			TOOL_BUILD,
			"Send a villager to construct a foundation.",
			{"unit_id": {"type": "integer"}, "building_id": {"type": "integer"}},
		),
		_fn(
			TOOL_MOVE,
			"Move a unit to pos.",
			{
				"unit_id": {"type": "integer"},
				"pos": {"type": "array", "items": {"type": "number"}},
			},
		),
		_fn(
			TOOL_ATTACK,
			"Order a unit to attack a target entity.",
			{"unit_id": {"type": "integer"}, "target_id": {"type": "integer"}},
		),
		_fn(
			TOOL_STOP,
			"Cancel a unit's current order.",
			{"unit_id": {"type": "integer"}},
		),
		_fn(TOOL_NOOP, "Do nothing this tick.", {}),
	]


static func _fn(name: String, description: String, properties: Dictionary) -> Dictionary:
	return {
		"type": "function",
		"function": {
			"name": name,
			"description": description,
			"parameters": {"type": "object", "properties": properties},
		},
	}
