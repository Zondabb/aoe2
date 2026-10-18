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
	"place_wall",
	"set_gate_state",
	TOOL_BUILD,
	TOOL_MOVE,
	TOOL_ATTACK,
	TOOL_STOP,
	"research_age",
	"cancel_research_age",
	"research_technology",
	"cancel_technology",
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
			"在己方已完工建筑中训练其 trainable 兵种，依据 catalog 实际成本、人口预留、研究和队列容量。不要重复填满队列。",
			{"building_id": {"type": "integer"}, "unit_def_id": {"type": "string"}},
		),
		_fn(
			TOOL_PLACE_BUILDING,
			"用己方村民在 construction_options 的合法 pos 放地基，并自动令该村民建造；先满足时代/建筑前置，不重复已有地基。",
			{
				"builder_id": {"type": "integer"},
				"building_def_id": {"type": "string"},
				"pos": {"type": "array", "items": {"type": "number"}},
			},
		),
		_fn("place_wall", "按 defense_options 的起终点建造整排城墙并安排连续施工，整排收费且保留出入口。", {"builder_id":{"type":"integer"}, "building_def_id":{"type":"string"}, "start":{"type":"array", "items":{"type":"number"}}, "end":{"type":"array", "items":{"type":"number"}}, "include_gate":{"type":"boolean"}}),
		_fn("set_gate_state", "设置己方城门的自动、常开或锁闭状态。", {"building_id":{"type":"integer"}, "gate_state":{"type":"string", "enum":["auto", "open", "locked"]}}),
		_fn(
			TOOL_BUILD,
			"让己方村民继续己方未完工地基，优先完成已有兵营/房屋；不用等待 place_building 返回新 id 再建造。",
			{"unit_id": {"type": "integer"}, "building_id": {"type": "integer"}},
		),
		_fn(
			TOOL_MOVE,
			"移动己方单位至 [x,y] 仿真坐标；可从 scouting.frontiers 自主探索或 army.rally_point 集结，目标必须在 map_bounds 内。相同 move_goal 尚在行进时无需重发。",
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
		_fn("research_age", "在空闲城镇中心研究下一个时代，按观测中的条件和成本判断。", {"building_id": {"type": "integer"}}),
		_fn("cancel_research_age", "取消该城镇中心的时代研究并退款。", {"building_id": {"type": "integer"}}),
		_fn("research_technology", "研究观测中该建筑可用的兵种升级。", {"building_id": {"type": "integer"}, "technology_id": {"type": "string"}}),
		_fn("cancel_technology", "取消该建筑的兵种研究。", {"building_id": {"type": "integer"}}),
		_fn(TOOL_NOOP, "本 tick 不执行任何操作。", {}),
	]


static func _fn(name: String, description: String, properties: Dictionary) -> Dictionary:
	for key in properties:
		if properties[key].get("type") == "array":
			properties[key]["minItems"] = 2
			properties[key]["maxItems"] = 2
	return {
		"type": "function",
		"function": {
			"name": name,
			"description": description,
			"parameters": {"type": "object", "properties": properties, "required": properties.keys(), "additionalProperties": false},
		},
	}
