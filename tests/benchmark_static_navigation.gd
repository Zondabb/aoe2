extends SceneTree
## Run unchanged before/after; measures the actual generated map's static work.
const Grid := preload("res://scripts/systems/nav_grid_service.gd")
const Avoidance := preload("res://scripts/systems/local_avoidance.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")
class Probe extends RefCounted:
	var sim_pos := Vector2(-120, -120)
	var def: UnitDef
	var hp := 30.0
	var velocity := Vector2.ZERO
	func locomotion_velocity() -> Vector2:
		return velocity

func _initialize() -> void:
	call_deferred("_run")

func _time(operation: Callable, count: int) -> float:
	var start := Time.get_ticks_usec()
	for iteration in count: operation.call()
	return float(Time.get_ticks_usec() - start) / (1000.0 * count)

func _run() -> void:
	var session := root.get_node("GameSession")
	session.match_ai_mode = "sandbox"
	session.match_map_data = {}
	session.online_active = false
	var world := load("res://scenes/match_2d.tscn").instantiate() as Node
	root.add_child(world)
	current_scene = world
	await process_frame
	await process_frame
	world.process_mode = Node.PROCESS_MODE_DISABLED
	var blockers := Grid.collect_blockers_from_tree(self)
	var bounds: Rect2 = world.get_node("Bootstrap").map_bounds
	var nav := Grid.new()
	var setup_ms := _time(func(): nav.setup_rect(Vector2i(bounds.position), Vector2i(bounds.end)), 1)
	var rebuild_ms := _time(func(): nav.rebuild_from_blockers(blockers), 3)
	var unchanged_rebuild_ms := _time(func(): nav.rebuild_from_blockers(blockers), 20)
	# Warm both clearance layers before measuring radius changes.
	nav.is_world_walkable_with_radius(Vector2(-120, -120), 0.35)
	nav.is_world_walkable_with_radius(Vector2(-120, -120), 1.3)
	var radius_ms := _time(func():
		nav.is_world_walkable_with_radius(Vector2(-120, -120), 0.35)
		nav.is_world_walkable_with_radius(Vector2(-120, -120), 1.3)
	, 12)
	var path_ms := _time(func(): nav.find_path(Vector2(-120, -120), Vector2(120, 120), 0.35), 1)
	var cached_path_ms := _time(func(): nav.find_path(Vector2(-120, -120), Vector2(120, 120), 0.35), 20)
	var unit := Probe.new()
	unit.def = Catalog.get_unit("villager")
	var avoid_ms := _time(func(): Avoidance.step(unit, Vector2(3.2, 0), Vector2.ZERO, 1.0 / 60.0, [], blockers), 100)
	var holder := world.get_node("NavService")
	var query_ms := -1.0
	var local_count := -1
	var local_avoid_ms := -1.0
	if holder.has_method("query_static_blockers"):
		query_ms = _time(func(): holder.query_static_blockers(unit.sim_pos, unit.sim_pos, 5.0), 100)
		var local: Array = holder.query_static_blockers(unit.sim_pos, unit.sim_pos, 5.0)
		local_count = local.size()
		local_avoid_ms = _time(func(): Avoidance.step(unit, Vector2(3.2, 0), Vector2.ZERO, 1.0 / 60.0, [], local), 100)
	var result := {"entities": world.get_node("Entities").get_child_count(), "blockers": blockers.size(),
		"map_size": [bounds.size.x,bounds.size.y], "setup_ms": setup_ms, "rebuild_ms": rebuild_ms,
		"unchanged_rebuild_ms": unchanged_rebuild_ms,
		"two_cached_radius_switches_ms": radius_ms, "long_path_ms": path_ms, "cached_path_ms": cached_path_ms,
		"avoid_all_blockers_ms": avoid_ms, "spatial_query_ms": query_ms, "spatial_local_count": local_count,
		"avoid_local_ms": local_avoid_ms}
	var crowd: Array[Probe] = []
	var neighbors: Array[Array] = []
	for index in 48:
		var body := Probe.new()
		body.def = Catalog.get_unit("militia")
		body.sim_pos = Vector2(index % 8, index / 8) * 2.0
		body.velocity = Vector2(3.6, 0)
		crowd.append(body)
	for body in crowd:
		var nearby: Array = []
		for other in crowd:
			if other != body and body.sim_pos.distance_squared_to(other.sim_pos) <= 100:
				nearby.append(other)
		neighbors.append(nearby)
	result["aligned_48_avoidance_ms"] = _time(func():
		for index in crowd.size():
			Avoidance.step(crowd[index], Vector2(3.6, 0), Vector2(3.6, 0), 1.0 / 60.0, neighbors[index], [])
	, 50)
	for body in crowd: body.velocity = Vector2.ZERO
	result["stationary_48_avoidance_ms"] = _time(func():
		for index in crowd.size():
			Avoidance.step(crowd[index], Vector2(3.6, 0), Vector2.ZERO, 1.0 / 60.0, neighbors[index], [])
	, 20)
	var suffix := "before" if "--before" in OS.get_cmdline_user_args() else "after"
	if "--crowd-before" in OS.get_cmdline_user_args(): suffix = "avoidance-before"
	var file := FileAccess.open("res://.godot/navigation-%s.json" % suffix, FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "  "))
	print("NAVIGATION BENCHMARK: ", JSON.stringify(result))
	quit()
