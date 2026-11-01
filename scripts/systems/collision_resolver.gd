class_name CollisionResolver
extends RefCounted

const SpriteCatalogScript := preload("res://scripts/presentation/sprite_catalog.gd")
const ResourceNodeScript := preload("res://scripts/entities/resource_node.gd")
const ShoreGeometry := preload("res://scripts/world/shore_geometry.gd")
const Fixed := preload("res://scripts/core/sim_fixed.gd")

const DEFAULT_RADIUS := 0.42
const UNIT_SEPARATION_EXTRA := 0.0
static var _map_bounds_enabled := false
static var _map_min := Vector2.ZERO
static var _map_max := Vector2.ZERO
## [enabled, min_x, min_y, max_x, max_y] in fixed units for LocalAvoidance.
static var _bounds_record := PackedInt64Array([0, 0, 0, 0, 0])


static func set_map_bounds(world_min: Vector2, world_max: Vector2) -> void:
	_map_min = world_min
	_map_max = world_max
	_map_bounds_enabled = true
	var low := Fixed.vector(world_min)
	var high := Fixed.vector(world_max)
	_bounds_record = PackedInt64Array([1, low.x, low.y, high.x, high.y])


static func clear_map_bounds() -> void:
	_map_bounds_enabled = false
	_bounds_record = PackedInt64Array([0, 0, 0, 0, 0])


static func bounds_record() -> PackedInt64Array:
	return _bounds_record


## Integer avoidance boxes for blocker nodes: [boxes, water]. Boxes have
## stride 5 (center_x, center_y, half_x + radius, half_y + radius, water
## index or -1); water holds shoreline contours referenced by index.
static func static_boxes(solids: Array, radius_q: int) -> Array:
	var boxes := PackedInt64Array()
	var water: Array = []
	for solid in solids:
		if not is_instance_valid(solid) or solid.get("is_placement_ghost") == true:
			continue
		var half := Fixed.vector(_blocker_half(solid, 0.0))
		if half.x <= 0 or half.y <= 0:
			continue
		var center := Fixed.vector(solid.get("sim_pos"))
		var water_index := -1
		if solid.has_method("get_water_contours") and not solid.get_water_contours().is_empty():
			water_index = water.size()
			water.append(solid.get_water_contours())
		boxes.append_array([center.x, center.y, half.x + radius_q, half.y + radius_q, water_index])
	return [boxes, water]


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
	var pos := clamp_to_map(desired_pos, radius)
	return pos if is_step_safe(unit, from_pos, pos, units, solids, ignore_units) else from_pos


## Swept geometry, independent of facing angle. Existing overlaps may escape,
## but a lateral/large step cannot create a new overlap or tunnel through a body.
static func is_step_safe(unit: Object, from: Vector2, to: Vector2, units: Array, solids: Array, ignore: Array = []) -> bool:
	var radius := unit_radius(unit)
	if not clamp_to_map(to, radius).is_equal_approx(to):
		return false
	if not static_step_safe(from, to, radius, solids):
		return false
	for other in units:
		if not is_instance_valid(other) or other == unit or other in ignore:
			continue
		var health: Variant = other.get("hp")
		if health != null and float(health) <= 0:
			continue
		var center: Vector2 = other.get("sim_pos")
		var separation := Fixed.coord(radius) + Fixed.coord(unit_radius(other))
		var origin := Fixed.vector(from)
		var destination := Fixed.vector(to)
		var offset := origin - Fixed.vector(center)
		var motion := destination - origin
		var limit := separation * separation
		if Fixed.length_sq(offset) < limit:
			if _dot(motion, offset) < 0:
				return false
			continue
		var nearest := origin
		var length_squared := Fixed.length_sq(motion)
		if length_squared > 0:
			var projection := clampi(-_dot(offset, motion), 0, length_squared)
			nearest += Vector2i(Fixed.mul_div(motion.x, projection, length_squared), Fixed.mul_div(motion.y, projection, length_squared))
		if Fixed.length_sq(nearest - Fixed.vector(center)) < limit:
			return false
	return true

static func _dot(a: Vector2i, b: Vector2i) -> int:
	return int(a.x) * int(b.x) + int(a.y) * int(b.y)

