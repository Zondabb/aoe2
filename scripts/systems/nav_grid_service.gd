class_name NavGridService
extends RefCounted

const ResourceNodeScript := preload("res://scripts/entities/resource_node.gd")
const SpriteCatalogScript := preload("res://scripts/presentation/sprite_catalog.gd")
const CollisionResolverScript := preload("res://scripts/systems/collision_resolver.gd")

## Grid A* over logical xz (sim_pos). Buildings, ores, and terrain cells are
## square solid blockers. Units are NOT baked into the grid (soft-sep remains).

const CELL_SIZE := 1.0
const DEFAULT_MAP_MIN := -40
const DEFAULT_MAP_MAX := 40
const MAX_PATH_REQUESTS_PER_FRAME := 12
const WAYPOINT_ARRIVAL := 0.35
const MAX_WALKABLE_SEARCH := 24
const MAX_PATH_CACHE := 512
const MAX_RADIUS_GRID_CACHE := 8
const DEFAULT_UNIT_RADIUS := 0.35
const MIN_UNIT_RADIUS := 0.2
const RADIUS_QUANTIZE_STEP := 0.05

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
var _path_cache: Dictionary = {}
var _path_cache_order: Array[String] = []
var _solid_cells_cache: Array[Vector2i] = []
var _solid_cells_dirty := true
var _blocker_marks: Array[Dictionary] = []
var _solid_by_radius: Dictionary = {}
var _solid_radius_order: Array[String] = []
var _active_radius_key := ""
var _query_radius := DEFAULT_UNIT_RADIUS


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
	_blocker_marks.clear()
	_solid_by_radius.clear()
	_solid_radius_order.clear()
	_active_radius_key = ""
	_solid_cells_dirty = true
	_clear_path_cache()
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
		_blocker_marks.append({"center": center, "half": half})
	_ensure_active_radius(DEFAULT_UNIT_RADIUS)


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
	if _solid[idx] != (1 if solid else 0):
		_solid_cells_dirty = true
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


func find_path(
	from: Vector2, to: Vector2, unit_radius: float = DEFAULT_UNIT_RADIUS
) -> PackedVector2Array:
	if _grid == null:
		return PackedVector2Array([to])
	var radius := _quantize_radius(unit_radius)
	_query_radius = radius
	_ensure_active_radius(radius)
	var safe_from := nearest_walkable_world(from, radius)
	var safe_to := nearest_walkable_world(to, radius)
	var start := world_to_cell(safe_from)
	var goal := world_to_cell(safe_to)
	if start == Vector2i(-99999, -99999) or goal == Vector2i(-99999, -99999):
		return PackedVector2Array()
	var cache_key := _path_cache_key(start, goal, radius)
	if _path_cache.has(cache_key):
		return _adapt_cached_path(
			_path_cache[cache_key] as PackedVector2Array, safe_from, to, safe_to, radius
		)
	var id_path: Array = _grid.get_id_path(start, goal)
	if id_path.is_empty():
		return PackedVector2Array()
	var points := PackedVector2Array()
	for cell_variant in id_path:
		var cell: Vector2i = cell_variant
		points.append(cell_to_world_center(cell))
	if points.is_empty():
		return points
	var simplified := _simplify_path(points)
	_store_cached_path(cache_key, simplified)
	return _adapt_cached_path(simplified, safe_from, to, safe_to, radius)


## One-shot path with other units temporarily marked solid (local grid sync, then revert).
func find_path_avoiding_units(
	from: Vector2,
	to: Vector2,
	unit_radius: float,
	units: Array
) -> PackedVector2Array:
	if units.is_empty():
		return find_path(from, to, unit_radius)
	var radius := _quantize_radius(unit_radius)
	_query_radius = radius
	_ensure_active_radius(radius)
	var changed: Array[Dictionary] = []
	for value in units:
		var unit := value as Object
		if unit == null or not is_instance_valid(unit):
			continue
		var center_variant: Variant = unit.get("sim_pos")
		if not (center_variant is Vector2):
			continue
		var half := _unit_footprint_half(unit)
		_mark_aabb_temp_solid(center_variant as Vector2, Vector2(half, half), changed)
	if changed.is_empty():
		return find_path(from, to, unit_radius)
	_sync_changed_cells_to_grid(changed)
	var path := _find_path_uncached(from, to, radius)
	_revert_temp_solid_marks(changed)
	_sync_changed_cells_to_grid(changed)
	return path


