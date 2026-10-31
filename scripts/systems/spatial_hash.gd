class_name SpatialHash
extends RefCounted

## Uniform grid buckets over logical xz (sim_pos). Not used for pathfinding.

const DEFAULT_CELL_SIZE := 2.0
const Fixed := preload("res://scripts/core/sim_fixed.gd")

var cell_size := DEFAULT_CELL_SIZE
var _buckets: Dictionary = {}
var _entity_cell: Dictionary = {}
## Sorted occupied X cells for each Y row. Radius queries retain their original
## row/column/bucket order without probing every empty cell in the rectangle.
var _row_columns: Dictionary = {}


func setup(p_cell_size: float = DEFAULT_CELL_SIZE) -> void:
	cell_size = maxf(0.25, p_cell_size)
	clear()


func clear() -> void:
	_buckets.clear()
	_entity_cell.clear()
	_row_columns.clear()


func world_to_cell(world: Vector2) -> Vector2i:
	var size := maxi(1, Fixed.coord(cell_size))
	return Vector2i(Fixed.floor_div(Fixed.coord(world.x), size), Fixed.floor_div(Fixed.coord(world.y), size))


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
	var radius_q := Fixed.coord(radius)
	var radius_sq := radius_q * radius_q
	var origin := Fixed.vector(center)
	var size := maxi(1, Fixed.coord(cell_size))
	var min_cell := Vector2i(Fixed.floor_div(origin.x - radius_q, size), Fixed.floor_div(origin.y - radius_q, size))
	var max_cell := Vector2i(Fixed.floor_div(origin.x + radius_q, size), Fixed.floor_div(origin.y + radius_q, size))
	var empty_cells: Array[Vector2i] = []
	for cy in range(min_cell.y, max_cell.y + 1):
		if not _row_columns.has(cy): continue
		var columns: PackedInt32Array = _row_columns[cy]
		var column_index := columns.bsearch(min_cell.x)
		while column_index < columns.size():
			var cx := columns[column_index]
			if cx > max_cell.x: break
			column_index += 1
			var cell := Vector2i(cx, cy)
			var bucket: Array = _buckets[cell]
			var write := 0
			for i in bucket.size():
				# A freed-object Variant must be rejected before casting it to
				# Object; the cast itself raises an error in Godot 4.7.
				var candidate: Variant = bucket[i]
				if candidate == null or not is_instance_valid(candidate):
					continue
				var entity := candidate as Object
				bucket[write] = entity
				write += 1
				# Units keep their authoritative grid position; reading it
				# directly equals Fixed.vector(sim_pos) without the property
				# getter and two float conversions per neighbour.
				var point: Vector2i
				if entity is UnitAgent:
					var unit: UnitAgent = entity
					point = unit._sim_pos_q
				else:
					var pos_variant: Variant = entity.get("sim_pos")
					if not (pos_variant is Vector2):
						continue
					point = Fixed.vector(pos_variant as Vector2)
				var dx: int = int(origin.x) - int(point.x)
				var dy: int = int(origin.y) - int(point.y)
				if dx * dx + dy * dy <= radius_sq:
					result.append(entity)
			if write < bucket.size():
				bucket.resize(write)
				if write == 0:
					empty_cells.append(cell)
				else:
					_buckets[cell] = bucket
	# Defer removals until column traversal is done so packed-array mutation
	# cannot shift the iterator past the next occupied bucket.
	for cell in empty_cells:
		_buckets.erase(cell)
		_remove_row_column(cell)
	# Restoring a keyframe rebuilds buckets; insertion history must not decide
	# combat ties or floating-point accumulation order in a network match.
	if not result.is_empty() and result[0].has_meta("lockstep_entity"):
		_sort_by_net_id(result)
	return result


## net_id is unique per lockstep entity: sort the integer keys natively
## instead of calling a comparison lambda (two meta lookups) n·log n times.
static func _sort_by_net_id(result: Array) -> void:
	var keyed := {}
	var keys := PackedInt64Array()
	for entity in result:
		var key := int(entity.get_meta("net_id", 0))
		if key == 0 or keyed.has(key):
			result.sort_custom(func(a: Object, b: Object): return int(a.get_meta("net_id", 0)) < int(b.get_meta("net_id", 0)))
			return
		keyed[key] = entity
		keys.append(key)
	keys.sort()
	for i in keys.size():
		result[i] = keyed[keys[i]]


func _bucket_add(cell: Vector2i, entity: Object) -> void:
	if not _buckets.has(cell):
		_buckets[cell] = []
		var columns: PackedInt32Array = _row_columns.get(cell.y, PackedInt32Array())
		var index := columns.bsearch(cell.x)
		columns.insert(index, cell.x)
		_row_columns[cell.y] = columns
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
		_remove_row_column(cell)
	else:
		_buckets[cell] = bucket


func _remove_row_column(cell: Vector2i) -> void:
	var columns: PackedInt32Array = _row_columns[cell.y]
	var index := columns.bsearch(cell.x)
	columns.remove_at(index)
	if columns.is_empty():
		_row_columns.erase(cell.y)
	else:
		_row_columns[cell.y] = columns
