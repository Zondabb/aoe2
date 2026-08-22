class_name SpatialHash
extends RefCounted

## Uniform grid buckets over logical xz (sim_pos). Not used for pathfinding.

const DEFAULT_CELL_SIZE := 2.0

var cell_size := DEFAULT_CELL_SIZE
var _buckets: Dictionary = {}
var _entity_cell: Dictionary = {}


func setup(p_cell_size: float = DEFAULT_CELL_SIZE) -> void:
	cell_size = maxf(0.25, p_cell_size)
	clear()


func clear() -> void:
	_buckets.clear()
	_entity_cell.clear()


func world_to_cell(world: Vector2) -> Vector2i:
	return Vector2i(floori(world.x / cell_size), floori(world.y / cell_size))


func insert(entity: Object, pos: Vector2) -> void:
	if entity == null or not is_instance_valid(entity):
		return
	var id := entity.get_instance_id()
	if _entity_cell.has(id):
		move(entity, pos)
		return
	var cell := world_to_cell(pos)
	_entity_cell[id] = cell
	_bucket_add(cell, entity)


func remove(entity: Object) -> void:
	if entity == null:
		return
	var id := entity.get_instance_id()
	if not _entity_cell.has(id):
		return
	var cell: Vector2i = _entity_cell[id]
	_entity_cell.erase(id)
	_bucket_remove(cell, entity)


func move(entity: Object, pos: Vector2) -> void:
	if entity == null or not is_instance_valid(entity):
		return
	var id := entity.get_instance_id()
	var new_cell := world_to_cell(pos)
	if not _entity_cell.has(id):
		_entity_cell[id] = new_cell
		_bucket_add(new_cell, entity)
		return
	var old_cell: Vector2i = _entity_cell[id]
	if old_cell == new_cell:
		return
	_bucket_remove(old_cell, entity)
	_entity_cell[id] = new_cell
	_bucket_add(new_cell, entity)


func has_entity(entity: Object) -> bool:
	if entity == null:
		return false
	return _entity_cell.has(entity.get_instance_id())


func entity_count() -> int:
	return _entity_cell.size()


func query_radius(center: Vector2, radius: float) -> Array:
	var result: Array = []
	if radius < 0.0:
		return result
	var radius_sq := radius * radius
	var min_cell := world_to_cell(center - Vector2(radius, radius))
	var max_cell := world_to_cell(center + Vector2(radius, radius))
	for cy in range(min_cell.y, max_cell.y + 1):
		for cx in range(min_cell.x, max_cell.x + 1):
			var cell := Vector2i(cx, cy)
			if not _buckets.has(cell):
				continue
			var bucket: Array = _buckets[cell]
			var write := 0
			for i in bucket.size():
				var entity := bucket[i] as Object
				if entity == null or not is_instance_valid(entity):
					continue
				bucket[write] = entity
				write += 1
				var pos_variant: Variant = entity.get("sim_pos")
				if not (pos_variant is Vector2):
					continue
				if center.distance_squared_to(pos_variant as Vector2) <= radius_sq:
					result.append(entity)
			if write < bucket.size():
				bucket.resize(write)
				if write == 0:
					_buckets.erase(cell)
				else:
					_buckets[cell] = bucket
	return result


func _bucket_add(cell: Vector2i, entity: Object) -> void:
	if not _buckets.has(cell):
		_buckets[cell] = []
	var bucket: Array = _buckets[cell]
	if bucket.has(entity):
		return
	bucket.append(entity)
	_buckets[cell] = bucket


func _bucket_remove(cell: Vector2i, entity: Object) -> void:
	if not _buckets.has(cell):
		return
	var bucket: Array = _buckets[cell]
	var idx := bucket.find(entity)
	if idx >= 0:
		bucket.remove_at(idx)
	if bucket.is_empty():
		_buckets.erase(cell)
	else:
		_buckets[cell] = bucket
