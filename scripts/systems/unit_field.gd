class_name UnitFieldScript
extends RefCounted
## Integer movement snapshot of every unit: fixed position, footprint radius,
## velocity (fixed units per second) and alive flag, bucketed for neighbour
## queries. Local avoidance reads only this snapshot, so the native field
## (AoeUnitField, GDExtension) and this GDScript reference return the same
## bodies for the same update calls. Results never depend on iteration order:
## avoidance only sums integer risks and tests any-hit geometry.
##
## Updates: VisionService registers/unregisters units and rebuilds the field
## with its index (every lockstep step); a unit re-syncs its own entry at the
## end of each movement update and when its health reaches zero.

const Fixed := preload("res://scripts/core/sim_fixed.gd")
const CELL := 2048 # Two tiles in 1/1024 tile units.
## Inputs are clamped so every product in the solver fits in 64 bits.
const V_MAX := 8192
const RADIUS_MAX := 8192
const POS_MAX := 1 << 24
## Same as LocalAvoidance.MARGIN_Q and Fixed.TIME_SCALE.
const MARGIN_Q := 123
const TIME_SCALE := 30720

## key -> PackedInt64Array [x, y, radius, vx, vy, alive, cell_x, cell_y, speed]
## (speed = isqrt(vx² + vy²), computed once per update rather than per query).
var _units: Dictionary = {}
## Vector2i cell -> Array[int] keys
var _buckets: Dictionary = {}
var _max_radius := 0
var _max_speed := 0

static func native_available() -> bool:
	return ClassDB.class_exists("AoeUnitField")

## The native field when the extension is loaded, otherwise this script.
static func create() -> RefCounted:
	if native_available():
		return ClassDB.instantiate("AoeUnitField")
	return new()

func is_native() -> bool:
	return false

func clear() -> void:
	_units.clear()
	_buckets.clear()
	_max_radius = 0
	_max_speed = 0

func size() -> int:
	return _units.size()

func has_unit(key: int) -> bool:
	return _units.has(key)

func set_unit(key: int, position: Vector2i, radius: int, velocity: Vector2i, alive: bool) -> void:
	position = Vector2i(clampi(position.x, -POS_MAX, POS_MAX), clampi(position.y, -POS_MAX, POS_MAX))
	radius = clampi(radius, 0, RADIUS_MAX)
	velocity = Vector2i(clampi(velocity.x, -V_MAX, V_MAX), clampi(velocity.y, -V_MAX, V_MAX))
	var cell := Vector2i(Fixed.floor_div(position.x, CELL), Fixed.floor_div(position.y, CELL))
	var record: Variant = _units.get(key)
	if record != null:
		var old_cell := Vector2i(int(record[6]), int(record[7]))
		if old_cell != cell:
			_bucket_remove(old_cell, key)
			_bucket_add(cell, key)
	else:
		_bucket_add(cell, key)
	var speed := Fixed.isqrt(int(velocity.x) * velocity.x + int(velocity.y) * velocity.y)
	_units[key] = PackedInt64Array([position.x, position.y, radius, velocity.x, velocity.y, 1 if alive else 0, cell.x, cell.y, speed])
	_max_radius = maxi(_max_radius, radius)
	_max_speed = maxi(_max_speed, speed + 1)

func remove(key: int) -> void:
	var record: Variant = _units.get(key)
	if record == null: return
	_bucket_remove(Vector2i(int(record[6]), int(record[7])), key)
	_units.erase(key)

func _bucket_add(cell: Vector2i, key: int) -> void:
	var bucket: Array = _buckets.get(cell, [])
	bucket.append(key)
	_buckets[cell] = bucket

func _bucket_remove(cell: Vector2i, key: int) -> void:
	var bucket: Array = _buckets.get(cell, [])
	bucket.erase(key)
	if bucket.is_empty(): _buckets.erase(cell)

## Bodies that the swept/predicted avoidance of a unit at `from` can touch
## within `horizon` time units: stride 5 [rel_x, rel_y, vel_x, vel_y, R].
## R is the combined footprint radius. Same reach rule as the native field.
func gather(self_key: int, from: Vector2i, radius: int, speed: int, horizon: int) -> PackedInt64Array:
	var bodies := PackedInt64Array()
	from = Vector2i(clampi(from.x, -POS_MAX, POS_MAX), clampi(from.y, -POS_MAX, POS_MAX))
	radius = clampi(radius, 0, RADIUS_MAX)
	speed = clampi(speed, 0, 2 * V_MAX)
	horizon = clampi(horizon, 0, 2 * TIME_SCALE)
	# Cell range bound: any body passing the exact reach test below lies within.
	var bound: int = radius + _max_radius + MARGIN_Q + Fixed.mul_div(speed + _max_speed, horizon, TIME_SCALE) + 1
	var low := Vector2i(Fixed.floor_div(from.x - bound, CELL), Fixed.floor_div(from.y - bound, CELL))
	var high := Vector2i(Fixed.floor_div(from.x + bound, CELL), Fixed.floor_div(from.y + bound, CELL))
	for cy in range(low.y, high.y + 1):
		for cx in range(low.x, high.x + 1):
			var bucket: Variant = _buckets.get(Vector2i(cx, cy))
			if bucket == null: continue
			for key in bucket:
				if key == self_key: continue
				var record: PackedInt64Array = _units[key]
				if record[5] == 0: continue
				var rx: int = record[0] - from.x
				var ry: int = record[1] - from.y
				# Cheap box rejection; `bound` exceeds every exact reach below.
				if rx > bound or rx < -bound or ry > bound or ry < -bound: continue
				var combined: int = radius + record[2]
				var reach: int = combined + MARGIN_Q + Fixed.mul_div(speed + record[8], horizon, TIME_SCALE)
				if rx * rx + ry * ry > reach * reach: continue
				bodies.append_array([rx, ry, record[3], record[4], combined])
	return bodies

## Full GDScript steering (water-free inputs match AoeUnitField.steer exactly).
func steer(self_key: int, motion: PackedInt64Array, boxes: PackedInt64Array, bounds: PackedInt64Array, cache: Dictionary) -> Vector2i:
	return load("res://scripts/systems/local_avoidance.gd").steer_with_field(self, self_key, motion, boxes, [], bounds, cache)
