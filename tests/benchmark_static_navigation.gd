extends SceneTree
## Run unchanged before/after; measures the actual generated map's static work.
const Grid := preload("res://scripts/systems/nav_grid_service.gd")
const Avoidance := preload("res://scripts/systems/local_avoidance.gd")
const Field := preload("res://scripts/systems/unit_field.gd")
const Collision := preload("res://scripts/systems/collision_resolver.gd")
const Fixed := preload("res://scripts/core/sim_fixed.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")
class Probe extends RefCounted:
	var sim_pos := Vector2(-120, -120)
	var def: UnitDef
	var velocity := Vector2.ZERO

## One full (unscheduled) steering solve, script or native.
func _solve(field: RefCounted, key: int, body: Probe, preferred: Vector2, boxes: PackedInt64Array, use_native: bool) -> Vector2i:
	var radius := Fixed.coord(body.def.resolved_footprint_radius())
	var time := Fixed.time_from_seconds(1.0 / 60.0)
	var motion := Avoidance.motion_record(Fixed.vector(body.sim_pos), radius, Fixed.vector(preferred), Fixed.vector(body.velocity), time, Fixed.vector(body.sim_pos + preferred * 10.0), true, key)
	var bounds := PackedInt64Array([0, 0, 0, 0, 0])
	if use_native: return field.steer(key, motion, boxes, bounds, {})
	return Avoidance.steer_with_field(field, key, motion, boxes, [], bounds, {})

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
	var empty := Field.new()
	var radius_q := Fixed.coord(unit.def.resolved_footprint_radius())
	var all_boxes: PackedInt64Array = Collision.static_boxes(blockers, radius_q)[0]
	var avoid_ms := _time(func(): _solve(empty, 1, unit, Vector2(3.2, 0), all_boxes, false), 100)
	var holder := world.get_node("NavService")
	var query_ms := -1.0
	var local_count := -1
	var local_avoid_ms := -1.0
	if holder.has_method("query_static_blockers"):
		query_ms = _time(func(): holder.query_static_blockers(unit.sim_pos, unit.sim_pos, 5.0), 100)
		var local: Array = holder.query_static_blockers(unit.sim_pos, unit.sim_pos, 5.0)
		local_count = local.size()
		var local_boxes: PackedInt64Array = holder.query_static_boxes(unit.sim_pos, 5.0, radius_q)[0]
		local_avoid_ms = _time(func(): _solve(empty, 1, unit, Vector2(3.2, 0), local_boxes, false), 100)
	var result := {"entities": world.get_node("Entities").get_child_count(), "blockers": blockers.size(),
		"map_size": [bounds.size.x,bounds.size.y], "setup_ms": setup_ms, "rebuild_ms": rebuild_ms,
		"unchanged_rebuild_ms": unchanged_rebuild_ms,
		"two_cached_radius_switches_ms": radius_ms, "long_path_ms": path_ms, "cached_path_ms": cached_path_ms,
		"avoid_all_blockers_ms": avoid_ms, "spatial_query_ms": query_ms, "spatial_local_count": local_count,
		"avoid_local_ms": local_avoid_ms}
	var crowd: Array[Probe] = []
	for index in 48:
		var body := Probe.new()
		body.def = Catalog.get_unit("militia")
		body.sim_pos = Vector2(index % 8, index / 8) * 2.0
		body.velocity = Vector2(3.6, 0)
		crowd.append(body)
	var fields := {"script": Field.new()}
	if Field.native_available(): fields["native"] = ClassDB.instantiate("AoeUnitField")
	for label in fields:
		var field: RefCounted = fields[label]
		for velocity in [Vector2(3.6, 0), Vector2.ZERO]:
			for index in crowd.size():
				crowd[index].velocity = velocity
				field.set_unit(index + 1, Fixed.vector(crowd[index].sim_pos), Fixed.coord(crowd[index].def.resolved_footprint_radius()), Fixed.vector(velocity), true)
			var name := "%s_48_avoidance_%s_ms" % ["aligned" if velocity != Vector2.ZERO else "stationary", label]
			result[name] = _time(func():
				for index in crowd.size():
					_solve(field, index + 1, crowd[index], Vector2(3.6, 0), PackedInt64Array(), label == "native")
			, 50 if velocity != Vector2.ZERO else 20)
	var suffix := "before" if "--before" in OS.get_cmdline_user_args() else "after"
	if "--crowd-before" in OS.get_cmdline_user_args(): suffix = "avoidance-before"
	var file := FileAccess.open("res://.godot/navigation-%s.json" % suffix, FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "  "))
	print("NAVIGATION BENCHMARK: ", JSON.stringify(result))
	quit()
