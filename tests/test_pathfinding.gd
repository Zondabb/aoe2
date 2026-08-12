extends RefCounted

const NavGridScript := preload("res://scripts/systems/nav_grid.gd")
const PathfindingServiceScript := preload("res://scripts/systems/pathfinding_service.gd")
const ResourceNodeScript := preload("res://scripts/entities/resource_node.gd")
const SpriteCatalogScript := preload("res://scripts/presentation/sprite_catalog.gd")

class _TestBody extends RefCounted:
	var def: Resource
	var sim_pos: Vector2
	var resource_type: int
	var amount := 100.0

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_open_map_short_path(failures)
	_test_building_blocks_path(failures)
	_test_tree_blocks_berry_passes(failures)
	_test_gold_blocks_path(failures)
	_test_resource_footprint_matches_sprite(failures)
	_test_path_blocker_sheet_footprint(failures)
	_test_blocked_goal_no_straight_line(failures)
	_test_depleted_tree_opens_cell(failures)
	_test_destroyed_building_reopens_path(failures)
	_test_unit_radius_affects_walkability(failures)
	return failures

func _make_grid() -> Node:
	var grid := NavGridScript.new()
	grid.setup(Rect2(-10.0, -10.0, 20.0, 20.0))
	return grid

func _make_building(pos: Vector2, footprint: Vector2 = Vector2(4, 4)) -> Object:
	var body := _TestBody.new()
	var def := BuildingDef.new()
	def.footprint = footprint
	body.def = def
	body.sim_pos = pos
	return body

func _make_resource(
	pos: Vector2,
	resource_type: Enums.ResourceType,
	amount: float = 100.0
) -> Object:
	var body := _TestBody.new()
	body.resource_type = resource_type
	body.amount = amount
	body.sim_pos = pos
	return body

func _path_crosses_point(path: PackedVector2Array, point: Vector2, radius: float) -> bool:
	for waypoint in path:
		if waypoint.distance_to(point) <= radius:
			return true
	for index in path.size() - 1:
		var start: Vector2 = path[index]
		var end: Vector2 = path[index + 1]
		var segment := end - start
		var length := segment.length()
		if length <= 0.001:
			continue
		var steps := maxi(1, int(ceil(length / 0.25)))
		for step in steps + 1:
			var sample := start.lerp(end, float(step) / float(steps))
			if sample.distance_to(point) <= radius:
				return true
	return false

func _test_open_map_short_path(failures: Array[String]) -> void:
	var grid := _make_grid()
	grid.rebuild([], [])
	var path := PathfindingServiceScript.find_path(
		grid, Vector2(-5.0, 0.0), Vector2(5.0, 0.0), 0.35
	)
	if path.is_empty():
		failures.append("open map path should not be empty")
	elif path[-1].distance_to(Vector2(5.0, 0.0)) > 0.01:
		failures.append("open map path should end at target")

func _test_building_blocks_path(failures: Array[String]) -> void:
	var grid := _make_grid()
	var building := _make_building(Vector2.ZERO, Vector2(4, 4))
	grid.rebuild([building], [])
	var path := PathfindingServiceScript.find_path(
		grid, Vector2(-5.0, 0.0), Vector2(5.0, 0.0), 0.35
	)
	if path.is_empty():
		failures.append("building detour path should not be empty")
	if _path_crosses_point(path, Vector2.ZERO, 2.5):
		failures.append("path should not cut through building footprint")

func _test_tree_blocks_berry_passes(failures: Array[String]) -> void:
	var grid := _make_grid()
	var tree := _make_resource(Vector2.ZERO, Enums.ResourceType.WOOD)
	var bush := _make_resource(Vector2(2.0, 0.0), Enums.ResourceType.FOOD)
	grid.rebuild([], [tree, bush])
	var around_tree := PathfindingServiceScript.find_path(
		grid, Vector2(-5.0, 0.0), Vector2(5.0, 0.0), 0.35
	)
	if _path_crosses_point(around_tree, Vector2.ZERO, 1.0):
		failures.append("path should detour around trees")
	var through_bush := PathfindingServiceScript.find_path(
		grid, Vector2(1.0, 0.0), Vector2(3.0, 0.0), 0.35
	)
	if through_bush.is_empty():
		failures.append("path through berry bush should remain available")

