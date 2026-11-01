extends SceneTree
## Walls and gates are observed with a compact record: what can differ between
## pieces (health, construction, placement, passability and the door), without
## the production, research, drop-off and per-type keys of other buildings.
const Observation := preload("res://scripts/ai_gateway/observation_builder.gd")
const Protocol := preload("res://scripts/ai_gateway/ai_protocol.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Walls := preload("res://scripts/systems/wall_system.gd")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const TEAM := 1
const PIECE := ["blocks_movement", "build_progress", "def_id", "footprint", "hp", "id", "is_complete", "kind", "max_hp", "orientation", "pos", "team"]
const BUILDING_ONLY := ["build_time", "planning_footprint", "drop_off_resources", "train_queue_empty", "train_queue", "train_progress", "production", "research", "is_researching", "trainable", "train_blocked_reasons"]
var checks := 0
var failures := 0
var entities: Node2D
var state: MatchState

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)

func _run() -> void:
	var session := root.get_node("GameSession")
	session.match_map_data = {}
	session.match_ai_mode = "sandbox"
	session.online_active = false
	session.player_civ_id = &"chinese"
	session.ai_civ_id = &"teutons"
	var world: Node = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(world)
	current_scene = world
	await process_frame
	await process_frame
	world.process_mode = Node.PROCESS_MODE_DISABLED
	entities = world.get_node("Entities")
	state = world.get_node("Bootstrap").match_state
	for team in 2: state.set_age(team, 2)
	var own_tc := _town_center(TEAM)
	var enemy_tc := _town_center(1 - TEAM)
	# Own: two finished runs with gates, one run of foundations, a house.
	var own: Array = _place(TEAM, "palisade_wall", own_tc.sim_pos + Vector2(14, -6), own_tc.sim_pos + Vector2(14, 6), true, false)
	own.append_array(_place(TEAM, "stone_wall", own_tc.sim_pos + Vector2(-6, 14), own_tc.sim_pos + Vector2(6, 14), true, false))
	var foundations: Array = _place(TEAM, "stone_wall", own_tc.sim_pos + Vector2(-14, -4), own_tc.sim_pos + Vector2(-14, 4), false, true)
	var house := _place_one(TEAM, "house", own_tc.sim_pos + Vector2(-8, -12), 0, false)
	# Enemy pieces beside our own town center, inside its vision.
	var enemy: Array = _place(1 - TEAM, "palisade_wall", own_tc.sim_pos + Vector2(-6, -14), own_tc.sim_pos + Vector2(6, -14), true, false)
	var gates := own.filter(func(node): return node.def.id == &"gate")
	check(gates.size() == 2, "two own gates placed (%d)" % gates.size())
	gates[0].set_gate_state("open")
	gates[1].set_gate_state("locked")
	enemy.filter(func(node): return node.def.id == &"gate")[0].set_gate_state("open")
	for node in own + foundations + enemy: node.hp = node.hp * 0.75
	state.fog.rebuild(entities.get_children())
	var observation := Observation.build(state, entities, TEAM, 1 - TEAM, 300.0)
	var seen := {"own wall": 0, "own gate": 0, "foundation": 0, "enemy wall": 0, "enemy gate": 0}
	for node in own + foundations + enemy:
		var record := _record(observation, node)
		if record.is_empty(): continue
		var is_gate: bool = node.def.id == &"gate"
		var mine: bool = node.team == TEAM
		var expected := PIECE.duplicate()
		if is_gate:
			expected.append("gate_open")
			if mine: expected.append("gate_state")
		expected.sort()
		var keys := record.keys()
		keys.sort()
		var label := "%s %s" % ["own" if mine else "enemy", "gate" if is_gate else "wall"]
		seen[label] += 1
		if not node.is_complete: seen["foundation"] += 1
		check(keys == expected, "%s %s carries exactly the piece keys (%s)" % [label, node.def.id, keys])
		check(record.footprint == Protocol.vec2_to_array(node.get_placement_footprint()) and record.orientation == node.wall_orientation, label + " footprint and orientation are the piece's own")
		check(record.blocks_movement == (node.get_movement_half() != Vector2.ZERO), label + " passability follows the door")
		check(is_equal_approx(record.hp, node.hp) and record.is_complete == node.is_complete and is_equal_approx(record.build_progress, node.build_progress), label + " health and construction are live")
		if is_gate:
			check(record.gate_open == node.gate_open and (not mine or record.gate_state == node.gate_state), label + " door state is observed")
	for label in seen: check(seen[label] > 0, "observation includes %s pieces (%d)" % [label, seen[label]])
	check(gates.all(func(gate): return _record(observation, gate).gate_open == gate.gate_open) and _record(observation, gates[0]).gate_open and not _record(observation, gates[1]).gate_open, "open and locked own gates are distinguished")
	# Every other building keeps its full record.
	for node in [house, own_tc]:
		var record := _record(observation, node)
		check(BUILDING_ONLY.all(func(key): return record.has(key)) and record.has("gate_state") and record.has("gate_open"), "%s keeps production, research and per-type keys" % node.def.id)
	check(_record(observation, own_tc).trainable.has("villager"), "town center still lists what it trains")
	print("FORTIFICATION OBSERVATION: %d checks, %d failures, %s" % [checks, failures, seen])
	state.frozen = true
	world.free()
	quit(0 if failures == 0 else 1)

func _record(observation: Dictionary, node: Node2D) -> Dictionary:
	var at := Vector2(node.sim_pos)
	for record: Dictionary in observation.entities:
		if record.get("def_id") == String(node.def.id) and int(record.team) == node.team and Protocol.array_to_vec2(record.pos).is_equal_approx(at): return record
	return {}

func _town_center(team: int) -> Node2D:
	for node in entities.get_children():
		if node is BuildingAgent and node.team == team and node.def.id == &"town_center": return node
	return null

func _place(team: int, material: String, start: Vector2, end: Vector2, gate: bool, foundation: bool) -> Array:
	var placed: Array = []
	for item: Dictionary in Walls.plan(material, start, end, gate):
		placed.append(_place_one(team, item.building_def_id, item.pos, int(item.orientation), foundation))
	return placed

func _place_one(team: int, id: String, pos: Vector2, orientation: int, foundation: bool) -> BuildingAgent:
	var building := BUILDING_VIEW.instantiate() as BuildingAgent
	building.def = Catalog.get_building(StringName(id))
	building.team = team
	building.civ = load("res://data/civs/%s.tres" % ("teutons" if team == TEAM else "chinese"))
	building.match_state = state
	building.sim_pos = pos
	Walls.configure_building(building, orientation)
	if foundation: building.start_construction()
	entities.add_child(building)
	building.set_physics_process(false)
	return building
