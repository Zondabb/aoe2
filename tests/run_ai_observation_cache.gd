extends SceneTree

const Observation := preload("res://scripts/ai_gateway/observation_builder.gd")
const Decision := preload("res://scripts/ai_gateway/decision_context_builder.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Perimeter := preload("res://scripts/ai_gateway/defense_perimeter.gd")
const Walls := preload("res://scripts/systems/wall_system.gd")
const Context := preload("res://scripts/ai_gateway/command_execution_context.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func _run() -> void:
	UnitDebugFocus.set_spectator_mode(true)
	var session := root.get_node("GameSession")
	session.match_map_data = {}
	session.match_ai_mode = "sandbox"
	session.online_active = false
	var world := load("res://scenes/match_2d.tscn").instantiate() as Node2D
	root.add_child(world)
	current_scene = world
	await process_frame
	await process_frame
	world.process_mode = Node.PROCESS_MODE_DISABLED
	var state: MatchState = world.get_node("Bootstrap").match_state
	var entities: Node2D = world.get_node("Entities")
	for team in 2:
		state.set_age(team, 1)
		for type in 4: state.resources[team][type] = 10000
		_compare_defense(state, entities, team, "opening")
		_compare_scout_cache(state, entities, team, "opening")
	var scout: UnitAgent
	var tc: BuildingAgent
	for node in entities.get_children():
		if node is UnitAgent and node.team == 1 and node.def.id == &"scout_cavalry": scout = node
		if node is BuildingAgent and node.team == 1 and node.def.id == &"town_center": tc = node
	scout.sim_pos += Vector2(32, -8)
	state.fog.rebuild(entities.get_children())
	_compare_scout_cache(state, entities, 1, "moved scout and new exploration")
	var mask: PackedByteArray = state.fog.explored[1]
	var grid: Vector2i = state.fog.grid_size
	for y in range(40, mini(grid.y - 1, 70)):
		for x in range(40, mini(grid.x - 1, 70)): mask[y * grid.x + x] = 255
	state.fog.explored[1] = mask
	_compare_scout_cache(state, entities, 1, "direct mask mutation")
	state.fog_enabled = false
	_compare_defense(state, entities, 1, "fog disabled")
	var cache := {}
	var fortifications: Array[BuildingAgent] = []
	for id in [&"house", &"barracks", &"palisade_wall", &"gate"]:
		for index in 3:
			var building := BuildingAgent.new()
			building.def = Catalog.get_building(id)
			building.team = 1
			building.civ = tc.civ
			building.match_state = state
			building.sim_pos = tc.sim_pos + Vector2(12 + index * 4, 12)
			entities.add_child(building)
			building.set_physics_process(false)
			check(Observation.serialize_entity(building, Registry.id_of(building), cache) == Observation.serialize_entity(building), "shared unlock cache matches uncached %s %d" % [id, index])
			building.is_complete = false
			check(Observation.serialize_entity(building, Registry.id_of(building), cache) == Observation.serialize_entity(building), "construction state stays live for %s %d" % [id, index])
			building.is_complete = true
			fortifications.append(building)
	var context := Context.new()
	context.match_state = state
	context.entities = entities
	context.team = 1
	context.civ = tc.civ
	var plan := Perimeter.get_plan(state, entities, 1, tc.sim_pos, Registry.id_of(tc), state.map_bounds, "palisade_wall")
	# Place a complete ring directly so the no-missing-batch fast path is exercised.
	for batch: Dictionary in Perimeter.batches(plan):
		for piece: Dictionary in batch.pieces:
			if Walls.existing_segment(piece, context) != null: continue
			var building := BuildingAgent.new()
			building.def = Catalog.get_building(piece.building_def_id)
			building.team = 1
			building.civ = tc.civ
			building.match_state = state
			building.sim_pos = piece.pos
			Walls.configure_building(building, int(piece.orientation))
			entities.add_child(building)
			building.set_physics_process(false)
	_compare_defense(state, entities, 1, "completed wall ring")
	state.fog_enabled = true
	state.fog.rebuild(entities.get_children())
	_compare_defense(state, entities, 1, "completed wall ring under fog")
	state.frozen = true
	world.free()
	print("AI OBSERVATION CACHE: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _compare_defense(state: MatchState, entities: Node2D, team: int, label: String) -> void:
	var full := Observation.build(state, entities, team, 1 - team, 240.0)
	var minimal := Observation.build(state, entities, team, 1 - team, 240.0, Observation.DEFAULT_DEFEND_RADIUS, true)
	for key in ["defense_options", "defense_plan", "defense_scout_options"]:
		check(full.decision_context[key] == minimal.decision_context[key], "%s team %d: minimal %s matches full observation" % [label, team, key])
	var full_hostiles: Array = full.entities.filter(func(e): return e.kind == "unit" and int(e.get("team", team)) != team).map(func(e): return [e.id, e.team, e.def_id, e.pos])
	var minimal_hostiles: Array = minimal.entities.filter(func(e): return e.kind == "unit" and int(e.get("team", team)) != team).map(func(e): return [e.id, e.team, e.def_id, e.pos])
	check(full_hostiles == minimal_hostiles, label + ": defense safety sees the same hostile units")

func _compare_scout_cache(state: MatchState, entities: Node2D, team: int, label: String) -> void:
	var initial: Dictionary = Observation.build(state, entities, team, 1 - team, 240.0).decision_context.scouting
	var cached: Dictionary = Observation.build(state, entities, team, 1 - team, 240.0).decision_context.scouting
	state.remove_meta(Decision.FRONTIER_CACHE_META)
	var fresh: Dictionary = Observation.build(state, entities, team, 1 - team, 240.0).decision_context.scouting
	check(initial == cached and cached == fresh, label + ": cached frontier geometry matches fresh geometry")
