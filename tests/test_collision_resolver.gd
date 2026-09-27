extends RefCounted

const CollisionResolverScript := preload("res://scripts/systems/collision_resolver.gd")
const LocalAvoidanceScript := preload("res://scripts/systems/local_avoidance.gd")
const TOWN_CENTER := preload("res://data/buildings/town_center.tres")

class _TestBody extends RefCounted:
	var def: Resource
	var sim_pos: Vector2
	var team: Enums.Team = Enums.Team.PLAYER
	var order: Enums.OrderType = Enums.OrderType.MOVE
	var block_half := Vector2.ZERO

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_building_blocks_movement(failures)
	_test_town_center_allows_movement(failures)
	_test_building_sideways_slide_allowed(failures)
	_test_building_can_move_away(failures)
	_test_unit_overlap_blocks(failures)
	_test_unit_can_move_when_clear(failures)
	_test_unit_can_move_away(failures)
	_test_unit_sideways_slide_allowed(failures)
	_test_can_approach_until_separation_zone(failures)
	_test_map_bounds_clamp(failures)
	return failures

func _test_town_center_allows_movement(failures: Array[String]) -> void:
	var town_center := _make_building(Vector2.ZERO)
	town_center.def = TOWN_CENTER
	# A cached positive footprint must not override the definition's open passage.
	town_center.block_half = Vector2(2, 2)
	for radius in [0.35, 1.3]:
		var unit := _make_unit(Vector2(-5, 0), radius)
		for direction in [Vector2.RIGHT, Vector2.DOWN, Vector2.ONE.normalized()]:
			var from: Vector2 = direction * -5.0
			var to: Vector2 = direction * 5.0
			var crossed := CollisionResolverScript.resolve_move(unit, from, to, [], [town_center])
			if not crossed.is_equal_approx(to):
				failures.append("town center should allow crossing for radius %s" % radius)
			var entered := CollisionResolverScript.resolve_move(unit, from, Vector2.ZERO, [], [town_center])
			if not entered.is_equal_approx(Vector2.ZERO):
				failures.append("town center center should be a valid movement destination")
		unit.sim_pos = Vector2(-3, 0)
		var next := LocalAvoidanceScript.step(unit, Vector2(4, 0), Vector2(4, 0), 0.25, [], [town_center])
		if not next.is_equal_approx(Vector2(-2, 0)):
			failures.append("local avoidance should not steer away from an open town center")
	if TOWN_CENTER.footprint != Vector2(4, 4):
		failures.append("town center movement must preserve its placement footprint")

func _make_unit(pos: Vector2, radius: float = 0.35) -> Object:
	var u := _TestBody.new()
	var def := UnitDef.new()
	def.footprint_radius = radius
	u.def = def
	u.sim_pos = pos
	return u

func _make_building(pos: Vector2, footprint: Vector2 = Vector2(2, 2)) -> Object:
	var b := _TestBody.new()
	var def := BuildingDef.new()
	def.footprint = footprint
	b.def = def
	b.sim_pos = pos
	return b

func _test_building_blocks_movement(failures: Array[String]) -> void:
	var unit := _make_unit(Vector2(-2.0, 0.0), 0.35)
	var building := _make_building(Vector2(0, 0), Vector2(2, 2))
	var from_pos := Vector2(-2.0, 0.0)
	var desired := Vector2(-1.0, 0.8)
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		unit, from_pos, desired, [], [building]
	)
	if resolved.distance_to(from_pos) > 0.001:
		failures.append("movement into building should stop at from_pos, got %s" % resolved)

func _test_building_sideways_slide_allowed(failures: Array[String]) -> void:
	# Overlap the west face; sliding keeps penetration from increasing.
	var unit := _make_unit(Vector2(-1.2, 0.0), 0.35)
	var building := _make_building(Vector2(0, 0), Vector2(2, 2))
	var from_pos := Vector2(-1.2, 0.0)
	var desired := Vector2(-1.2, 0.25)
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		unit, from_pos, desired, [], [building]
	)
	if resolved.distance_to(desired) > 0.001:
		failures.append(
			"sideways step beside building should be allowed, got %s" % resolved
		)

