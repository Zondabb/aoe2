extends RefCounted

const CollisionResolverScript := preload("res://scripts/systems/collision_resolver.gd")
const HOUSE: BuildingDef = preload("res://data/buildings/house.tres")

class _TestBody extends RefCounted:
	var def: Resource
	var sim_pos: Vector2

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_building_push_out(failures)
	_test_unit_soft_separate(failures)
	_test_wall_slide_keeps_tangent(failures)
	return failures

func _make_unit(pos: Vector2, radius: float = 0.35) -> Object:
	var u := _TestBody.new()
	var def := UnitDef.new()
	def.collision_radius = radius
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
	var unit := _make_unit(Vector2(0, 0))
	var building := _make_building(Vector2(0, 0), Vector2(2, 2))
	# Desired center overlaps house AABB expanded by radius.
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		unit, Vector2(-2, 0), Vector2(0, 0), [], [building]
	)
	var half := Vector2(1, 1) + Vector2(0.35, 0.35)
	if absf(resolved.x) < half.x and absf(resolved.y) < half.y:
		failures.append("unit should be pushed outside building expanded AABB, got %s" % resolved)

func _test_unit_soft_separate(failures: Array[String]) -> void:
	var self_unit := _make_unit(Vector2(0, 0), 0.35)
	var other := _make_unit(Vector2(0.2, 0.0), 0.35)
	var before: float = self_unit.get("sim_pos").distance_to(other.get("sim_pos"))
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		self_unit, Vector2(0, 0), Vector2(0, 0), [self_unit, other], []
	)
	var after := resolved.distance_to(other.get("sim_pos"))
	if after <= before + 0.001:
		failures.append("soft separate should increase distance, before=%s after=%s" % [before, after])
	if after >= 0.35 + 0.35:
		failures.append("soft separate should not fully hard-block (got full separation %s)" % after)

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
