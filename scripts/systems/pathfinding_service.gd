class_name PathfindingService
extends RefCounted

const SQRT2 := 1.4142135623730951
const NEIGHBORS := [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]
const NEIGHBOR_COSTS := [1.0, 1.0, 1.0, 1.0, SQRT2, SQRT2, SQRT2, SQRT2]
const GOAL_SEARCH_RADIUS := 8
const MAX_ASTAR_EXPANSIONS := 2048
const LOS_SAMPLE_STEP := 0.5

static func find_path(
	grid: NavGrid,
	from: Vector2,
	to: Vector2,
	unit_radius: float = 0.35
) -> PackedVector2Array:
	if grid == null:
		return PackedVector2Array([to])
	var start_cell := grid.world_to_cell(from)
	var goal_cell := grid.world_to_cell(to)
	if not grid.is_walkable_cell(start_cell, unit_radius):
		start_cell = _nearest_walkable(grid, start_cell, GOAL_SEARCH_RADIUS, unit_radius)
	if not grid.is_walkable_cell(goal_cell, unit_radius):
		goal_cell = _nearest_walkable(grid, goal_cell, GOAL_SEARCH_RADIUS, unit_radius)
	var goal_world := to
	if not grid.is_walkable_world(to, unit_radius):
		goal_world = grid.cell_to_world(goal_cell)
	if start_cell == goal_cell:
		return PackedVector2Array([goal_world])
	var cell_path := _astar(grid, start_cell, goal_cell, unit_radius)
	if cell_path.is_empty():
		var fallback := _nearest_walkable_world(grid, to, GOAL_SEARCH_RADIUS, unit_radius)
		if grid.is_walkable_world(fallback, unit_radius):
			return PackedVector2Array([fallback])
		return PackedVector2Array()
	var world_path: Array[Vector2] = []
	for cell: Vector2i in cell_path:
		world_path.append(grid.cell_to_world(cell))
	world_path.append(goal_world)
	return _string_pull(grid, world_path, unit_radius)

static func _astar(
	grid: NavGrid,
	start: Vector2i,
	goal: Vector2i,
	unit_radius: float
) -> Array[Vector2i]:
	var start_index := grid.cell_index(start)
	var goal_index := grid.cell_index(goal)
	if start_index < 0 or goal_index < 0:
		return []
	var open_set: Array[int] = [start_index]
	var came_from: Dictionary = {}
	var g_score: Dictionary = {start_index: 0.0}
	var f_score: Dictionary = {start_index: _heuristic(start, goal)}
	var expansions := 0
	while not open_set.is_empty() and expansions < MAX_ASTAR_EXPANSIONS:
		expansions += 1
		var current_index := _pop_lowest_f(open_set, f_score)
		if current_index == goal_index:
			return _reconstruct_path(came_from, current_index, grid)
		open_set.erase(current_index)
		var current_cell := _index_to_cell(current_index, grid.grid_width())
		for i in NEIGHBORS.size():
			var neighbor: Vector2i = current_cell + NEIGHBORS[i]
			if not grid.is_walkable_cell(neighbor, unit_radius):
				continue
			var neighbor_index := grid.cell_index(neighbor)
			if neighbor_index < 0:
				continue
			var tentative_g: float = float(g_score.get(current_index, INF)) + NEIGHBOR_COSTS[i]
			if tentative_g >= float(g_score.get(neighbor_index, INF)):
				continue
			came_from[neighbor_index] = current_index
			g_score[neighbor_index] = tentative_g
			f_score[neighbor_index] = tentative_g + _heuristic(neighbor, goal)
			if not open_set.has(neighbor_index):
				open_set.append(neighbor_index)
	return []

static func _pop_lowest_f(open_set: Array[int], f_score: Dictionary) -> int:
	var best_index := open_set[0]
	var best_score: float = float(f_score.get(best_index, INF))
	for index in open_set:
		var score: float = float(f_score.get(index, INF))
		if score < best_score:
			best_score = score
			best_index = index
	return best_index

static func _heuristic(a: Vector2i, b: Vector2i) -> float:
	var dx := float(a.x - b.x)
	var dy := float(a.y - b.y)
	return sqrt(dx * dx + dy * dy)

static func _index_to_cell(index: int, width: int) -> Vector2i:
	return Vector2i(index % width, int(index / width))

static func _reconstruct_path(
	came_from: Dictionary,
	current_index: int,
	grid: NavGrid
) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	var index := current_index
	while came_from.has(index):
		path.push_front(_index_to_cell(index, grid.grid_width()))
		index = int(came_from[index])
	path.push_front(_index_to_cell(index, grid.grid_width()))
	if path.size() <= 1:
		return []
	return path.slice(1)

static func _nearest_walkable(
	grid: NavGrid,
	origin: Vector2i,
	radius: int,
	unit_radius: float
) -> Vector2i:
	if grid.is_walkable_cell(origin, unit_radius):
		return origin
	var best := origin
	var best_dist := INF
	for search_radius in range(1, radius + 1):
		for dy in range(-search_radius, search_radius + 1):
			for dx in range(-search_radius, search_radius + 1):
				var cell := origin + Vector2i(dx, dy)
				if not grid.is_walkable_cell(cell, unit_radius):
					continue
				var dist := Vector2(dx, dy).length_squared()
				if dist < best_dist:
					best_dist = dist
					best = cell
		if best_dist < INF:
			return best
	return best

static func _nearest_walkable_world(
	grid: NavGrid,
	origin: Vector2,
	radius: int,
	unit_radius: float
) -> Vector2:
	var origin_cell := grid.world_to_cell(origin)
	var best_cell := _nearest_walkable(grid, origin_cell, radius, unit_radius)
	return grid.cell_to_world(best_cell)

static func _string_pull(
	grid: NavGrid,
	points: Array[Vector2],
	unit_radius: float
) -> PackedVector2Array:
	if points.is_empty():
		return PackedVector2Array()
	var simplified: Array[Vector2] = [points[-1]]
	for i in range(points.size() - 2, -1, -1):
		if not _line_clear(grid, points[i], simplified[0], unit_radius):
			simplified.insert(0, points[i + 1])
	return PackedVector2Array(simplified)

static func _line_clear(
	grid: NavGrid,
	from: Vector2,
	to: Vector2,
	unit_radius: float
) -> bool:
	var delta := to - from
	var distance := delta.length()
	if distance <= 0.001:
		return grid.is_walkable_world(from, unit_radius)
	var steps := maxi(1, int(ceil(distance / LOS_SAMPLE_STEP)))
	for step in steps + 1:
		var t := float(step) / float(steps)
		var sample := from.lerp(to, t)
		if not grid.is_walkable_world(sample, unit_radius):
			return false
	return true
