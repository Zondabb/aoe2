class_name NavGrid
extends Node

signal navigation_map_changed

const ResourceNodeScript := preload("res://scripts/entities/resource_node.gd")
const PathfindingServiceScript := preload("res://scripts/systems/pathfinding_service.gd")
const CELL_SIZE := 1.0
const MAX_PATH_REQUESTS_PER_FRAME := 10

var _bounds := Rect2(-60.0, -60.0, 120.0, 120.0)
var _width := 0
var _height := 0
var _building_blocked: PackedByteArray = PackedByteArray()
var _resource_blocked: PackedByteArray = PackedByteArray()
var _path_queue: Array[Dictionary] = []

func _ready() -> void:
	add_to_group("nav_grid")
	set_process(true)

func setup(bounds: Rect2) -> void:
	_bounds = bounds
	_width = maxi(1, int(ceil(_bounds.size.x / CELL_SIZE)))
	_height = maxi(1, int(ceil(_bounds.size.y / CELL_SIZE)))
	var size := _width * _height
	_building_blocked = PackedByteArray()
	_resource_blocked = PackedByteArray()
	_building_blocked.resize(size)
	_resource_blocked.resize(size)
	_building_blocked.fill(0)
	_resource_blocked.fill(0)

func rebuild(buildings: Array, resources: Array) -> void:
	if _building_blocked.is_empty():
		return
	_building_blocked.fill(0)
	_resource_blocked.fill(0)
	for value in buildings:
		_mark_building(value, true)
	for value in resources:
		_mark_resource(value, true)
	_emit_map_changed()

func rebuild_buildings(buildings: Array) -> void:
	if _building_blocked.is_empty():
		return
	_building_blocked.fill(0)
	for value in buildings:
		_mark_building(value, true)
	_emit_map_changed()

func rebuild_resources(resources: Array) -> void:
	if _resource_blocked.is_empty():
		return
	_resource_blocked.fill(0)
	for value in resources:
		_mark_resource(value, true)
	_emit_map_changed()

func mark_building(building: Object, blocked: bool) -> void:
	if building == null:
		return
	if blocked:
		_mark_building(building, true)
		_emit_map_changed()
		return
	if is_inside_tree():
		rebuild_buildings(get_tree().get_nodes_in_group("buildings"))
	else:
		_emit_map_changed()

func mark_resource(resource: Object, blocked: bool) -> void:
	if resource == null:
		return
	if not blocked:
		if is_inside_tree():
			rebuild_resources(get_tree().get_nodes_in_group("resource_nodes"))
		return
	_mark_resource(resource, blocked)
	_emit_map_changed()

func queue_path_request(
	requester: Object,
	from_pos: Vector2,
	to_pos: Vector2,
	unit_radius: float
) -> void:
	for index in _path_queue.size():
		var pending: Dictionary = _path_queue[index]
		if pending.get("requester") == requester:
			_path_queue[index] = {
				"requester": requester,
				"from": from_pos,
				"to": to_pos,
				"radius": unit_radius,
			}
			set_process(true)
			return
	_path_queue.append({
		"requester": requester,
		"from": from_pos,
		"to": to_pos,
		"radius": unit_radius,
	})
	set_process(true)

func _process(_delta: float) -> void:
	var processed := 0
	while processed < MAX_PATH_REQUESTS_PER_FRAME and not _path_queue.is_empty():
		var request: Dictionary = _path_queue.pop_front()
		var requester: Object = request.get("requester")
		var path := PathfindingServiceScript.find_path(
			self,
			request.get("from"),
			request.get("to"),
			float(request.get("radius", 0.35))
		)
		if (
			is_instance_valid(requester)
			and requester.has_method("_apply_path_result")
		):
			requester.call("_apply_path_result", path, request.get("to"))
		processed += 1
	if _path_queue.is_empty():
		set_process(false)

