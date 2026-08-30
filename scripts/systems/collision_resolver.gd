class_name CollisionResolver
extends RefCounted

const SpriteCatalogScript := preload("res://scripts/presentation/sprite_catalog.gd")
const ResourceNodeScript := preload("res://scripts/entities/resource_node.gd")

const DEFAULT_RADIUS := 0.42
const UNIT_SEPARATION_EXTRA := 0.0
## Half-angle of the forward cone toward another unit/building (degrees).
## Move is blocked when angle(move, to_other) < this value; sideways/away is allowed.
const DEFAULT_UNIT_BLOCK_ANGLE_DEGREES := 45.0

static var _map_bounds_enabled := false
static var _map_min := Vector2.ZERO
static var _map_max := Vector2.ZERO
static var unit_block_angle_degrees := DEFAULT_UNIT_BLOCK_ANGLE_DEGREES


static func set_map_bounds(world_min: Vector2, world_max: Vector2) -> void:
	_map_min = world_min
	_map_max = world_max
	_map_bounds_enabled = true


static func clear_map_bounds() -> void:
	_map_bounds_enabled = false


static func set_unit_block_angle_degrees(degrees: float) -> void:
	unit_block_angle_degrees = clampf(degrees, 0.0, 180.0)


static func reset_unit_block_angle_degrees() -> void:
	unit_block_angle_degrees = DEFAULT_UNIT_BLOCK_ANGLE_DEGREES


static func clamp_to_map(pos: Vector2, radius: float) -> Vector2:
	if not _map_bounds_enabled:
		return pos
	var inset := maxf(radius, 0.0)
	return Vector2(
		clampf(pos.x, _map_min.x + inset, _map_max.x - inset),
		clampf(pos.y, _map_min.y + inset, _map_max.y - inset)
	)

static func unit_radius(unit: Object) -> float:
	if unit == null:
		return DEFAULT_RADIUS
	var unit_def := unit.get("def") as UnitDef
	if unit_def != null:
		return unit_def.resolved_footprint_radius()
	return DEFAULT_RADIUS


static func min_unit_separation(radius: float, other_radius: float) -> float:
	return radius + other_radius + UNIT_SEPARATION_EXTRA


static func _is_ignored_unit(other: Object, ignore_units: Array) -> bool:
	for item in ignore_units:
		if item == other:
			return true
	return false


static func resolve_move(
	unit: Object,
	from_pos: Vector2,
	desired_pos: Vector2,
	units: Array,
	buildings: Array,
	path_blockers: Array = [],
	ignore_units: Array = []
) -> Vector2:
	var radius := unit_radius(unit)
	var solids: Array = []
	solids.append_array(buildings)
	solids.append_array(path_blockers)
	var pos := desired_pos
	if _blocks_building_move(from_pos, desired_pos, radius, solids):
		pos = from_pos
	if pos != from_pos and _blocks_unit_move(
		from_pos, pos, radius, unit, units, ignore_units
	):
		pos = from_pos
	return clamp_to_map(pos, radius)

static func _blocks_unit_move(
	from_pos: Vector2,
	desired_pos: Vector2,
	radius: float,
	unit: Object,
	units: Array,
	ignore_units: Array
) -> bool:
	var move := desired_pos - from_pos
	if move.length_squared() < 0.0000001:
		return false
	var move_dir := move.normalized()
	var block_cos := cos(deg_to_rad(unit_block_angle_degrees))
	for value in units:
		var other := value as Object
		if other == null or other == unit or not is_instance_valid(other):
			continue
		if _is_ignored_unit(other, ignore_units):
			continue
		var other_pos: Vector2 = other.get("sim_pos")
		var min_dist := min_unit_separation(radius, unit_radius(other))
		var from_dist := from_pos.distance_to(other_pos)
		var desired_dist := desired_pos.distance_to(other_pos)
		# Only interact when already overlapping or about to enter the bubble.
		if from_dist >= min_dist - 0.0001 and desired_dist >= min_dist - 0.0001:
			continue
		var to_other := other_pos - from_pos
		if to_other.length_squared() < 0.0000001:
			# Coincident centers: no facing cone; allow unstacking.
			continue
		# Block when moving into the forward cone toward the other unit.
		# angle < threshold  <=>  dot(move_dir, to_other_dir) > cos(threshold)
		if move_dir.dot(to_other.normalized()) > block_cos + 0.0001:
			return true
	return false


## Same forward-cone rule as units: only block when the step closes on the
## solid (overlap / entering AABB) and move aims at the blocker center.
static func _blocks_building_move(
	from_pos: Vector2,
	desired_pos: Vector2,
	radius: float,
	buildings: Array
) -> bool:
	var move := desired_pos - from_pos
	if move.length_squared() < 0.0000001:
		return false
	var move_dir := move.normalized()
	var block_cos := cos(deg_to_rad(unit_block_angle_degrees))
	for value in buildings:
		var building := value as Object
		if building == null or not is_instance_valid(building):
			continue
		var from_hits := _hits_building(from_pos, radius, building)
		var desired_hits := _hits_building(desired_pos, radius, building)
		if not from_hits and not desired_hits:
			continue
		var center: Vector2 = building.get("sim_pos")
		var to_other := center - from_pos
		if to_other.length_squared() < 0.0000001:
			continue
		if move_dir.dot(to_other.normalized()) > block_cos + 0.0001:
			return true
	return false

static func _blocker_half(blocker: Object, radius: float) -> Vector2:
	if blocker == null:
		return Vector2.ZERO
	var half_variant: Variant = blocker.get("block_half")
	if half_variant is Vector2:
		var half := half_variant as Vector2
		if half.x > 0.0 and half.y > 0.0:
			return half + Vector2(radius, radius)
	var building_def := blocker.get("def") as BuildingDef
	if building_def != null:
		var civ := blocker.get("civ") as CivDef
		var civ_id: StringName = civ.id if civ != null else &""
		return (
			SpriteCatalogScript.pathfinding_footprint_for_building(building_def, civ_id) * 0.5
			+ Vector2(radius, radius)
		)
	var size_variant: Variant = blocker.get("block_size")
	if size_variant is Vector2:
		return (size_variant as Vector2) * 0.5 + Vector2(radius, radius)
	if blocker.get("resource_type") != null and float(blocker.get("amount")) > 0.0:
		var resource_type: int = int(blocker.get("resource_type"))
		var footprint := ResourceNodeScript.pathfinding_footprint(resource_type)
		if footprint.length_squared() > 0.0:
			return footprint * 0.5 + Vector2(radius, radius)
	return Vector2.ZERO

static func _hits_building(pos: Vector2, radius: float, building: Object) -> bool:
	var half := _blocker_half(building, radius)
	if half.x <= 0.0 or half.y <= 0.0:
		return false
	var center: Vector2 = building.get("sim_pos")
	var delta := pos - center
	return absf(delta.x) < half.x and absf(delta.y) < half.y

static func _hits_any_building(pos: Vector2, radius: float, buildings: Array) -> bool:
	for value in buildings:
		var building := value as Object
		if building == null or not is_instance_valid(building):
			continue
		if _hits_building(pos, radius, building):
			return true
	return false
