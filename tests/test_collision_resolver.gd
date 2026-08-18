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
	_test_building_blocks_movement(failures)
	_test_map_bounds_clamp(failures)
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
	var from_pos := Vector2(-1.0, 0.0)
	var desired := Vector2(-0.5, 0.0)
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		unit, from_pos, desired, [building]
	)
	if absf(resolved.x) < half.x and absf(resolved.y) < half.y:
		failures.append(
			"push-out must leave expanded AABB when starting inside, got %s" % resolved
		)
	if absf(resolved.x) < half.x - 0.001:
		failures.append(
			"push-out should exit on nearest X face at ±%.2f, got %s" % [half.x, resolved]
		)

func _test_building_blocks_movement(failures: Array[String]) -> void:
	var unit := _make_unit(Vector2(-2.0, 0.0), 0.35)
	var building := _make_building(Vector2(0, 0), Vector2(2, 2))
	var from_pos := Vector2(-2.0, 0.0)
	var desired := Vector2(-1.0, 0.8)
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		unit, from_pos, desired, [building]
	)
	if resolved.distance_to(from_pos) > 0.001:
		failures.append("movement into building should stop at from_pos, got %s" % resolved)

func _test_map_bounds_clamp(failures: Array[String]) -> void:
	CollisionResolverScript.set_map_bounds(Vector2(-10.0, -10.0), Vector2(10.0, 10.0))
	var unit := _make_unit(Vector2(9.8, 0.0), 0.35)
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		unit, unit.sim_pos, Vector2(12.0, 0.0), []
	)
	if resolved.x > 10.0 - 0.35 + 0.001:
		failures.append("units should not move past map max bound, got %s" % resolved)
	CollisionResolverScript.clear_map_bounds()