func _test_building_can_move_away(failures: Array[String]) -> void:
	var unit := _make_unit(Vector2(-1.0, 0.0), 0.35)
	var building := _make_building(Vector2(0, 0), Vector2(2, 2))
	var from_pos := Vector2(-1.0, 0.0)
	var desired := Vector2(-1.5, 0.0)
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		unit, from_pos, desired, [], [building]
	)
	if resolved.distance_to(desired) > 0.001:
		failures.append("step away from building overlap should be allowed, got %s" % resolved)

func _test_unit_overlap_blocks(failures: Array[String]) -> void:
	var mover := _make_unit(Vector2(0.0, 0.0), 0.42)
	var blocker := _make_unit(Vector2(0.55, 0.0), 0.42)
	var from_pos := Vector2(0.0, 0.0)
	# A step toward the blocker increases penetration and must be rejected.
	var desired := Vector2(0.25, 0.0)
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		mover, from_pos, desired, [mover, blocker], []
	)
	if resolved.distance_to(from_pos) > 0.001:
		failures.append(
			"step into an overlapping body should stop at from_pos, got %s" % resolved
		)

func _test_unit_can_move_when_clear(failures: Array[String]) -> void:
	var mover := _make_unit(Vector2(0.0, 0.0), 0.42)
	var from_pos := Vector2(0.0, 0.0)
	var desired := Vector2(0.25, 0.0)
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		mover, from_pos, desired, [mover], []
	)
	if resolved.distance_to(desired) > 0.001:
		failures.append("open step should reach desired position, got %s" % resolved)

func _test_unit_can_move_away(failures: Array[String]) -> void:
	var mover := _make_unit(Vector2(0.0, 0.0), 0.42)
	var blocker := _make_unit(Vector2(0.55, 0.0), 0.42)
	var from_pos := Vector2(0.0, 0.0)
	# Movement away from the overlap is allowed.
	var desired := Vector2(-0.5, 0.0)
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		mover, from_pos, desired, [mover, blocker], []
	)
	if resolved.distance_to(desired) > 0.001:
		failures.append("step away from overlap should be allowed, got %s" % resolved)

func _test_unit_sideways_slide_allowed(failures: Array[String]) -> void:
	var mover := _make_unit(Vector2(0.0, 0.0), 0.42)
	var blocker := _make_unit(Vector2(0.55, 0.0), 0.42)
	var from_pos := Vector2(0.0, 0.0)
	# A tangent step does not increase the existing overlap.
	var desired := Vector2(0.0, 0.25)
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		mover, from_pos, desired, [mover, blocker], []
	)
	if resolved.distance_to(desired) > 0.001:
		failures.append(
			"tangent step away from overlap should be allowed, got %s" % resolved
		)

func _test_can_approach_until_separation_zone(failures: Array[String]) -> void:
	var mover := _make_unit(Vector2(0.0, 0.0), 0.42)
	var blocker := _make_unit(Vector2(2.0, 0.0), 0.42)
	var min_dist := CollisionResolverScript.min_unit_separation(0.42, 0.42)
	var from_pos := Vector2(0.0, 0.0)
	var desired_outside := Vector2(min_dist * 0.4, 0.0)
	var resolved_outside: Vector2 = CollisionResolverScript.resolve_move(
		mover, from_pos, desired_outside, [mover, blocker], []
	)
	if resolved_outside.distance_to(desired_outside) > 0.001:
		failures.append("units far apart should be able to approach, got %s" % resolved_outside)
	# Entering another unit's circle must be rejected.
	var desired_inside := Vector2(2.0 - min_dist + 0.05, 0.0)
	var resolved_inside: Vector2 = CollisionResolverScript.resolve_move(
		mover, from_pos, desired_inside, [mover, blocker], []
	)
	if resolved_inside.distance_to(from_pos) > 0.001:
		failures.append(
			"approach into separation zone should stop, got %s" % resolved_inside
		)

func _test_map_bounds_clamp(failures: Array[String]) -> void:
	CollisionResolverScript.set_map_bounds(Vector2(-10.0, -10.0), Vector2(10.0, 10.0))
	var unit := _make_unit(Vector2(9.8, 0.0), 0.35)
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		unit, unit.sim_pos, Vector2(12.0, 0.0), [], []
	)
	if resolved.x > 10.0 - 0.35 + 0.001:
		failures.append("units should not move past map max bound, got %s" % resolved)
	CollisionResolverScript.clear_map_bounds()
