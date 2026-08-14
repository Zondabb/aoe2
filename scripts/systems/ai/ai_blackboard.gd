class_name AiBlackboard
extends RefCounted

var match_time := 0.0
var ai_team: Enums.Team = Enums.Team.AI
var enemy_team: Enums.Team = Enums.Team.PLAYER

var food := 0
var wood := 0
var gold := 0
var pop_used := 0
var pop_cap := 0

var villager_count := 0
var military_count := 0
var incomplete_buildings := 0

var own_tc_pos := Vector2.ZERO
var enemy_tc_pos := Vector2.ZERO
var threat_near_base := false

var team_units: Array[Node2D] = []
var team_villagers: Array[Node2D] = []
var team_buildings: Array[Node2D] = []
var resource_nodes: Array[Node2D] = []


func refresh(
	match_state: MatchState,
	entities: Node2D,
	team: Enums.Team,
	enemy: Enums.Team,
	match_time_seconds: float,
	defend_radius: float
) -> void:
	match_time = match_time_seconds
	ai_team = team
	enemy_team = enemy
	team_units.clear()
	team_villagers.clear()
	team_buildings.clear()
	resource_nodes.clear()
	villager_count = 0
	military_count = 0
	incomplete_buildings = 0
	own_tc_pos = Vector2.ZERO
	enemy_tc_pos = Vector2.ZERO
	threat_near_base = false

	if match_state == null or entities == null:
		return

	food = match_state.get_resource(team, Enums.ResourceType.FOOD)
	wood = match_state.get_resource(team, Enums.ResourceType.WOOD)
	gold = match_state.get_resource(team, Enums.ResourceType.GOLD)
	pop_used = int(match_state.population.get(team, 0))
	pop_cap = int(match_state.population_cap.get(team, 0))

	for node in entities.get_children():
		if node.has_method("extract"):
			resource_nodes.append(node as Node2D)
			continue
		if node.get("def") is BuildingDef:
			var building := node as Node2D
			var building_def := building.get("def") as BuildingDef
			var building_team: Enums.Team = building.get("team")
			if building_def != null and building_def.id == &"town_center":
				if building_team == team:
					own_tc_pos = building.get("sim_pos")
				elif building_team == enemy:
					enemy_tc_pos = building.get("sim_pos")
			if building_team != team:
				continue
			team_buildings.append(building)
			if not bool(building.get("is_complete")):
				incomplete_buildings += 1
			continue
		if node.get("def") is UnitDef:
			if node.get("team") != team:
				if float(node.get("hp")) > 0.0 and own_tc_pos != Vector2.ZERO:
					var dist: float = own_tc_pos.distance_to(node.get("sim_pos"))
					if dist <= defend_radius:
						threat_near_base = true
				continue
			team_units.append(node as Node2D)
			var unit_def := node.get("def") as UnitDef
			if unit_def.id == &"villager":
				villager_count += 1
				team_villagers.append(node as Node2D)
			else:
				military_count += 1
