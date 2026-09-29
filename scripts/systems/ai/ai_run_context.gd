class_name AiRunContext
extends RefCounted

const EntityRegistryScript := preload("res://scripts/ai_gateway/entity_registry.gd")
const AiProtocolScript := preload("res://scripts/ai_gateway/ai_protocol.gd")

var match_state: MatchState
var entities: Node2D
var civ: CivDef
var profile: CivAiProfile
var team: Enums.Team
var enemy_team: Enums.Team
var blackboard: AiBlackboard
var decision_log: AiDecisionLog
var team_label: String
var phase: int = 0
var next_build_slot: int = 0

var capture_commands := false
var capture_tick := 0
var pending_commands: Array = []
var debug_entries: Array = []
var _command_seq := 0


func log_decision(category: String, message: String) -> void:
	if decision_log != null:
		decision_log.log(blackboard.match_time, team_label, category, message)
	if capture_commands:
		debug_entries.append({"category": category, "message": message})


func begin_capture(tick: int) -> void:
	capture_commands = true
	capture_tick = tick
	pending_commands.clear()
	debug_entries.clear()
	_command_seq = 0


func end_capture() -> Dictionary:
	capture_commands = false
	return {"commands": pending_commands.duplicate(), "debug": debug_entries.duplicate()}


func issue_gather(villager: Node2D, resource: Node2D) -> void:
	if villager == null or resource == null:
		return
	if capture_commands:
		_push_command(
			{
				"op": "gather",
				"unit_id": EntityRegistryScript.id_of(villager),
				"target_id": EntityRegistryScript.id_of(resource),
			}
		)
		return
	villager.call("command_gather", resource)


func issue_build(villager: Node2D, building: Node2D) -> void:
	if villager == null or building == null:
		return
	if capture_commands:
		_push_command(
			{
				"op": "build",
				"unit_id": EntityRegistryScript.id_of(villager),
				"building_id": EntityRegistryScript.id_of(building),
			}
		)
		return
	villager.call("command_build", building)


func issue_attack(unit: Node2D, target: Node2D) -> void:
	if unit == null or target == null:
		return
	if capture_commands:
		_push_command(
			{
				"op": "attack",
				"unit_id": EntityRegistryScript.id_of(unit),
				"target_id": EntityRegistryScript.id_of(target),
			}
		)
		return
	unit.call("command_attack", target)


func issue_move(unit: Node2D, pos: Vector2) -> void:
	if unit == null:
		return
	if capture_commands:
		_push_command(
			{
				"op": "move",
				"unit_id": EntityRegistryScript.id_of(unit),
				"pos": AiProtocolScript.vec2_to_array(pos),
			}
		)
		return
	unit.call("command_move", pos)


func issue_place_building(
	building_def: BuildingDef, pos: Vector2, builder: Node2D = null
) -> bool:
	if building_def == null:
		return false
	if capture_commands:
		var cmd := {
			"op": "place_building",
			"building_def_id": String(building_def.id),
			"pos": AiProtocolScript.vec2_to_array(pos),
		}
		if builder != null:
			cmd["builder_id"] = EntityRegistryScript.id_of(builder)
		_push_command(cmd)
		next_build_slot += 1
		return true
	return false


func issue_train(building: Node2D, unit_def: UnitDef) -> bool:
	if building == null or unit_def == null:
		return false
	if capture_commands:
		_push_command(
			{
				"op": "train",
				"building_id": EntityRegistryScript.id_of(building),
				"unit_def_id": String(unit_def.id),
			}
		)
		return true
	return bool(building.call("enqueue_train", unit_def))


func _push_command(cmd: Dictionary) -> void:
	cmd["command_id"] = "c_%d_%d" % [capture_tick, _command_seq]
	_command_seq += 1
	pending_commands.append(cmd)


func issue_age_upgrade(building: Node2D) -> bool:
	if capture_commands:
		_push_command({"op": "research_age", "building_id": EntityRegistryScript.id_of(building)})
		return true
	return bool(building.call("start_age_upgrade"))


func issue_technology(building: Node2D, technology_id: String) -> bool:
	if capture_commands:
		_push_command({"op": "research_technology", "building_id": EntityRegistryScript.id_of(building), "technology_id": technology_id})
		return true
	return bool(match_state.technology_progression.start_research(building, technology_id))
