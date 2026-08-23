extends RefCounted

const NavGridServiceScript := preload("res://scripts/systems/nav_grid_service.gd")

class FakeBlocker extends Object:
	var sim_pos := Vector2.ZERO
	var block_half := Vector2.ONE
	var block_size := Vector2(2, 2)

class BuildingStub extends Object:
	var is_complete := false
	var is_placement_ghost := false
	var def: Object = null


class FakeUnit extends Object:
	var sim_pos := Vector2.ZERO
	var def: UnitDef
	var hp := 40.0

	func take_damage(_amount: float, _source: Node = null) -> void:
		pass


func run() -> Array[String]:
	var failures: Array[String] = []
	var nav := NavGridServiceScript.new()
	nav.setup(-20, 20, 1.0)

	var open_path: PackedVector2Array = nav.find_path(Vector2(-5, 0), Vector2(5, 0))
	if open_path.is_empty():
		failures.append("open map should find a path")
	elif open_path[open_path.size() - 1].distance_to(Vector2(5, 0)) > 0.6:
		failures.append("open path should end near the goal")

	var wall := FakeBlocker.new()
	wall.sim_pos = Vector2(0, 0)
	wall.block_size = Vector2(2, 8)
	wall.block_half = Vector2(1, 4)
	nav.rebuild_from_blockers([wall])

	var trapped := nav.find_path(Vector2(0, 0), Vector2(6, 0))
	if trapped.is_empty():
		failures.append("path from inside a wall should still escape to a goal")
	elif trapped[0].distance_to(Vector2(0, 0)) < 0.05:
		failures.append("path from inside a wall should start at a nearby walkable point")

	if not nav.is_world_solid(Vector2(0, 0)):
		failures.append("wall center cell should be solid")

	var detour: PackedVector2Array = nav.find_path(Vector2(-6, 0), Vector2(6, 0))
	if detour.is_empty():
		failures.append("path should detour around a solid wall")
	else:
		for point in detour:
			if absf(point.x) < 0.6 and absf(point.y) < 3.5:
				failures.append("detour path should not cross the wall interior")
				break
		# Shortest detour should go above or below, not reverse far away.
		var max_abs_y := 0.0
		for point in detour:
			max_abs_y = maxf(max_abs_y, absf(point.y))
		if max_abs_y > 12.0:
			failures.append("detour should stay near the obstacle (shortest path)")

	var inside := nav.find_nearest_walkable(Vector2(0, 0))
	if nav.is_world_solid(inside):
		failures.append("nearest walkable should leave solid cells")

	nav.enqueue_path(1, Vector2(-4, 4), Vector2(4, 4))
	nav.enqueue_path(2, Vector2(-4, -4), Vector2(4, -4))
	var flushed: Dictionary = nav.flush_pending_paths()
	if flushed.size() != 2:
		failures.append("flush_pending_paths should return queued results")
	elif (flushed[1] as PackedVector2Array).is_empty() or (flushed[2] as PackedVector2Array).is_empty():
		failures.append("queued paths should be non-empty on open terrain after rebuild")

	# Rebuild empty for queue check on clear map.
	nav.rebuild_from_blockers([])
	nav.enqueue_path(3, Vector2(-3, 0), Vector2(3, 0))
	var one: Dictionary = nav.flush_pending_paths()
	if not one.has(3) or (one[3] as PackedVector2Array).is_empty():
		failures.append("budgeted queue should resolve paths on clear grid")

	var incomplete := BuildingStub.new()
	incomplete.def = Object.new()
	if not NavGridServiceScript._building_blocks_nav(incomplete):
		failures.append("incomplete building should block nav to match collision")
	var complete := BuildingStub.new()
	complete.is_complete = true
	complete.def = Object.new()
	if not NavGridServiceScript._building_blocks_nav(complete):
		failures.append("complete building should block nav")

	nav.rebuild_from_blockers([])
	var first: PackedVector2Array = nav.find_path(Vector2(-4, 0), Vector2(4, 0), 0.35)
	var second: PackedVector2Array = nav.find_path(Vector2(-4, 0), Vector2(4, 0), 0.35)
	if first.is_empty() or second.is_empty():
		failures.append("cached path lookup should return a route")
	elif first.size() != second.size():
		failures.append("cached path lookup should match the first result")

	var pillar := FakeBlocker.new()
	pillar.sim_pos = Vector2(0.5, 0.5)
	pillar.block_half = Vector2(0.1, 0.1)
	nav.rebuild_from_blockers([pillar])
	nav.find_path(Vector2(-5, 0), Vector2(5, 0), 0.35)
	var small_cells := nav.get_solid_cells().size()
	nav.find_path(Vector2(-5, 0), Vector2(5, 0), 0.70)
	var large_cells := nav.get_solid_cells().size()
	if large_cells <= small_cells:
		failures.append("larger unit radius should inflate the nav grid more")

	nav.rebuild_from_blockers([])
	var blocker_unit := FakeUnit.new()
	blocker_unit.sim_pos = Vector2(0.0, 0.0)
	blocker_unit.def = UnitDef.new()
	blocker_unit.def.footprint_radius = 0.55
	var direct: PackedVector2Array = nav.find_path(Vector2(-5.0, 0.0), Vector2(5.0, 0.0), 0.35)
	if direct.is_empty():
		failures.append("open path should exist before unit temp block")
	var avoid: PackedVector2Array = nav.find_path_avoiding_units(
		Vector2(-5.0, 0.0), Vector2(5.0, 0.0), 0.35, [blocker_unit]
	)
	if avoid.is_empty():
		failures.append("path avoiding unit should still reach goal")
	for point in avoid:
		if point.distance_to(Vector2.ZERO) < 0.35:
			failures.append("path avoiding unit should not cross the blocker center")
			break
	# Grid should be restored after temp marks.
	var after: PackedVector2Array = nav.find_path(Vector2(-5.0, 0.0), Vector2(5.0, 0.0), 0.35)
	if after.is_empty():
		failures.append("grid should be walkable again after temp unit marks revert")

	return failures
