extends RefCounted

const NavGridServiceScript := preload("res://scripts/systems/nav_grid_service.gd")

class FakeBlocker extends Object:
	var sim_pos := Vector2.ZERO
	var block_half := Vector2.ONE
	var block_size := Vector2(2, 2)

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

	return failures