func _test_gold_blocks_path(failures: Array[String]) -> void:
	var grid := _make_grid()
	var mine := _make_resource(Vector2.ZERO, Enums.ResourceType.GOLD)
	grid.rebuild([], [mine])
	var path := PathfindingServiceScript.find_path(
		grid, Vector2(-5.0, 0.0), Vector2(5.0, 0.0), 0.35
	)
	if _path_crosses_point(path, Vector2.ZERO, 1.5):
		failures.append("path should detour around gold mines")

func _test_resource_footprint_matches_sprite(failures: Array[String]) -> void:
	var gold := ResourceNodeScript.pathfinding_footprint(Enums.ResourceType.GOLD)
	var meta := SpriteCatalogScript.load_meta(
		SpriteCatalogScript.resource_sheet_base(Enums.ResourceType.GOLD)
	)
	var expected := SpriteCatalogScript.pathfinding_footprint_from_meta(meta)
	if gold.distance_to(expected) > 0.01:
		failures.append("gold mine footprint should match sprite square size")
	if gold.x < 5.0 or gold.x > 7.5:
		failures.append("gold mine footprint should sit between old 2x2 stub and full sprite size")

func _test_path_blocker_sheet_footprint(failures: Array[String]) -> void:
	var footprint := SpriteCatalogScript.pathfinding_footprint_for_sheet(
		"res://assets/sprites/resources/gold_mine",
		SpriteCatalogScript.RESOURCE_PIXEL_SCALE_2D
	)
	if footprint.x < 5.0:
		failures.append("gold sheet footprint should cover most of the mine sprite width")

func _test_blocked_goal_no_straight_line(failures: Array[String]) -> void:
	var grid := _make_grid()
	var mine := _make_resource(Vector2.ZERO, Enums.ResourceType.GOLD)
	grid.rebuild([], [mine])
	var path := PathfindingServiceScript.find_path(
		grid, Vector2(-8.0, 0.0), Vector2.ZERO, 0.35
	)
	if path.is_empty():
		failures.append("path to blocked goal should snap to a nearby walkable point")
	elif _path_crosses_point(path, Vector2.ZERO, 2.0):
		failures.append("blocked goal should not produce a straight line through the mine")

func _test_depleted_tree_opens_cell(failures: Array[String]) -> void:
	var grid := _make_grid()
	var tree := _make_resource(Vector2.ZERO, Enums.ResourceType.WOOD)
	grid.rebuild([], [tree])
	if grid.is_walkable_world(Vector2.ZERO):
		failures.append("standing tree should block its center cell")
	tree.amount = 0.0
	grid.rebuild_resources([tree])
	if not grid.is_walkable_world(Vector2.ZERO):
		failures.append("depleted tree should release nav grid cells")

func _test_destroyed_building_reopens_path(failures: Array[String]) -> void:
	var grid := _make_grid()
	var building := _make_building(Vector2.ZERO, Vector2(4, 4))
	grid.rebuild([building], [])
	if grid.is_walkable_world(Vector2.ZERO, 0.35):
		failures.append("building should block its center for units")
	grid.rebuild_buildings([])
	if not grid.is_walkable_world(Vector2.ZERO, 0.35):
		failures.append("removed building should reopen nav grid cells")

func _test_unit_radius_affects_walkability(failures: Array[String]) -> void:
	var grid := _make_grid()
	var building := _make_building(Vector2.ZERO, Vector2(4, 4))
	grid.rebuild([building], [])
	var path_small := PathfindingServiceScript.find_path(
		grid, Vector2(-5.0, 0.0), Vector2(5.0, 0.0), 0.35
	)
	var path_large := PathfindingServiceScript.find_path(
		grid, Vector2(-5.0, 0.0), Vector2(5.0, 0.0), 1.0
	)
	if path_small.is_empty() or path_large.is_empty():
		failures.append("radius-aware paths should not be empty")
		return
	var small_min := _min_distance_to_point(path_small, Vector2.ZERO)
	var large_min := _min_distance_to_point(path_large, Vector2.ZERO)
	if large_min <= small_min + 0.05:
		failures.append("larger unit radius should keep path further from obstacles")

func _min_distance_to_point(path: PackedVector2Array, point: Vector2) -> float:
	var best := INF
	for waypoint in path:
		best = minf(best, waypoint.distance_to(point))
	for index in path.size() - 1:
		var start: Vector2 = path[index]
		var end: Vector2 = path[index + 1]
		var steps := maxi(1, int(ceil(start.distance_to(end) / 0.25)))
		for step in steps + 1:
			var sample := start.lerp(end, float(step) / float(steps))
			best = minf(best, sample.distance_to(point))
	return best