func is_world_walkable_with_radius(
	world: Vector2, radius: float = DEFAULT_UNIT_RADIUS
) -> bool:
	var quantized := _quantize_radius(radius)
	_ensure_active_radius(quantized)
	_query_radius = quantized
	if _index_of(world_to_cell(world)) < 0:
		return false
	return not _circle_hits_solid(world, quantized)


func nearest_walkable_world(
	world: Vector2, radius: float = DEFAULT_UNIT_RADIUS
) -> Vector2:
	var quantized := _quantize_radius(radius)
	_ensure_active_radius(quantized)
	_query_radius = quantized
	if is_world_walkable_with_radius(world, quantized):
		return world
	var origin := world_to_cell(world)
	var best := world
	var best_dist := INF
	var max_r := mini(maxi(_width, _height), MAX_WALKABLE_SEARCH)
	for search_r in range(1, max_r):
		var found := false
		for dy in range(-search_r, search_r + 1):
			for dx in range(-search_r, search_r + 1):
				if maxi(absi(dx), absi(dy)) != search_r:
					continue
				var candidate_cell := origin + Vector2i(dx, dy)
				if _index_of(candidate_cell) < 0 or is_cell_solid(candidate_cell):
					continue
				var candidate := cell_to_world_center(candidate_cell)
				if not is_world_walkable_with_radius(candidate, quantized):
					continue
				var dist := world.distance_squared_to(candidate)
				if dist < best_dist:
					best_dist = dist
					best = candidate
					found = true
		if found:
			return best
	return best


func find_nearest_walkable(world: Vector2, unit_radius: float = DEFAULT_UNIT_RADIUS) -> Vector2:
	return nearest_walkable_world(world, unit_radius)


## Queue a path request; call flush_pending_paths each frame (budgeted).
func enqueue_path(
	unit_id: int,
	from: Vector2,
	to: Vector2,
	unit_radius: float = DEFAULT_UNIT_RADIUS
) -> void:
	var req := {
		"id": unit_id,
		"from": from,
		"to": to,
		"radius": unit_radius,
	}
	for index in _pending_requests.size():
		var pending: Dictionary = _pending_requests[index]
		if int(pending.get("id", -1)) == unit_id:
			_pending_requests[index] = req
			return
	_pending_requests.append(req)


func flush_pending_paths() -> Dictionary:
	var results := {}
	var count := 0
	while not _pending_requests.is_empty() and count < _frame_budget:
		var req: Dictionary = _pending_requests.pop_front()
		var radius := float(req.get("radius", DEFAULT_UNIT_RADIUS))
		results[int(req["id"])] = find_path(req["from"], req["to"], radius)
		count += 1
	return results


func pending_count() -> int:
	return _pending_requests.size()


func set_frame_budget(budget: int) -> void:
	_frame_budget = maxi(1, budget)


func get_solid_cells() -> Array[Vector2i]:
	if _solid_cells_dirty:
		_rebuild_solid_cells_cache()
	return _solid_cells_cache


func get_map_rect() -> Rect2:
	return Rect2(
		Vector2(float(map_min), float(map_min)) * cell_size,
		Vector2(float(_width), float(_height)) * cell_size
	)


static func collect_blockers_from_tree(tree: SceneTree) -> Array:
	var blockers: Array = []
	if tree == null:
		return blockers
	blockers.append_array(tree.get_nodes_in_group("path_blockers"))
	for node in tree.get_nodes_in_group("buildings"):
		if _building_blocks_nav(node):
			blockers.append(node)
	for node in tree.get_nodes_in_group("resource_nodes"):
		if _resource_blocks_nav(node):
			blockers.append(node)
	return blockers


static func _building_blocks_nav(building: Object) -> bool:
	if building == null or not is_instance_valid(building):
		return false
	if building.get("is_placement_ghost") == true:
		return false
	# 地基与完工建筑均挡路，与 CollisionResolver 一致
	return building.get("def") != null