static func static_step_safe(from: Vector2, to: Vector2, radius: float, solids: Array) -> bool:
	for solid in solids:
		if not is_instance_valid(solid) or solid.get("is_placement_ghost") == true:
			continue
		var half := _blocker_half(solid, radius)
		if half.x <= 0 or half.y <= 0:
			continue
		var center: Vector2 = solid.get("sim_pos")
		if solid.has_method("get_water_contours") and not solid.get_water_contours().is_empty():
			if ShoreGeometry.segment_hits(from, to, radius, solid.get_water_contours()): return false
		elif segment_hits_box(from - center, to - center, half):
			return false
	return true


## Avoidance samples many velocities against the same local blockers. Geometry
## snapshots remove repeated Object property reads from that inner loop.
static func static_geometry_step_safe(from: Vector2, to: Vector2, geometry: Array[Dictionary]) -> bool:
	for solid in geometry:
		var center: Vector2 = solid.center
		if solid.has("contours"):
			if ShoreGeometry.segment_hits(from, to, solid.radius, solid.contours): return false
		elif segment_hits_box(from - center, to - center, solid.half):
			return false
	return true


static func segment_hits_box(from: Vector2, to: Vector2, half: Vector2) -> bool:
	# Geometry predicates use the shared 1/1024-unit lattice. A one-quantum
	# inset permits travel along the boundary; rational slab intervals avoid
	# divisions and architecture-dependent rounding at a corner.
	var origin := Fixed.vector(from)
	var extent := Fixed.vector(half) - Vector2i.ONE
	if extent.x <= 0 or extent.y <= 0: return false
	var motion := Fixed.vector(to) - origin
	if absi(origin.x) < extent.x and absi(origin.y) < extent.y:
		var depth := extent - origin.abs()
		# Already embedded: permit sliding or moving out via the nearest face.
		if depth.x <= depth.y and motion.x * signi(origin.x) >= 0:
			return false
		if depth.y <= depth.x and motion.y * signi(origin.y) >= 0:
			return false
		return true
	var near_num := 0
	var near_den := 1
	var far_num := 1
	var far_den := 1
	for axis in 2:
		if motion[axis] == 0:
			if absi(origin[axis]) >= extent[axis]:
				return false
			continue
		var denominator := absi(motion[axis])
		var first := -int(extent[axis]) - int(origin[axis])
		var second := int(extent[axis]) - int(origin[axis])
		if motion[axis] < 0:
			var swap := first
			first = -second
			second = -swap
		if first * near_den > near_num * denominator:
			near_num = first
			near_den = denominator
		if second * far_den < far_num * denominator:
			far_num = second
			far_den = denominator
		if near_num * far_den > far_num * near_den:
			return false
	return true

static func _blocker_half(blocker: Object, radius: float) -> Vector2:
	if blocker == null:
		return Vector2.ZERO
	if blocker.has_method("get_movement_half"):
		var movement_half: Vector2 = blocker.call("get_movement_half")
		return movement_half + Vector2.ONE * radius if movement_half.x > 0.0 and movement_half.y > 0.0 else Vector2.ZERO
	var building_def := blocker.get("def") as BuildingDef
	if building_def != null and not building_def.blocks_movement:
		return Vector2.ZERO
	if building_def == null and blocker.get("resource_type") != null:
		if float(blocker.get("amount")) <= 0.0 or not ResourceNodeScript.resource_blocks_pathfinding(int(blocker.get("resource_type"))):
			return Vector2.ZERO
	var half_variant: Variant = blocker.get("block_half")
	if half_variant is Vector2:
		var half := half_variant as Vector2
		if half.x > 0.0 and half.y > 0.0:
			return half + Vector2(radius, radius)
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
	if building != null and building.has_method("get_water_contours") and not building.get_water_contours().is_empty():
		return ShoreGeometry.circle_hits(pos, radius, building.get_water_contours())
	var half := _blocker_half(building, radius)
	if half.x <= 0.0 or half.y <= 0.0:
		return false
	var center: Vector2 = building.get("sim_pos")
	var delta := Fixed.vector(pos) - Fixed.vector(center)
	var extent := Fixed.vector(half)
	return absi(delta.x) < extent.x and absi(delta.y) < extent.y

static func _hits_any_building(pos: Vector2, radius: float, buildings: Array) -> bool:
	for value in buildings:
		var building := value as Object
		if building == null or not is_instance_valid(building):
			continue
		if _hits_building(pos, radius, building):
			return true
	return false
