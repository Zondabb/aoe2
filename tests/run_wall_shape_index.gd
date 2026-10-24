extends SceneTree
## FortificationVisual._wall_shape uses a per-frame neighbour snapshot. Every
## piece must get the same shape as the original scan over all siblings,
## including changes made earlier in the same frame.
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Building := preload("res://scenes/entities/building_view.tscn")
const Walls := preload("res://scripts/systems/wall_system.gd")
const Art := preload("res://scripts/presentation/fortification_visual.gd")
const MATERIALS := ["palisade_wall", "stone_wall", "fortified_wall"]
var checks := 0
var failures := 0
var entities: Node2D
var state: MatchState
var compared := 0
var by_shape := {}

func _initialize() -> void: call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)

func building(id: String, pos: Vector2, team := 0, orientation := 0, complete := true, ghost := false) -> BuildingAgent:
	var entity := Building.instantiate() as BuildingAgent
	entity.def = Catalog.get_building(StringName(id))
	entity.civ = load("res://data/civs/%s.tres" % ("chinese" if team == 0 else "teutons"))
	entity.team = team
	entity.match_state = state
	entity.sim_pos = pos
	entity.wall_orientation = orientation
	entity.is_complete = complete
	entity.is_placement_ghost = ghost
	entities.add_child(entity)
	return entity

## The original implementation: every sibling, every time.
func reference_shape(building: BuildingAgent, catalog: Dictionary) -> int:
	var directions: Array[Vector2] = []
	for neighbor in building.get_parent().get_children():
		if neighbor == building or neighbor is not BuildingAgent or neighbor.is_queued_for_deletion(): continue
		if neighbor.def == null or not Walls.is_fortification(neighbor.def.id) or neighbor.team != building.team: continue
		if neighbor.is_placement_ghost and not building.is_placement_ghost: continue
		var delta: Vector2 = neighbor.sim_pos - building.sim_pos
		if neighbor.def.id == &"gate":
			var tip := Walls.direction(neighbor.wall_orientation) * 1.5
			delta = delta - tip if (delta - tip).length_squared() < (delta + tip).length_squared() else delta + tip
		var snapped := delta.round()
		if not delta.is_equal_approx(snapped) or maxf(absf(delta.x), absf(delta.y)) != 1.0: continue
		if not directions.has(snapped): directions.append(snapped)
	if directions.size() == 2 and directions[0] == -directions[1]:
		for orientation in 4:
			if directions[0] == Walls.direction(orientation) or directions[0] == -Walls.direction(orientation):
				return int(catalog.orientation_frames[orientation])
	return int(catalog.post_frame)

## Compares every wall piece (gates use no neighbour shape) in the container.
func compare_all(label: String) -> void:
	var catalog := Art.manifest()
	var mismatches := 0
	for node in entities.get_children():
		if node is not BuildingAgent or node.def == null or not Walls.is_wall(node.def.id) or node.is_queued_for_deletion(): continue
		var visual: Node2D = node.get_node("FortificationVisual")
		var shape: int = visual._wall_shape(node, catalog)
		compared += 1
		by_shape[shape] = int(by_shape.get(shape, 0)) + 1
		if shape != reference_shape(node, catalog): mismatches += 1
	check(mismatches == 0, "%s: indexed wall shapes match the full scan (%d mismatches)" % [label, mismatches])

func _run() -> void:
	state = MatchState.new()
	state.setup_defaults()
	state.set_age(0, 2)
	state.set_age(1, 2)
	state.frozen = true
	entities = Node2D.new()
	root.add_child(entities)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261024
	# Straight and diagonal runs with gates, as the planner and players build them.
	for run in 60:
		var start := Vector2(rng.randi_range(-40, 40), rng.randi_range(-40, 40))
		var direction := Walls.direction(rng.randi_range(0, 3)) * (1 if rng.randf() < 0.5 else -1)
		var length := rng.randi_range(2, 14)
		var team := rng.randi_range(0, 1)
		var ghost := rng.randf() < 0.15
		var complete := rng.randf() < 0.7
		for item: Dictionary in Walls.plan(MATERIALS[run % 3], start, start + direction * length, length >= 6 and rng.randf() < 0.5):
			building(item.building_def_id, item.pos, team, int(item.orientation), complete, ghost)
	# Dense random pieces: corners, junctions, touching teams, stray gates.
	for index in 900:
		var pos := Vector2(rng.randi_range(-20, 20), rng.randi_range(-20, 20))
		var team := 0 if rng.randf() < 0.75 else 1
		var ghost := rng.randf() < 0.1
		if rng.randf() < 0.08:
			var orientation := rng.randi_range(0, 3)
			building("gate", pos + Walls.direction(orientation) * 1.5, team, orientation, rng.randf() < 0.8, ghost)
		else:
			building(MATERIALS[index % 3], pos, team, rng.randi_range(0, 3), rng.randf() < 0.8, ghost)
	# Scattered non-fortification buildings share the container.
	for index in 20: building("house", Vector2(rng.randi_range(-40, 40), rng.randi_range(-40, 40)))
	await process_frame
	compare_all("initial layout")

	# Changes made after the snapshot, all within one frame.
	await process_frame
	compare_all("snapshot built")
	var walls: Array = entities.get_children().filter(func(node): return node is BuildingAgent and node.def != null and Walls.is_wall(node.def.id))
	var ghosts: Array = walls.filter(func(node): return node.is_placement_ghost)
	var real: Array = walls.filter(func(node): return not node.is_placement_ghost)
	for index in 12:
		ghosts[index].sim_pos = real[index * 7].sim_pos + Walls.direction(index % 4)
	compare_all("ghosts moved next to walls in the same frame")
	ghosts[20].is_placement_ghost = false
	ghosts[21].is_placement_ghost = false
	compare_all("previews confirmed in the same frame")
	real[30].team = 1 - real[30].team
	real[31].team = 1 - real[31].team
	compare_all("team changed in the same frame")
	real[40].queue_free()
	real[41].queue_free()
	compare_all("walls queued for deletion in the same frame")
	real[50].free()
	real[51].free()
	compare_all("walls freed in the same frame")
	building("stone_wall", real[60].sim_pos + Vector2.RIGHT, real[60].team)
	building("gate", real[61].sim_pos + Walls.direction(2) * 2.5, real[61].team, 2)
	compare_all("walls added in the same frame")
	# Real buildings do not move; a move is reflected from the next frame.
	await process_frame
	real[70].sim_pos = real[71].sim_pos + Vector2.DOWN
	await process_frame
	compare_all("moved wall, next frame")
	# A second container in the same frame keeps its own snapshot.
	var first := entities
	entities = Node2D.new()
	root.add_child(entities)
	building("palisade_wall", Vector2.ZERO)
	building("palisade_wall", Vector2.RIGHT)
	building("palisade_wall", Vector2.LEFT)
	compare_all("second container")
	entities = first
	compare_all("first container again")
	check(by_shape.size() >= 4, "layouts cover posts and several connected axes (%s)" % [by_shape])
	print("WALL SHAPE INDEX: %d checks, %d failures, %d pieces compared, shapes %s" % [checks, failures, compared, by_shape])
	quit(0 if failures == 0 else 1)