static func _resource_blocks_nav(resource: Object) -> bool:
	if resource == null or not is_instance_valid(resource):
		return false
	if float(resource.get("amount")) <= 0.0:
		return false
	var resource_type: int = int(resource.get("resource_type"))
	return ResourceNodeScript.resource_blocks_pathfinding(resource_type)


func _quantize_radius(radius: float) -> float:
	return maxf(MIN_UNIT_RADIUS, snappedf(radius, RADIUS_QUANTIZE_STEP))


func _radius_key(radius: float) -> String:
	return "%.2f" % _quantize_radius(radius)


func _path_cache_key(start: Vector2i, goal: Vector2i, radius: float) -> String:
	return "%d,%d|%d,%d|r%s" % [start.x, start.y, goal.x, goal.y, _radius_key(radius)]


func _ensure_active_radius(radius: float) -> void:
	var key := _radius_key(radius)
	if key == _active_radius_key and not _solid.is_empty():
		return
	_active_radius_key = key
	_solid = _get_or_build_solid_for_radius(_quantize_radius(radius))
	_sync_grid_from_solid()
	_solid_cells_dirty = true


func _get_or_build_solid_for_radius(radius: float) -> PackedByteArray:
	var key := _radius_key(radius)
	if _solid_by_radius.has(key):
		return _solid_by_radius[key] as PackedByteArray
	var inflated := PackedByteArray()
	inflated.resize(_width * _height)
	inflated.fill(0)
	var pad := Vector2(radius, radius)
	for mark: Dictionary in _blocker_marks:
		_mark_aabb_on_layer(
			inflated, mark["center"] as Vector2, (mark["half"] as Vector2) + pad
		)
	_solid_by_radius[key] = inflated
	_solid_radius_order.append(key)
	while _solid_radius_order.size() > MAX_RADIUS_GRID_CACHE:
		var oldest: String = _solid_radius_order.pop_front()
		_solid_by_radius.erase(oldest)
	return inflated


func _mark_aabb_on_layer(layer: PackedByteArray, center: Vector2, half: Vector2) -> void:
	var min_cell := world_to_cell(center - half)
	var max_cell := world_to_cell(center + half - Vector2(0.001, 0.001))
	for cy in range(min_cell.y, max_cell.y + 1):
		for cx in range(min_cell.x, max_cell.x + 1):
			var idx := _index_of(Vector2i(cx, cy))
			if idx >= 0:
				layer[idx] = 1


func _rebuild_solid_cells_cache() -> void:
	_solid_cells_cache = []
	for y in _height:
		for x in _width:
			if _solid[y * _width + x] != 0:
				_solid_cells_cache.append(Vector2i(_origin_cell.x + x, _origin_cell.y + y))
	_solid_cells_dirty = false


func _clear_path_cache() -> void:
	_path_cache.clear()
	_path_cache_order.clear()


func _store_cached_path(key: String, path: PackedVector2Array) -> void:
	if _path_cache.has(key):
		return
	_path_cache[key] = path
	_path_cache_order.append(key)
	while _path_cache_order.size() > MAX_PATH_CACHE:
		var oldest: String = _path_cache_order.pop_front()
		_path_cache.erase(oldest)


func _adapt_cached_path(
	cached: PackedVector2Array,
	safe_from: Vector2,
	to: Vector2,
	safe_to: Vector2,
	radius: float
) -> PackedVector2Array:
	if cached.is_empty():
		return cached
	var points := cached.duplicate()
	if safe_from.distance_to(points[0]) > WAYPOINT_ARRIVAL:
		points.insert(0, safe_from)
	if is_world_walkable_with_radius(to, radius):
		points[points.size() - 1] = to
	elif points[points.size() - 1].distance_to(safe_to) > WAYPOINT_ARRIVAL:
		points[points.size() - 1] = safe_to
	return points


func _sync_grid_from_solid() -> void:
	for y in _height:
		for x in _width:
			var cell := Vector2i(_origin_cell.x + x, _origin_cell.y + y)
			_grid.set_point_solid(cell, _solid[y * _width + x] != 0)


