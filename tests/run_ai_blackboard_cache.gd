extends SceneTree

const Blackboard := preload("res://scripts/systems/ai/ai_blackboard.gd")
const FogAccess := preload("res://scripts/systems/fog_access.gd")
const Holder := preload("res://scripts/systems/fog_of_war_holder.gd")
const Fog := preload("res://scripts/systems/fog_of_war_service.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Farm := preload("res://scripts/entities/farm_agent.gd")
var checks := 0
var failures: Array[String] = []

class LegacyUnit extends Node2D:
	var def := UnitDef.new()
	var team := 0
	var hp := 20.0
	var sim_pos := Vector2.ZERO

class LegacyResource extends Node2D:
	var sim_pos := Vector2.ZERO
	var resource_type := 0
	var block_size := Vector2.ONE
	func extract(_delta: float) -> float: return 1.0

func _initialize() -> void: call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func _run() -> void:
	UnitDebugFocus.set_spectator_mode(true)
	for offset in [Vector2.ZERO, Vector2(100, 200)]:
		await _fog_fixture(offset)
	_fallback_fixture()
	print("AI BLACKBOARD CACHE: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _fog_fixture(offset: Vector2) -> void:
	var world := Node2D.new()
	root.add_child(world)
	var entities := Node2D.new()
	entities.name = "Entities"
	world.add_child(entities)
	var state := MatchState.new()
	state.setup_defaults()
	state.map_bounds = Rect2(Vector2(-32, -32) + offset, Vector2(64, 64))
	var tc := _building(entities, state, &"town_center", 0, offset + Vector2(1, 1))
	var enemy_tc := _building(entities, state, &"town_center", 1, offset + Vector2(26, 26))
	var worker := _unit(entities, state, &"villager", 0, offset + Vector2(2, 2))
	worker.vision_radius_override = 8.0
	var enemy := _unit(entities, state, &"militia", 1, offset + Vector2(5, 2))
	var visible := _resource(entities, offset + Vector2(4, 3))
	var hidden := _resource(entities, offset + Vector2(27, 27))
	var farm := Farm.new()
	farm.def = Catalog.get_building(&"farm")
	farm.team = 0
	farm.sim_pos = offset + Vector2(3, 4)
	farm.match_state = state
	entities.add_child(farm)
	farm.set_physics_process(false)
	Holder.install_rect(world, state, state.map_bounds.position, state.map_bounds.end)
	var holder: Node = world.get_meta("fog_holder")
	holder.set_physics_process(false)
	_compare(state, entities, "visible/hidden resources and farms %s" % offset)
	var board := Blackboard.new()
	board.refresh(state, entities, 0, 1, 10.0, 12.0)
	check(visible in board.resource_nodes and hidden not in board.resource_nodes and farm in board.resource_nodes, "actual fog includes visible resources and completed farms only")
	check(board.enemy_tc_pos == Vector2.ZERO and board.threat_near_base, "hidden enemy TC stays unknown while visible enemy raises threat")
	farm.is_complete = false
	holder.rebuild_now()
	_compare(state, entities, "unfinished farm")
	board.refresh(state, entities, 0, 1, 10.0, 12.0)
	check(farm not in board.resource_nodes and board.incomplete_buildings == 1, "unfinished farm remains a building without becoming a resource")
	visible.sim_pos = hidden.sim_pos
	_compare(state, entities, "resource moved without holder rebuild")
	visible.sim_pos = offset + Vector2(17, 1)
	visible.block_size_override = Vector2(24, 4)
	_compare(state, entities, "resource footprint changed without holder rebuild")
	holder.rebuild_now()
	worker.sim_pos = offset + Vector2(-25, -25)
	tc.hp = 0.0
	state.fog.rebuild([worker])
	_compare(state, entities, "direct mask rebuild invalidates static cache")
	enemy.sim_pos = worker.sim_pos + Vector2(2, 0)
	_compare(state, entities, "enemy enters current fog mask")
	enemy.sim_pos = offset + Vector2(25, -25)
	_compare(state, entities, "enemy exits current fog mask")
	enemy_tc.team = 0
	_compare(state, entities, "converted building bypasses stale hostile visibility")
	var added := _resource(entities, worker.sim_pos + Vector2(2, 0))
	_compare(state, entities, "new resource appears before holder rebuild")
	added.free()
	_compare(state, entities, "freed resource is retired")
	var ghost := _building(entities, state, &"house", 0, worker.sim_pos)
	ghost.is_placement_ghost = true
	_compare(state, entities, "placement ghost excluded")
	state.fog_enabled = false
	_compare(state, entities, "disabled fog ignores holder visibility")
	state.fog_enabled = true
	var original: RefCounted = state.fog
	state.fog = Fog.new()
	state.fog.setup_rect(state.map_bounds.position, state.map_bounds.end)
	state.fog.rebuild([worker])
	_compare(state, entities, "replacement mask does not read another holder")
	state.fog = original
	world.free()
	await process_frame

func _fallback_fixture() -> void:
	var entities := Node2D.new()
	var state := MatchState.new()
	state.setup_defaults()
	var unit := LegacyUnit.new()
	unit.def.id = &"villager"
	unit.sim_pos = Vector2(1, 1)
	entities.add_child(unit)
	var resource := LegacyResource.new()
	resource.sim_pos = Vector2(2, 1)
	entities.add_child(resource)
	_compare(state, entities, "legacy arena without holder")
	state.fog_enabled = true
	state.fog = Fog.new()
	state.fog.setup(-32, 32)
	state.fog.rebuild([unit])
	_compare(state, entities, "legacy arena using standalone fog")
	entities.free()

func _unit(entities: Node2D, state: MatchState, id: StringName, team: int, pos: Vector2) -> UnitAgent:
	var unit := UnitAgent.new()
	unit.def = Catalog.get_unit(id)
	unit.team = team
	unit.match_state = state
	unit.sim_pos = pos
	entities.add_child(unit)
	unit.set_physics_process(false)
	return unit

func _building(entities: Node2D, state: MatchState, id: StringName, team: int, pos: Vector2) -> BuildingAgent:
	var building := BuildingAgent.new()
	building.def = Catalog.get_building(id)
	building.team = team
	building.sim_pos = pos
	building.match_state = state
	entities.add_child(building)
	building.set_physics_process(false)
	return building

func _resource(entities: Node2D, pos: Vector2) -> ResourceNode:
	var resource := ResourceNode.new()
	resource.resource_type = Enums.ResourceType.WOOD
	resource.sim_pos = pos
	entities.add_child(resource)
	return resource

func _compare(state: MatchState, entities: Node2D, label: String) -> void:
	for team in 2:
		var board := Blackboard.new()
		board.refresh(state, entities, team, 1 - team, 10.0, 12.0)
		check(_snapshot(board) == _reference(state, entities, team, 1 - team), "%s team %d matches uncached visibility and classification" % [label, team])

func _snapshot(board: AiBlackboard) -> Dictionary:
	return {"resources":board.resource_nodes, "buildings":board.team_buildings, "units":board.team_units, "villagers":board.team_villagers,
		"villager_count":board.villager_count, "military_count":board.military_count, "incomplete":board.incomplete_buildings,
		"own_tc":board.own_tc_pos, "enemy_tc":board.enemy_tc_pos, "threat":board.threat_near_base}

# Retain the original full-scene algorithm as the reference for cache behavior.
# It always consults current fog; no cached list or geometry is read here.
func _reference(state: MatchState, entities: Node2D, team: int, enemy: int) -> Dictionary:
	var result := {"resources":[], "buildings":[], "units":[], "villagers":[], "villager_count":0, "military_count":0,
		"incomplete":0, "own_tc":Vector2.ZERO, "enemy_tc":Vector2.ZERO, "threat":false}
	for node in entities.get_children():
		if not FogAccess.state_can_see(state, team, node) or node.get("is_placement_ghost") == true: continue
		if node.has_method("extract"):
			if not node is BuildingAgent or node.is_complete: result.resources.append(node)
			if not node is BuildingAgent: continue
		if node.get("def") is BuildingDef:
			var definition: BuildingDef = node.get("def")
			if definition.id == &"town_center":
				if node.get("team") == team: result.own_tc = node.get("sim_pos")
				elif node.get("team") == enemy: result.enemy_tc = node.get("sim_pos")
			if node.get("team") != team: continue
			result.buildings.append(node)
			if not node.get("is_complete"): result.incomplete += 1
			continue
		if node.get("def") is UnitDef:
			if node.get("team") != team:
				if float(node.get("hp")) > 0.0 and result.own_tc != Vector2.ZERO and result.own_tc.distance_to(node.get("sim_pos")) <= 12.0: result.threat = true
				continue
			result.units.append(node)
			if node.get("def").id == &"villager":
				result.villager_count += 1
				result.villagers.append(node)
			else: result.military_count += 1
	return result
