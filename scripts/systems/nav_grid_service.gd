class_name NavGridService
extends RefCounted

## Grid A* over logical xz (sim_pos). Buildings, ores, and terrain cells are
## square solid blockers. Units are NOT baked into the grid (soft-sep remains).

const CELL_SIZE := 1.0
const DEFAULT_MAP_MIN := -40
const DEFAULT_MAP_MAX := 40
const MAX_PATH_REQUESTS_PER_FRAME := 12
const WAYPOINT_ARRIVAL := 0.35

var cell_size := CELL_SIZE
var map_min := DEFAULT_MAP_MIN
var map_max := DEFAULT_MAP_MAX
var _grid: AStarGrid2D
var _solid := PackedByteArray()
var _width := 0
var _height := 0
var _origin_cell := Vector2i.ZERO
var _pending_requests: Array = []
var _frame_budget := MAX_PATH_REQUESTS_PER_FRAME


func setup(
	p_map_min: int = DEFAULT_MAP_MIN,
	p_map_max: int = DEFAULT_MAP_MAX,
	p_cell_size: float = CELL_SIZE
) -> void:
	map_min = p_map_min
	map_max = p_map_max
	cell_size = maxf(0.25, p_cell_size)
	_origin_cell = Vector2i(map_min, map_min)
	_width = map_max - map_min
	_height = map_max - map_min
	_solid = PackedByteArray()
	_solid.resize(_width * _height)
	_solid.fill(0)
	_grid = AStarGrid2D.new()
	_grid.region = Rect2i(_origin_cell, Vector2i(_width, _height))
	_grid.cell_size = Vector2(cell_size, cell_size)
	_grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_grid.update()


func clear_solids() -> void:
	if _solid.is_empty():
		return
	_solid.fill(0)
	for y in _height:
		for x in _width:
			_grid.set_point_solid(Vector2i(_origin_cell.x + x, _origin_cell.y + y), false)


func rebuild_from_blockers(blockers: Array) -> void:
	clear_solids()
	for value in blockers:
		var blocker := value as Object
		if blocker == null or not is_instance_valid(blocker):
			continue
		var center: Vector2 = blocker.get("sim_pos")
		var half := _blocker_half(blocker)
		if half.x <= 0.0 or half.y <= 0.0:
			continue
		mark_aabb_solid(center, half, true)
	_sync_grid_from_solid()


func mark_aabb_solid(center: Vector2, half: Vector2, solid: bool = true) -> void:
	var min_cell := world_to_cell(center - half)
	var max_cell := world_to_cell(center + half - Vector2(0.001, 0.001))
	for cy in range(min_cell.y, max_cell.y + 1):
		for cx in range(min_cell.x, max_cell.x + 1):
			set_cell_solid(Vector2i(cx, cy), solid)


func mark_cell_rect_solid(cell_rect: Rect2i, solid: bool = true) -> void:
	for cy in range(cell_rect.position.y, cell_rect.position.y + cell_rect.size.y):
		for cx in range(cell_rect.position.x, cell_rect.position.x + cell_rect.size.x):
			set_cell_solid(Vector2i(cx, cy), solid)


func set_cell_solid(cell: Vector2i, solid: bool) -> void:
	var idx := _index_of(cell)
	if idx < 0:
		return
	_solid[idx] = 1 if solid else 0


func is_cell_solid(cell: Vector2i) -> bool:
	var idx := _index_of(cell)
	if idx < 0:
		return true
	return _solid[idx] != 0


func is_world_solid(world: Vector2) -> bool:
	return is_cell_solid(world_to_cell(world))


func world_to_cell(world: Vector2) -> Vector2i:
	return Vector2i(floori(world.x / cell_size), floori(world.y / cell_size))


func cell_to_world_center(cell: Vector2i) -> Vector2:
	return (Vector2(cell) + Vector2(0.5, 0.5)) * cell_size


func find_path(from: Vector2, to: Vector2) -> PackedVector2Array:
	if _grid == null:
		return PackedVector2Array([to])
	var start := _nearest_walkable_cell(world_to_cell(from))
	var goal := _nearest_walkable_cell(world_to_cell(to))
	if start == Vector2i(-99999, -99999) or goal == Vector2i(-99999, -99999):
		return PackedVector2Array()
	var id_path: Array = _grid.get_id_path(start, goal)
	if id_path.is_empty():
		return PackedVector2Array()
	var points := PackedVector2Array()
	for cell_variant in id_path:
		var cell: Vector2i = cell_variant
		points.append(cell_to_world_center(cell))
	if points.is_empty():
		return points
	# Keep final click as last waypoint when it is walkable / near goal cell.
	if not is_world_solid(to):
		points[points.size() - 1] = to
	elif points[points.size() - 1].distance_to(to) > WAYPOINT_ARRIVAL:
		points.append(cell_to_world_center(goal))
	return _simplify_path(points)


