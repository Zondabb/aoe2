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
var _reserved_costs: Dictionary = {}
var _reserved_population := 0
var _busy_buildings: Dictionary = {}


func available_resource(type: Enums.ResourceType) -> int:
	return match_state.get_resource(team, type) - int(_reserved_costs.get(type, 0) if capture_commands else 0)


func can_afford(food: int, wood: int, gold: int, stone: int = 0) -> bool:
	return available_resource(Enums.ResourceType.FOOD) >= food and available_resource(Enums.ResourceType.WOOD) >= wood and available_resource(Enums.ResourceType.GOLD) >= gold and available_resource(Enums.ResourceType.STONE) >= stone


func population_used() -> int:
	return int(match_state.population[team]) + int(match_state.population_reserved[team]) + (_reserved_population if capture_commands else 0)


func building_busy(building: Node2D) -> bool:
	return capture_commands and _busy_buildings.has(building.get_instance_id())


func _reserve_cost(food: int, wood: int, gold: int, stone: int = 0) -> void:
	for type in Enums.ResourceType.values():
		_reserved_costs[type] = int(_reserved_costs.get(type, 0)) + [food, wood, gold, stone][type]


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
	_reserved_costs.clear()
	_reserved_population = 0
	_busy_buildings.clear()


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


func issue_wall(option: Dictionary) -> bool:
	var cost: Dictionary = option.cost
	if not can_afford(100 + int(cost.food), 150 + int(cost.wood), int(cost.gold), int(cost.stone)): return false
	var command := {"op": "place_wall"}
	for key in ["builder_id", "building_def_id", "start", "end", "include_gate"]: command[key] = option[key]
	if capture_commands:
		_reserve_cost(cost.food, cost.wood, cost.gold, cost.stone)
		_push_command(command)
		return true
	var context := preload("res://scripts/ai_gateway/command_execution_context.gd").new()
	context.match_state = match_state
	context.entities = entities
	context.team = team
	context.civ = civ
	return preload("res://scripts/ai_gateway/command_executor.gd").execute(command, context).ok


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
		if not can_afford(building_def.cost_food, building_def.cost_wood, building_def.cost_gold, building_def.cost_stone):
			return false
		var cmd := {
			"op": "place_building",
			"building_def_id": String(building_def.id),
			"pos": AiProtocolScript.vec2_to_array(pos),
		}
		if builder != null:
			cmd["builder_id"] = EntityRegistryScript.id_of(builder)
		_push_command(cmd)
		_reserve_cost(building_def.cost_food, building_def.cost_wood, building_def.cost_gold, building_def.cost_stone)
		next_build_slot += 1
		return true
	return false


func issue_train(building: Node2D, unit_def: UnitDef) -> bool:
	if building == null or unit_def == null:
		return false
	if capture_commands:
		if building_busy(building) or not can_afford(unit_def.cost_food, unit_def.cost_wood, unit_def.cost_gold, unit_def.cost_stone) or population_used() + unit_def.population > int(match_state.population_cap[team]):
			return false
		_push_command(
			{
				"op": "train",
				"building_id": EntityRegistryScript.id_of(building),
				"unit_def_id": String(unit_def.id),
			}
		)
		_reserve_cost(unit_def.cost_food, unit_def.cost_wood, unit_def.cost_gold, unit_def.cost_stone)
		_reserved_population += unit_def.population
		_busy_buildings[building.get_instance_id()] = true
		return true
	return bool(building.call("enqueue_train", unit_def))


func _push_command(cmd: Dictionary) -> void:
	cmd["command_id"] = "c_%d_%d" % [capture_tick, _command_seq]
	_command_seq += 1
	pending_commands.append(cmd)


func issue_age_upgrade(building: Node2D) -> bool:
	if capture_commands:
		var requirements: Dictionary = AgeProgression.requirements_for(match_state.age_of(team) + 1)
		if building_busy(building) or requirements.is_empty() or not can_afford(int(requirements.food), 0, int(requirements.gold)):
			return false
		_push_command({"op": "research_age", "building_id": EntityRegistryScript.id_of(building)})
		_reserve_cost(int(requirements.food), 0, int(requirements.gold))
		_busy_buildings[building.get_instance_id()] = true
		return true
	return bool(building.call("start_age_upgrade"))


func issue_technology(building: Node2D, technology_id: String) -> bool:
	if capture_commands:
		var cost: Dictionary = GameCatalog.technologies().get(technology_id, {}).get("cost", {})
		if building_busy(building) or not can_afford(int(cost.get("food", 0)), int(cost.get("wood", 0)), int(cost.get("gold", 0)), int(cost.get("stone", 0))):
			return false
		_push_command({"op": "research_technology", "building_id": EntityRegistryScript.id_of(building), "technology_id": technology_id})
		_reserve_cost(int(cost.get("food", 0)), int(cost.get("wood", 0)), int(cost.get("gold", 0)), int(cost.get("stone", 0)))
		_busy_buildings[building.get_instance_id()] = true
		return true
	return bool(match_state.technology_progression.start_research(building, technology_id))
