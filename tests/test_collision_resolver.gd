extends RefCounted

const CollisionResolverScript := preload("res://scripts/systems/collision_resolver.gd")

class _TestBody extends RefCounted:
	var def: Resource
	var sim_pos: Vector2
	var team: Enums.Team = Enums.Team.PLAYER
	var order: Enums.OrderType = Enums.OrderType.MOVE

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_building_push_out(failures)
	_test_unit_soft_separate(failures)
	_test_wall_slide_keeps_tangent(failures)
	_test_map_bounds_clamp(failures)
	_test_unit_separation_distance(failures)
	_test_unit_slide_when_blocked(failures)
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

func _test_building_push_out(failures: Array[String]) -> void:
	var unit := _make_unit(Vector2.ZERO, 0.35)
	var building := _make_building(Vector2.ZERO, Vector2(2, 2))
	var half := Vector2(1, 1) + Vector2(0.35, 0.35)
	# from_pos already inside expanded AABB; slide cannot escape, push-out must run.
	var from_pos := Vector2(-1.0, 0.0)
	var desired := Vector2(-0.5, 0.0)
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		unit, from_pos, desired, [], [building]
	)
	if absf(resolved.x) < half.x and absf(resolved.y) < half.y:
		failures.append(
			"push-out must leave expanded AABB when starting inside, got %s" % resolved
		)
	if absf(resolved.x) < half.x - 0.001:
		failures.append(
			"push-out should exit on nearest X face at ±%.2f, got %s" % [half.x, resolved]
		)

func _test_unit_soft_separate(failures: Array[String]) -> void:
	var self_unit := _make_unit(Vector2(0, 0), 0.42)
	var other := _make_unit(Vector2(0.2, 0.0), 0.42)
	var before: float = self_unit.get("sim_pos").distance_to(other.get("sim_pos"))
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		self_unit, Vector2(0, 0), Vector2(0, 0), [self_unit, other], []
	)
	var after := resolved.distance_to(other.get("sim_pos"))
	var expected := CollisionResolverScript.min_unit_separation(0.42, 0.42)
	if after <= before + 0.001:
		failures.append("soft separate should increase distance, before=%s after=%s" % [before, after])
	if after < expected - 0.05:
		failures.append(
			"soft separate should push toward min separation (got %s, want ~%s)" % [after, expected]
		)

func _test_wall_slide_keeps_tangent(failures: Array[String]) -> void:
	# Building occupies x in [-1,1], y in [-1,1]. Unit radius 0.35 → solid expanded x in [-1.35,1.35].
	var unit := _make_unit(Vector2(-2.0, 0.0), 0.35)
	var building := _make_building(Vector2(0, 0), Vector2(2, 2))
	var from_pos := Vector2(-2.0, 0.0)
	var desired := Vector2(-1.0, 0.8) # into the wall + upward
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		unit, from_pos, desired, [], [building]
	)
	if absf(resolved.x) < 1.35 - 0.001:
		failures.append("slide must not enter building on X, got %s" % resolved)
	if resolved.y < 0.4:
		failures.append("slide should keep most of tangent Y motion, got %s" % resolved)

func _test_map_bounds_clamp(failures: Array[String]) -> void:
	CollisionResolverScript.set_map_bounds(Vector2(-10.0, -10.0), Vector2(10.0, 10.0))
	var unit := _make_unit(Vector2(9.8, 0.0), 0.35)
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		unit, unit.sim_pos, Vector2(12.0, 0.0), [], []
	)
	if resolved.x > 10.0 - 0.35 + 0.001:
		failures.append("units should not move past map max bound, got %s" % resolved)
	CollisionResolverScript.clear_map_bounds()

func _test_unit_separation_distance(failures: Array[String]) -> void:
	var expected := CollisionResolverScript.min_unit_separation(0.42, 0.42)
	var self_unit := _make_unit(Vector2(0, 0), 0.42)
	var other := _make_unit(Vector2(0.2, 0.0), 0.42)
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		self_unit, Vector2(0, 0), Vector2(0, 0), [self_unit, other], []
	)
	if resolved.distance_to(other.sim_pos) < expected - 0.01:
		failures.append(
			"units should separate to at least min_unit_separation (got %s, want %s)"
			% [resolved.distance_to(other.sim_pos), expected]
		)

func _test_unit_slide_when_blocked(failures: Array[String]) -> void:
	var blocker := _make_unit(Vector2(1.0, 0.0), 0.42)
	blocker.team = Enums.Team.AI
	blocker.order = Enums.OrderType.ATTACK
	var mover := _make_unit(Vector2(0.0, 0.0), 0.42)
	mover.team = Enums.Team.PLAYER
	mover.order = Enums.OrderType.ATTACK
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		mover, Vector2(0.0, 0.0), Vector2(1.2, 0.6), [blocker, mover], []
	)
	if resolved.y < 0.12:
		failures.append("blocked unit should slide laterally toward goal, got %s" % resolved)
	if resolved.distance_squared_to(Vector2(1.2, 0.6)) >= Vector2(0.0, 0.0).distance_squared_to(
		Vector2(1.2, 0.6)
	):
		failures.append("slide should move closer to desired position than staying put")
