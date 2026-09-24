extends SceneTree

const Agent := preload("res://scripts/entities/unit_agent.gd")
const Holder := preload("res://scripts/systems/nav_service_holder.gd")
const Vision := preload("res://scripts/systems/vision_service_holder.gd")
const Blocker := preload("res://scripts/entities/path_blocker.gd")
var failures: Array[String] = []
var metrics: Array[Dictionary] = []
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)

func _run() -> void:
	for suite in ["test_collision_resolver", "test_locomotion", "test_nav_grid_service"]:
		var errors: Array = load("res://tests/%s.gd" % suite).new().run()
		check(errors.is_empty(), "%s: %s" % [suite, str(errors)])
	_test_geometry_and_queue()
	_scenario("head_on", [Vector2(-12, 0), Vector2(12, 0)], [Vector2(12, 0), Vector2(-12, 0)])
	_scenario("idle_bypass", [Vector2(-12, 0), Vector2.ZERO], [Vector2(12, 0), null])
	var starts: Array = []
	var targets: Array = []
	for row in 3:
		for column in 3:
			starts.append(Vector2(-15 - column * 3.3, (row - 1) * 3.3))
			targets.append(Vector2(12, 0))
	_scenario("shared_goal_9", starts, targets)
	starts = []
	targets = []
	for direction in [-1, 1]:
		for row in 3:
			starts.append(Vector2(direction * 14, (row - 1) * 3.5))
			targets.append(Vector2(-direction * 14, (row - 1) * 3.5))
	_scenario("opposing_groups_6", starts, targets)
	_scenario("corridor", [Vector2(-14, -1.5), Vector2(14, 1.5)], [Vector2(14, -1.5), Vector2(-14, 1.5)], true)
	_scenario("origin_goal", [Vector2(-12, 0), Vector2(-6, 0)], [Vector2.ZERO, null])
	_scenario("head_on_60hz", [Vector2(-12, 0), Vector2(12, 0)], [Vector2(12, 0), Vector2(-12, 0)], false, 1.0 / 60.0)
	_scenario("head_on_10hz", [Vector2(-12, 0), Vector2(12, 0)], [Vector2(12, 0), Vector2(-12, 0)], false, 0.1)
	_scenario("shared_goal_9_reversed", [Vector2(-21.6, 3.3), Vector2(-18.3, 3.3), Vector2(-15, 3.3), Vector2(-21.6, 0), Vector2(-18.3, 0), Vector2(-15, 0), Vector2(-21.6, -3.3), Vector2(-18.3, -3.3), Vector2(-15, -3.3)], [Vector2(12,0), Vector2(12,0), Vector2(12,0), Vector2(12,0), Vector2(12,0), Vector2(12,0), Vector2(12,0), Vector2(12,0), Vector2(12,0)])
	_test_reopening_route()
	var file := FileAccess.open("res://.godot/crowd-metrics.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(metrics, "  "))
	file.close()
	print("CROWD MOVEMENT: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _scenario(label: String, starts: Array, targets: Array, corridor := false, delta := 1.0 / 30.0) -> void:
	var world := Node2D.new()
	root.add_child(world)
	var state := MatchState.new()
	state.setup_defaults()
	var holder := Holder.new()
	holder.setup(-32, 32)
	world.add_child(holder)
	holder.set_process(false)
	var vision := Vision.new()
	vision.setup()
	world.add_child(vision)
	if corridor:
		for side in [-1, 1]:
			var wall := Blocker.new()
			wall.sim_pos = Vector2(0, side * 7)
			wall.auto_block_size = false
			wall.block_size = Vector2(16, 7)
			world.add_child(wall)
	var units: Array[UnitAgent] = []
	for index in starts.size():
		var unit := Agent.new()
		unit.name = "Crowd%d" % index
		unit.def = load("res://data/units/villager.tres")
		unit.match_state = state
		unit.sim_pos = starts[index]
		world.add_child(unit)
		unit.set_physics_process(false)
		units.append(unit)
	holder.rebuild_from_scene()
	vision.rebuild_from_scene()
	for index in units.size():
		if targets[index] is Vector2:
			units[index].command_move(targets[index])
	var minimum_separation := INF
	var max_stall := 0.0
	var stalled := []
	var arrived := 0
	var stayed_in_corridor := true
	var speed_respected := true
	var finish_time := 24.0
	stalled.resize(units.size())
	stalled.fill(0.0)
	var started := Time.get_ticks_usec()
	for frame in int(24.0 / delta):
		var paths := holder.nav.flush_pending_paths()
		for id in paths:
			instance_from_id(id).apply_nav_path(paths[id])
		for index in units.size():
			var unit := units[index]
			var before := unit.sim_pos
			unit._physics_process(delta)
			speed_respected = speed_respected and before.distance_to(unit.sim_pos) <= unit.def.move_speed * delta + 0.0001
			if unit.order == Enums.OrderType.MOVE and before.distance_to(unit.sim_pos) < 0.001:
				stalled[index] += delta
			else:
				stalled[index] = 0.0
			max_stall = maxf(max_stall, stalled[index])
		for i in units.size():
			for j in range(i + 1, units.size()):
				minimum_separation = minf(minimum_separation, units[i].sim_pos.distance_to(units[j].sim_pos))
		if corridor:
			for unit in units:
				stayed_in_corridor = stayed_in_corridor and absf(unit.sim_pos.y) < 2.21
		arrived = 0
		var expected := 0
		for index in units.size():
			if targets[index] is Vector2:
				expected += 1
				if units[index].order == Enums.OrderType.NONE and units[index].sim_pos.distance_to(units[index]._move_target) <= 0.5:
					arrived += 1
		if arrived == expected:
			finish_time = (frame + 1) * delta
			break
	var expected: int = targets.filter(func(value: Variant): return value is Vector2).size()
	var metric := {"scenario": label, "arrived": arrived, "expected": expected, "sim_seconds": snappedf(finish_time, 0.01), "min_separation": snappedf(minimum_separation, 0.001), "longest_stall": snappedf(max_stall, 0.01), "cpu_ms": (Time.get_ticks_usec() - started) / 1000.0}
	metrics.append(metric)
	print("CROWD_METRIC ", JSON.stringify(metric))
	if arrived != expected:
		for unit in units:
			print("CROWD_PENDING ", unit.name, " pos=", unit.sim_pos, " goal=", unit._move_target, " order=", unit.order, " path=", unit.get_nav_path_debug())
	check(arrived == expected, "%s: all commanded units arrive" % label)
	check(minimum_separation >= 2.58, "%s: units keep their 2.6-tile combined diameter" % label)
	check(max_stall < 3.0, "%s: no persistent mutual stall" % label)
	check(speed_respected, "%s: avoidance respects movement speed" % label)
	if corridor:
		check(stayed_in_corridor, "corridor: travel remains between inflated walls")
	for index in units.size():
		if targets[index] == null:
			check(units[index].sim_pos == starts[index], "%s: idle unit is not pushed or teleported" % label)
		elif label.begins_with("shared_goal"):
			check(units[index].sim_pos.distance_to(targets[index]) <= 7.9, "%s: shared-goal arrival stays inside the rally area" % label)
		else:
			check(units[index].sim_pos.distance_to(targets[index]) <= 0.5, "%s: solo destination remains exact" % label)
	world.free()
	CollisionResolver.clear_map_bounds()

func _test_geometry_and_queue() -> void:
	var body := Agent.new()
	body.def = load("res://data/units/villager.tres")
	var other := Agent.new()
	other.def = body.def
	other.hp = 25
	other.sim_pos = Vector2.ZERO
	check(not CollisionResolver.is_step_safe(body, Vector2(-4,0), Vector2(4,0), [other], []), "swept circles prevent large-step tunneling")
	check(CollisionResolver.is_step_safe(body, Vector2(-2,0), Vector2(-2,1), [other], []), "overlap can escape sideways")
	check(not CollisionResolver.is_step_safe(body, Vector2(-2,0), Vector2(4,0), [other], []), "overlap cannot escape through the opposite side")
	check(CollisionResolver.segment_hits_box(Vector2(-4,0), Vector2(4,0), Vector2.ONE), "swept AABB prevents wall tunneling")
	check(not CollisionResolver.segment_hits_box(Vector2(-4,1), Vector2(4,1), Vector2.ONE), "swept AABB permits tangent travel")
	var nav := NavGridService.new()
	nav.setup_rect(Vector2i(-20,-12), Vector2i(20,12))
	nav.set_frame_budget(2)
	for id in 5:
		nav.enqueue_path(id, Vector2(-10,0), Vector2(10,0), 1.3, [other])
	check(nav.flush_pending_paths().size() == 2 and nav.pending_count() == 3, "crowd recovery respects shared path budget")
	nav.cancel_path(3)
	check(nav.pending_count() == 2, "cancel removes queued requests")
	check(not nav.is_world_walkable_with_radius(Vector2(-19.5,0), 1.3), "navigation respects radius at map boundary")
	check(nav._quantize_radius(1.31) >= 1.31, "radius quantization never underestimates clearance")
	var original := nav.find_path(Vector2(-10,0), Vector2(10,0), 1.3)
	var detour := nav.find_path_avoiding_units(Vector2(-10,0), Vector2(10,0), 1.3, [other])
	check(not detour.is_empty(), "temporary crowd path exists")
	for index in range(1, detour.size()):
		check(CollisionResolver.is_step_safe(body, detour[index-1], detour[index], [other], []), "crowd path accounts for both unit radii")
	check(nav.find_path(Vector2(-10,0), Vector2(10,0), 1.3) == original, "temporary occupancy does not poison static path cache")
	body.free()
	other.free()

func _test_reopening_route() -> void:
	var world := Node2D.new()
	root.add_child(world)
	var holder := Holder.new()
	holder.setup(-20,20)
	world.add_child(holder)
	holder.set_process(false)
	var wall := Blocker.new()
	wall.auto_block_size = false
	wall.block_size = Vector2(2,40)
	world.add_child(wall)
	var unit := Agent.new()
	unit.def = load("res://data/units/villager.tres")
	unit.sim_pos = Vector2(-8,0)
	world.add_child(unit)
	unit.set_physics_process(false)
	holder.rebuild_from_scene()
	unit.command_move(Vector2(8,0))
	for frame in 480:
		if frame == 120:
			check(unit.sim_pos == Vector2(-8,0) and unit.order == Enums.OrderType.MOVE, "unreachable path waits instead of walking into the wall")
			wall.free()
			holder.rebuild_from_scene()
		var paths := holder.nav.flush_pending_paths()
		for id in paths:
			instance_from_id(id).apply_nav_path(paths[id])
		unit._physics_process(1.0 / 30.0)
	check(unit.sim_pos.distance_to(Vector2(8,0)) < 0.2 and unit.order == Enums.OrderType.NONE, "unit resumes after a four-second blockage clears")
	unit.command_move(Vector2(-8,0))
	unit.command_stop()
	check(holder.nav.pending_count() == 0 and not unit._path_pending, "stop cancels pending navigation")
	# Shared-goal arrival must never declare success from across a solid wall.
	wall = Blocker.new()
	wall.auto_block_size = false
	wall.block_size = Vector2(1,40)
	world.add_child(wall)
	holder.rebuild_from_scene()
	unit.sim_pos = Vector2(-2,0)
	unit._requested_move_target = Vector2(2,0)
	unit._move_target = Vector2(2,0)
	unit._has_move_command = true
	unit.order = Enums.OrderType.MOVE
	for index in 3:
		var peer := Agent.new()
		peer.def = unit.def
		peer.sim_pos = Vector2(2, index * 3)
		world.add_child(peer)
		peer.set_physics_process(false)
		peer._has_move_command = true
		peer._requested_move_target = Vector2(2,0)
	check(not unit._try_settle_shared_goal(), "shared-goal arrival cannot accept the wrong side of a wall")
	world.free()
	CollisionResolver.clear_map_bounds()
