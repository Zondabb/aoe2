class_name AiProtocol
extends RefCounted

## HTTP AI 协议常量与枚举字符串映射（protocol_version: 1）。

const Catalog := preload("res://scripts/data/game_catalog.gd")
const PROTOCOL_VERSION := 1
const MAX_PLAYER_INSTRUCTION_LENGTH := 240
const META_ENTITY_ID := &"entity_id"

const OP_MOVE := &"move"
const OP_STOP := &"stop"
const OP_GATHER := &"gather"
const OP_BUILD := &"build"
const OP_ATTACK := &"attack"
const OP_PLACE_BUILDING := &"place_building"
const OP_PLACE_WALL := &"place_wall"
const OP_SET_GATE_STATE := &"set_gate_state"
const OP_TRAIN := &"train"
const OP_NOOP := &"noop"
const OP_RESEARCH_AGE := &"research_age"
const OP_CANCEL_AGE := &"cancel_research_age"
const OP_RESEARCH_TECHNOLOGY := &"research_technology"
const OP_CANCEL_TECHNOLOGY := &"cancel_technology"

const EVENT_MATCH_STARTED := &"match_started"
const EVENT_MATCH_ENDED := &"match_ended"
const EVENT_ENTITY_SPAWNED := &"entity_spawned"
const EVENT_ENTITY_DESTROYED := &"entity_destroyed"
const EVENT_BUILDING_COMPLETED := &"building_completed"
const EVENT_RESOURCE_DEPLETED := &"resource_depleted"
const EVENT_UNIT_ORDER_FINISHED := &"unit_order_finished"


static func order_name(order: Enums.OrderType) -> String:
	match order:
		Enums.OrderType.NONE:
			return "NONE"
		Enums.OrderType.MOVE:
			return "MOVE"
		Enums.OrderType.GATHER:
			return "GATHER"
		Enums.OrderType.BUILD:
			return "BUILD"
		Enums.OrderType.ATTACK:
			return "ATTACK"
		_:
			return "NONE"


static func resource_type_name(resource_type: Enums.ResourceType) -> String:
	match resource_type:
		Enums.ResourceType.FOOD:
			return "FOOD"
		Enums.ResourceType.WOOD:
			return "WOOD"
		Enums.ResourceType.GOLD:
			return "GOLD"
		Enums.ResourceType.STONE:
			return "STONE"
		_:
			return "UNKNOWN"


static func entity_kind(entity: Node2D) -> String:
	if entity == null:
		return "unknown"
	if entity.get("def") is BuildingDef:
		return "building"
	if entity.has_method("extract"):
		return "resource"
	if entity.get("def") is UnitDef:
		return "unit"
	return "unknown"


static func vec2_to_array(value: Vector2) -> Array:
	return [float(value.x), float(value.y)]


static func def_id_string(entity: Node2D) -> String:
	var unit_def := entity.get("def") as UnitDef
	if unit_def != null:
		return String(unit_def.id)
	var building_def := entity.get("def") as BuildingDef
	if building_def != null:
		return String(building_def.id)
	return ""


static func json_safe(value: Variant) -> Variant:
	match typeof(value):
		TYPE_DICTIONARY:
			var out := {}
			for key in (value as Dictionary).keys():
				out[str(key)] = json_safe((value as Dictionary)[key])
			return out
		TYPE_ARRAY:
			var arr: Array = []
			for item in value as Array:
				arr.append(json_safe(item))
			return arr
		TYPE_VECTOR2:
			return vec2_to_array(value as Vector2)
		TYPE_STRING_NAME:
			return String(value)
		TYPE_OBJECT:
			return str(value)
		_:
			return value


static func op_from_string(value: String) -> StringName:
	match value:
		"move":
			return OP_MOVE
		"stop":
			return OP_STOP
		"gather":
			return OP_GATHER
		"build":
			return OP_BUILD
		"attack":
			return OP_ATTACK
		"place_building":
			return OP_PLACE_BUILDING
		"place_wall":
			return OP_PLACE_WALL
		"set_gate_state":
			return OP_SET_GATE_STATE
		"train":
			return OP_TRAIN
		"noop":
			return OP_NOOP
		"research_age":
			return OP_RESEARCH_AGE
		"cancel_research_age":
			return OP_CANCEL_AGE
		"research_technology":
			return OP_RESEARCH_TECHNOLOGY
		"cancel_technology":
			return OP_CANCEL_TECHNOLOGY
		_:
			return &""


static func array_to_vec2(value: Variant) -> Variant:
	if value is Vector2:
		return value
	if value is Array and (value as Array).size() >= 2:
		var arr := value as Array
		return Vector2(float(arr[0]), float(arr[1]))
	return null


static func building_def_for_id(building_def_id: String) -> BuildingDef:
	return Catalog.get_building(building_def_id)


static func unit_def_for_id(unit_def_id: String) -> UnitDef:
	return Catalog.get_unit(unit_def_id)
