extends SceneTree
const Grid := preload("res://scripts/systems/nav_grid_service.gd")
const Holder := preload("res://scripts/systems/nav_service_holder.gd")
const Collision := preload("res://scripts/systems/collision_resolver.gd")
const Avoidance := preload("res://scripts/systems/local_avoidance.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Building := preload("res://scenes/entities/building_view.tscn")
const Blocker := preload("res://scripts/entities/path_blocker.gd")
class Box extends RefCounted:
	var sim_pos := Vector2.ZERO
	var block_half := Vector2.ONE
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func _run() -> void:
	for suite in ["test_collision_resolver", "test_nav_grid_service", "test_locomotion"]:
		var errors: Array = load("res://tests/%s.gd" % suite).new().run()
		check(errors.is_empty(), "%s: %s" % [suite, errors])
	_test_clearance_layers()
	_test_risk_equivalence()
	await _test_spatial_lifecycle()
	print("STATIC NAVIGATION: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _test_risk_equivalence() -> void:
	# Compare optimized pruning against the former complete collision calculation
	# across varying velocities, overlap escape, radii, and frame durations.
	var random := RandomNumberGenerator.new()
	random.seed = 673841
	for scenario in 500:
		var bodies: Array[Dictionary] = []
		for _body in 8:
			var relative := Vector2(random.randf_range(-10, 10), random.randf_range(-10, 10))
			bodies.append({"relative": relative, "distance_sq": relative.length_squared(),
				"velocity": Vector2(random.randf_range(-6, 6), random.randf_range(-6, 6)), "radius": random.randf_range(0.3, 2.2)})
		var velocity := Vector2(random.randf_range(-6, 6), random.randf_range(-6, 6))
		var delta := random.randf_range(0.01, 0.25)
		var reference := _reference_risk(velocity, delta, bodies)
		var actual := Avoidance._body_risk(velocity, delta, bodies)
		check((is_inf(reference) and is_inf(actual)) or is_equal_approx(reference, actual), "optimized body risk agrees with full evaluation for scenario %d" % scenario)
		var limit := random.randf_range(0.01, 8)
		var bounded := Avoidance._body_risk(velocity, delta, bodies, limit)
		check((reference >= limit and bounded >= limit) or (reference < limit and is_equal_approx(reference, bounded)), "early risk termination preserves candidate eligibility for scenario %d" % scenario)

func _reference_risk(velocity: Vector2, delta: float, bodies: Array[Dictionary]) -> float:
	var score := 0.0
	var motion := velocity * delta
	for body in bodies:
		var relative: Vector2 = body.relative
		var radius: float = body.radius
		if relative.length_squared() < radius * radius - 0.0001:
			if motion.dot(-relative) < -0.00001: return INF
		else:
			var closest := Geometry2D.get_closest_point_to_segment(relative, Vector2.ZERO, motion)
			if closest.distance_squared_to(relative) < radius * radius - 0.0001: return INF
		var contact := Avoidance.collision_time(relative, velocity - body.velocity, radius + Avoidance.MARGIN)
		if contact < Avoidance.HORIZON: score += 4.0 * (1.0 - contact / Avoidance.HORIZON)
	return score

func _test_clearance_layers() -> void:
	var nav := Grid.new()
	nav.setup_rect(Vector2i(-12, -9), Vector2i(16, 11))
	var box := Box.new()
	box.sim_pos = Vector2(0.25, 1.25)
	box.block_half = Vector2(2.0, 3.0)
	check(nav.rebuild_from_blockers([box]), "first geometry rebuild changes navigation")
	for radius in [0.35, 1.3, 0.7, 0.35, 1.3]:
		nav.is_world_walkable_with_radius(Vector2(-8, 0), radius)
		var interior := nav.get_map_rect().grow(-radius)
		var inflated := Rect2(box.sim_pos - box.block_half - Vector2.ONE * radius, (box.block_half + Vector2.ONE * radius) * 2)
		for y in range(-9, 11):
			for x in range(-12, 16):
				var cell := Vector2i(x, y)
				var rect := Rect2(Vector2(cell), Vector2.ONE)
				var expected := not interior.has_point(nav.cell_to_world_center(cell)) or rect.intersects(inflated)
				check(nav.is_cell_solid(cell) == expected, "radius %.2f sparse layer agrees with exact clearance at %s" % [radius, cell])
	check(not nav.rebuild_from_blockers([box]), "unchanged geometry avoids a rebuild")
	box.sim_pos = Vector2(5.25, 1.25)
	check(nav.rebuild_from_blockers([box]), "moved geometry invalidates clearance and paths")
	check(nav.is_world_walkable_with_radius(Vector2(-1, 1), 0.35), "old obstacle cells reopen after a geometry update")
	check(not nav.is_world_walkable_with_radius(box.sim_pos, 1.3), "large-radius cache incorporates the moved obstacle")
	nav.clear_solids()
	check(nav.is_world_walkable_with_radius(box.sim_pos, 1.3), "clearing sparse layers opens previously occupied cells")

func _test_spatial_lifecycle() -> void:
	var world := Node2D.new()
	root.add_child(world)
	var entities := Node2D.new()
	world.add_child(entities)
	var state := MatchState.new()
	state.setup_defaults()
	var holder := Holder.new()
	holder.setup(-32, 32)
	world.add_child(holder)
	var wall := Blocker.new()
	wall.auto_block_size = false
	wall.sim_pos = Vector2.ZERO
	wall.block_size = Vector2(30, 4)
	entities.add_child(wall)
	var tree := ResourceNode.new()
	tree.resource_type = Enums.ResourceType.WOOD
	tree.block_size_override = Vector2(4, 4)
	tree.sim_pos = Vector2(12, 16)
	entities.add_child(tree)
	var tc := Building.instantiate() as BuildingAgent
	tc.def = Catalog.get_building("town_center")
	tc.match_state = state
	tc.sim_pos = Vector2(10, -18)
	entities.add_child(tc)
	var house := Building.instantiate() as BuildingAgent
	house.def = Catalog.get_building("house").duplicate()
	house.match_state = state
	house.sim_pos = Vector2(-12, -16)
	house.is_placement_ghost = true
	house.start_construction()
	entities.add_child(house)
	await process_frame
	await process_frame
	holder.rebuild_from_scene()
	var wide := holder.query_static_blockers(Vector2(15.5, 0), Vector2(15.5, 0), 1)
	check(wall in wide, "spatial queries include a large blocker whose center lies in a distant bucket")
	check(wide.count(wall) == 1, "multi-bucket blockers occur once per query")
	check(wall in holder.query_static_blockers(Vector2(-30, 0), Vector2(30, 0), 0.35), "swept queries include blockers between endpoints")
	var route := holder.nav.find_path(Vector2(-20, 12), Vector2(20, -12), 0.35)
	check(not route.is_empty(), "simplified long path detours around the actual large blocker")
	for index in range(1, route.size()):
		check(Collision.static_step_safe(route[index - 1], route[index], 0.35, [wall, tree]), "every simplified segment respects continuous blocker geometry")
	check(tc not in holder.query_static_blockers(tc.sim_pos, tc.sim_pos, 2), "open town-center passage stays out of the collision index")
	check(house not in holder.query_static_blockers(house.sim_pos, house.sim_pos, 1), "placement ghosts do not collide")
	check(tree in holder.query_static_blockers(Vector2(14.4, 16), Vector2(14.4, 16), 0.5), "resource override footprint is honored at its edge")
	check(not holder.nav.is_world_walkable_with_radius(tree.sim_pos, 1.3), "a live tree blocks even the large-radius layer")
	house.clear_ghost_visual()
	await physics_frame
	await process_frame
	check(house in holder.query_static_blockers(house.sim_pos, house.sim_pos, 1), "confirming a ghost updates the collision index before movement")
	check(not holder.nav.is_world_walkable_with_radius(house.sim_pos, 0.35), "new foundation blocks navigation without waiting for completion")
	house.def.blocks_movement = false
	await physics_frame
	await process_frame
	check(house not in holder.query_static_blockers(house.sim_pos, house.sim_pos, 1), "building passage changes remove its static body")
	check(holder.nav.is_world_walkable_with_radius(house.sim_pos, 1.3), "building passage changes also reopen cached nav layers")
	tree.extract(100)
	check(tree.amount == 0, "tree actually depletes")
	check(tree not in holder.query_static_blockers(tree.sim_pos, tree.sim_pos, 1), "depleted tree disappears from nearby collision queries immediately")
	check(holder.nav.is_world_walkable_with_radius(tree.sim_pos, 1.3), "chopping opens the tree's cells in every radius cache")
	check(Collision.static_step_safe(tree.sim_pos - Vector2(3, 0), tree.sim_pos + Vector2(3, 0), 0.35, [tree]), "arbitrary collision lists also ignore exhausted resources")
	var fresh := ResourceNode.new()
	fresh.resource_type = Enums.ResourceType.GOLD
	fresh.sim_pos = Vector2(-20, 16)
	entities.add_child(fresh)
	check(fresh in holder.query_static_blockers(fresh.sim_pos, fresh.sim_pos, 1), "new resource nodes become indexed on the first movement query")
	var old_pos := fresh.sim_pos
	fresh.queue_free()
	await process_frame
	check(holder.query_static_blockers(old_pos, old_pos, 1).is_empty(), "removed nodes leave no stale spatial references")
	check(holder.nav.is_world_walkable_with_radius(old_pos, 0.35), "removed obstacles reopen navigation")
	world.queue_free()
	await process_frame
	Collision.clear_map_bounds()
