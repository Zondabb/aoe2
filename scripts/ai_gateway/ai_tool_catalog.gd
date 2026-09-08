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
			"派村民采集资源点（target_id 为观测中的资源 entity id）。",
			{"unit_id": {"type": "integer"}, "target_id": {"type": "integer"}},
		),
		_fn(
			TOOL_TRAIN,
			"在已完工建筑中排队训练单位。",
			{"building_id": {"type": "integer"}, "unit_def_id": {"type": "string"}},
		),
		_fn(
			TOOL_PLACE_BUILDING,
			"在指定坐标放置建筑地基。",
			{
				"builder_id": {"type": "integer"},
				"building_def_id": {"type": "string"},
				"pos": {"type": "array", "items": {"type": "number"}},
			},
		),
		_fn(
			TOOL_BUILD,
			"派村民建造指定地基。",
			{"unit_id": {"type": "integer"}, "building_id": {"type": "integer"}},
		),
		_fn(
			TOOL_MOVE,
			"移动单位到指定坐标。",
			{
				"unit_id": {"type": "integer"},
				"pos": {"type": "array", "items": {"type": "number"}},
			},
		),
		_fn(
			TOOL_ATTACK,
			"命令单位攻击目标 entity。",
			{"unit_id": {"type": "integer"}, "target_id": {"type": "integer"}},
		),
		_fn(
			TOOL_STOP,
			"取消单位当前指令。",
			{"unit_id": {"type": "integer"}},
		),
		_fn(TOOL_NOOP, "本 tick 不执行任何操作。", {}),
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