func _find_path_uncached(
	from: Vector2, to: Vector2, radius: float
) -> PackedVector2Array:
	var safe_from := nearest_walkable_world(from, radius)
	var safe_to := nearest_walkable_world(to, radius)
	var start := world_to_cell(safe_from)
	var goal := world_to_cell(safe_to)
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
	var simplified := _simplify_path(points)
	return _adapt_cached_path(simplified, safe_from, to, safe_to, radius)


func _unit_footprint_half(unit: Object) -> float:
	return CollisionResolverScript.unit_radius(unit)


func _mark_aabb_temp_solid(
	center: Vector2, half: Vector2, changed: Array[Dictionary]
) -> void:
	var min_cell := world_to_cell(center - half)
	var max_cell := world_to_cell(center + half - Vector2(0.001, 0.001))
	for cy in range(min_cell.y, max_cell.y + 1):
		for cx in range(min_cell.x, max_cell.x + 1):
			var cell := Vector2i(cx, cy)
			var idx := _index_of(cell)
			if idx < 0 or _solid[idx] != 0:
				continue
			_solid[idx] = 1
			changed.append({"cell": cell, "idx": idx})
	if not changed.is_empty():
		_solid_cells_dirty = true


func _revert_temp_solid_marks(changed: Array[Dictionary]) -> void:
	for entry in changed:
		var idx: int = int(entry["idx"])
		_solid[idx] = 0
	_solid_cells_dirty = true


func _sync_changed_cells_to_grid(changed: Array[Dictionary]) -> void:
	for entry in changed:
		var cell: Vector2i = entry["cell"]
		var idx: int = int(entry["idx"])
		_grid.set_point_solid(cell, _solid[idx] != 0)


func _index_of(cell: Vector2i) -> int:
	var lx := cell.x - _origin_cell.x
	var ly := cell.y - _origin_cell.y
	if lx < 0 or ly < 0 or lx >= _width or ly >= _height:
		return -1
	return ly * _width + lx


func _blocker_half(blocker: Object) -> Vector2:
	if blocker.get("block_half") is Vector2:
		var half := blocker.get("block_half") as Vector2
		if half.x > 0.0 and half.y > 0.0:
			return half
	var building_def := blocker.get("def") as BuildingDef
	if building_def != null:
		var civ := blocker.get("civ") as CivDef
		var civ_id: StringName = civ.id if civ != null else &""
		return SpriteCatalogScript.pathfinding_footprint_for_building(
			building_def, civ_id
		) * 0.5
	var block_size: Variant = blocker.get("block_size")
	if block_size is Vector2:
		return (block_size as Vector2) * 0.5
	if blocker.get("resource_type") != null and float(blocker.get("amount")) > 0.0:
		var resource_type: int = int(blocker.get("resource_type"))
		var footprint := ResourceNodeScript.pathfinding_footprint(resource_type)
		if footprint.length_squared() > 0.0:
			return footprint * 0.5
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
		return not _circle_hits_solid(a, _query_radius)
	var steps := maxi(2, int(ceil(dist / (cell_size * 0.35))))
	for s in range(0, steps + 1):
		var t := float(s) / float(steps)
		var p := a.lerp(b, t)
		if _circle_hits_solid(p, _query_radius):
			return false
	return true


func _circle_hits_solid(center: Vector2, radius: float) -> bool:
	var search_half := Vector2(radius + cell_size, radius + cell_size)
	var min_cell := world_to_cell(center - search_half)
	var max_cell := world_to_cell(center + search_half)
	var cell_half := Vector2(cell_size * 0.5, cell_size * 0.5)
	for cy in range(min_cell.y, max_cell.y + 1):
		for cx in range(min_cell.x, max_cell.x + 1):
			var cell := Vector2i(cx, cy)
			if not is_cell_solid(cell):
				continue
			var box_center := cell_to_world_center(cell)
			if _circle_overlaps_aabb(center, radius, box_center, cell_half):
				return true
	return false


static func _circle_overlaps_aabb(
	circle_center: Vector2, radius: float, box_center: Vector2, box_half: Vector2
) -> bool:
	var closest := Vector2(
		clampf(circle_center.x, box_center.x - box_half.x, box_center.x + box_half.x),
		clampf(circle_center.y, box_center.y - box_half.y, box_center.y + box_half.y)
	)
	return circle_center.distance_squared_to(closest) <= radius * radius