func is_walkable_cell(cell: Vector2i, unit_radius: float = 0.0) -> bool:
	if unit_radius <= 0.001:
		var index := _cell_index(cell)
		if index < 0:
			return false
		return _building_blocked[index] == 0 and _resource_blocked[index] == 0
	return not _circle_hits_obstacle(cell_to_world(cell), unit_radius)

func is_walkable_world(pos: Vector2, unit_radius: float = 0.0) -> bool:
	return is_walkable_cell(world_to_cell(pos), unit_radius)

func world_to_cell(pos: Vector2) -> Vector2i:
	var local := pos - _bounds.position
	return Vector2i(
		clampi(int(floor(local.x / CELL_SIZE)), 0, _width - 1),
		clampi(int(floor(local.y / CELL_SIZE)), 0, _height - 1)
	)

func cell_to_world(cell: Vector2i) -> Vector2:
	return _bounds.position + Vector2(float(cell.x) + 0.5, float(cell.y) + 0.5) * CELL_SIZE

func grid_width() -> int:
	return _width

func grid_height() -> int:
	return _height

func cell_index(cell: Vector2i) -> int:
	return _cell_index(cell)

func _cell_index(cell: Vector2i) -> int:
	if cell.x < 0 or cell.y < 0 or cell.x >= _width or cell.y >= _height:
		return -1
	return cell.x + cell.y * _width

func _emit_map_changed() -> void:
	navigation_map_changed.emit()

func _circle_hits_obstacle(center: Vector2, radius: float) -> bool:
	var search_half := Vector2(radius + CELL_SIZE, radius + CELL_SIZE)
	var min_cell := world_to_cell(center - search_half)
	var max_cell := world_to_cell(center + search_half)
	var cell_half := Vector2(CELL_SIZE * 0.5, CELL_SIZE * 0.5)
	for y in range(min_cell.y, max_cell.y + 1):
		for x in range(min_cell.x, max_cell.x + 1):
			var cell := Vector2i(x, y)
			var index := _cell_index(cell)
			if index < 0:
				continue
			if _building_blocked[index] == 0 and _resource_blocked[index] == 0:
				continue
			if _circle_overlaps_aabb(
				center, radius, cell_to_world(cell), cell_half
			):
				return true
	return false

static func _circle_overlaps_aabb(
	circle_center: Vector2,
	radius: float,
	box_center: Vector2,
	box_half: Vector2
) -> bool:
	var closest := Vector2(
		clampf(circle_center.x, box_center.x - box_half.x, box_center.x + box_half.x),
		clampf(circle_center.y, box_center.y - box_half.y, box_center.y + box_half.y)
	)
	return circle_center.distance_squared_to(closest) <= radius * radius

func _mark_building(building: Object, blocked: bool) -> void:
	if not blocked:
		return
	var building_def := building.get("def") as BuildingDef
	if building_def == null:
		return
	if building.get("is_placement_ghost") == true:
		return
	var center: Vector2 = building.get("sim_pos")
	var half := building_def.footprint * 0.5
	_mark_aabb_on_layer(_building_blocked, center, half)

func _mark_resource(resource: Object, blocked: bool) -> void:
	if not blocked:
		return
	if float(resource.get("amount")) <= 0.0:
		return
	var resource_type: int = int(resource.get("resource_type"))
	if not ResourceNodeScript.resource_blocks_pathfinding(resource_type):
		return
	var center: Vector2 = resource.get("sim_pos")
	var footprint := ResourceNodeScript.pathfinding_footprint(resource_type)
	var half := footprint * 0.5
	_mark_aabb_on_layer(_resource_blocked, center, half)

func _mark_aabb_on_layer(layer: PackedByteArray, center: Vector2, half: Vector2) -> void:
	var min_cell := world_to_cell(center - half)
	var max_cell := world_to_cell(center + half)
	for y in range(min_cell.y, max_cell.y + 1):
		for x in range(min_cell.x, max_cell.x + 1):
			var index := _cell_index(Vector2i(x, y))
			if index >= 0:
				layer[index] = 1