func find_nearest_walkable(world: Vector2) -> Vector2:
	var cell := _nearest_walkable_cell(world_to_cell(world))
	if cell == Vector2i(-99999, -99999):
		return world
	return cell_to_world_center(cell)


## Queue a path request; call flush_pending_paths each frame (budgeted).
func enqueue_path(unit_id: int, from: Vector2, to: Vector2) -> void:
	_pending_requests.append({"id": unit_id, "from": from, "to": to})


func flush_pending_paths() -> Dictionary:
	var results := {}
	var count := 0
	while not _pending_requests.is_empty() and count < _frame_budget:
		var req: Dictionary = _pending_requests.pop_front()
		results[int(req["id"])] = find_path(req["from"], req["to"])
		count += 1
	return results


func pending_count() -> int:
	return _pending_requests.size()


func set_frame_budget(budget: int) -> void:
	_frame_budget = maxi(1, budget)


func get_solid_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for y in _height:
		for x in _width:
			if _solid[y * _width + x] != 0:
				cells.append(Vector2i(_origin_cell.x + x, _origin_cell.y + y))
	return cells


func get_map_rect() -> Rect2:
	return Rect2(
		Vector2(float(map_min), float(map_min)) * cell_size,
		Vector2(float(_width), float(_height)) * cell_size
	)


func _sync_grid_from_solid() -> void:
	for y in _height:
		for x in _width:
			var cell := Vector2i(_origin_cell.x + x, _origin_cell.y + y)
			_grid.set_point_solid(cell, _solid[y * _width + x] != 0)


func _index_of(cell: Vector2i) -> int:
	var lx := cell.x - _origin_cell.x
	var ly := cell.y - _origin_cell.y
	if lx < 0 or ly < 0 or lx >= _width or ly >= _height:
		return -1
	return ly * _width + lx


func _nearest_walkable_cell(cell: Vector2i) -> Vector2i:
	if not is_cell_solid(cell) and _index_of(cell) >= 0:
		return cell
	var best := Vector2i(-99999, -99999)
	var best_dist := INF
	var max_r := maxi(_width, _height)
	for radius in range(1, max_r):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dy)) != radius:
					continue
				var candidate := cell + Vector2i(dx, dy)
				if is_cell_solid(candidate) or _index_of(candidate) < 0:
					continue
				var dist := Vector2(dx, dy).length_squared()
				if dist < best_dist:
					best_dist = dist
					best = candidate
		if best != Vector2i(-99999, -99999):
			return best
	return best


func _blocker_half(blocker: Object) -> Vector2:
	if blocker.has_method("get") and blocker.get("block_half") != null:
		var half_variant: Variant = blocker.get("block_half")
		if half_variant is Vector2:
			return half_variant as Vector2
	var building_def := blocker.get("def") as BuildingDef
	if building_def != null:
		return building_def.footprint * 0.5
	var block_size: Variant = blocker.get("block_size")
	if block_size is Vector2:
		return (block_size as Vector2) * 0.5
	# Resources / terrain markers: square footprint default 2x2.
	return Vector2(1.0, 1.0)


func _simplify_path(points: PackedVector2Array) -> PackedVector2Array:
	if points.size() <= 2:
		return points
	var simplified := PackedVector2Array()
	simplified.append(points[0])
	var i := 0
	while i < points.size() - 1:
		var furthest := i + 1
		for j in range(i + 2, points.size()):
			if _line_clear(points[i], points[j]):
				furthest = j
			else:
				break
		simplified.append(points[furthest])
		i = furthest
	return simplified


func _line_clear(a: Vector2, b: Vector2) -> bool:
	var dist := a.distance_to(b)
	if dist < 0.001:
		return true
	var steps := maxi(2, int(ceil(dist / (cell_size * 0.5))))
	for s in range(1, steps):
		var t := float(s) / float(steps)
		var p := a.lerp(b, t)
		if is_world_solid(p):
			return false
	return true
