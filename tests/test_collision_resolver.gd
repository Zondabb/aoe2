extends RefCounted

const CollisionResolverScript := preload("res://scripts/systems/collision_resolver.gd")

class _TestBody extends RefCounted:
	var def: Resource
	var sim_pos: Vector2
	var team: Enums.Team = Enums.Team.PLAYER
	var order: Enums.OrderType = Enums.OrderType.MOVE

func run() -> Array[String]:
	var failures: Array[String] = []
	CollisionResolverScript.reset_unit_block_angle_degrees()
	_test_building_blocks_movement(failures)
	_test_building_sideways_slide_allowed(failures)
	_test_building_can_move_away(failures)
	_test_unit_forward_cone_blocks(failures)
	_test_unit_can_move_when_clear(failures)
	_test_unit_can_move_away(failures)
	_test_unit_sideways_slide_allowed(failures)
	_test_can_approach_until_separation_zone(failures)
	_test_block_angle_is_configurable(failures)
	_test_map_bounds_clamp(failures)
	CollisionResolverScript.reset_unit_block_angle_degrees()
	return failures

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
	# Overlap the west face; pure lateral step has ~90° to center → allowed.
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

func _test_unit_forward_cone_blocks(failures: Array[String]) -> void:
	var mover := _make_unit(Vector2(0.0, 0.0), 0.42)
	var blocker := _make_unit(Vector2(0.55, 0.0), 0.42)
	var from_pos := Vector2(0.0, 0.0)
	# Straight toward blocker: angle 0° < 45° → blocked.
	var desired := Vector2(0.25, 0.0)
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		mover, from_pos, desired, [mover, blocker], []
	)
	if resolved.distance_to(from_pos) > 0.001:
		failures.append(
			"step into forward block cone should stop at from_pos, got %s" % resolved
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
	# Away: angle 180° > 45° → allowed.
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
	# Pure lateral: angle 90° > 45° → allowed even while overlapping.
	var desired := Vector2(0.0, 0.25)
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		mover, from_pos, desired, [mover, blocker], []
	)
	if resolved.distance_to(desired) > 0.001:
		failures.append(
			"sideways step outside block cone should be allowed, got %s" % resolved
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
	# Entering bubble while aimed at blocker (angle 0°) → blocked.
	var desired_inside := Vector2(2.0 - min_dist + 0.05, 0.0)
	var resolved_inside: Vector2 = CollisionResolverScript.resolve_move(
		mover, from_pos, desired_inside, [mover, blocker], []
	)
	if resolved_inside.distance_to(from_pos) > 0.001:
		failures.append(
			"approach into separation zone in forward cone should stop, got %s" % resolved_inside
		)

func _test_block_angle_is_configurable(failures: Array[String]) -> void:
	var mover := _make_unit(Vector2(0.0, 0.0), 0.42)
	var blocker := _make_unit(Vector2(0.55, 0.0), 0.42)
	var from_pos := Vector2(0.0, 0.0)
	# 60° from +X toward blocker on +X: angle ≈ 60°.
	var desired := Vector2(0.15, 0.15 * sqrt(3.0))
	CollisionResolverScript.set_unit_block_angle_degrees(45.0)
	var allowed: Vector2 = CollisionResolverScript.resolve_move(
		mover, from_pos, desired, [mover, blocker], []
	)
	if allowed.distance_to(desired) > 0.001:
		failures.append("60° step should pass with 45° cone, got %s" % allowed)
	CollisionResolverScript.set_unit_block_angle_degrees(70.0)
	var blocked: Vector2 = CollisionResolverScript.resolve_move(
		mover, from_pos, desired, [mover, blocker], []
	)
	if blocked.distance_to(from_pos) > 0.001:
		failures.append("60° step should block with 70° cone, got %s" % blocked)
	CollisionResolverScript.reset_unit_block_angle_degrees()

func _test_map_bounds_clamp(failures: Array[String]) -> void:
	CollisionResolverScript.set_map_bounds(Vector2(-10.0, -10.0), Vector2(10.0, 10.0))
	var unit := _make_unit(Vector2(9.8, 0.0), 0.35)
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		unit, unit.sim_pos, Vector2(12.0, 0.0), [], []
	)
	if resolved.x > 10.0 - 0.35 + 0.001:
		failures.append("units should not move past map max bound, got %s" % resolved)
	CollisionResolverScript.clear_map_bounds()
