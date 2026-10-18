class_name CollisionResolver
extends RefCounted

const SpriteCatalogScript := preload("res://scripts/presentation/sprite_catalog.gd")
const ResourceNodeScript := preload("res://scripts/entities/resource_node.gd")
const ShoreGeometry := preload("res://scripts/world/shore_geometry.gd")

const DEFAULT_RADIUS := 0.42
const UNIT_SEPARATION_EXTRA := 0.0
static var _map_bounds_enabled := false
static var _map_min := Vector2.ZERO
static var _map_max := Vector2.ZERO


static func set_map_bounds(world_min: Vector2, world_max: Vector2) -> void:
	_map_min = world_min
	_map_max = world_max
	_map_bounds_enabled = true


static func clear_map_bounds() -> void:
	_map_bounds_enabled = false


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
		var separation := radius + unit_radius(other)
		var old_distance := from.distance_squared_to(center)
		if old_distance < separation * separation - 0.0001:
			if (to - from).dot(from - center) < -0.00001:
				return false
			continue
		var nearest := Geometry2D.get_closest_point_to_segment(center, from, to)
		if nearest.distance_squared_to(center) < separation * separation - 0.0001:
			return false
	return true


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
	# A tiny inset permits tangential travel exactly along a boundary.
	half -= Vector2.ONE * 0.0001
	var motion := to - from
	if absf(from.x) < half.x and absf(from.y) < half.y:
		var depth := half - from.abs()
		# Already embedded: permit sliding or moving out via the nearest face.
		if depth.x <= depth.y + 0.0001 and motion.x * signf(from.x) >= -0.00001:
			return false
		if depth.y <= depth.x + 0.0001 and motion.y * signf(from.y) >= -0.00001:
			return false
		return true
	var near := 0.0
	var far := 1.0
	for axis in 2:
		if absf(motion[axis]) < 0.0000001:
			if absf(from[axis]) >= half[axis]:
				return false
			continue
		var first := (-half[axis] - from[axis]) / motion[axis]
		var second := (half[axis] - from[axis]) / motion[axis]
		near = maxf(near, minf(first, second))
		far = minf(far, maxf(first, second))
		if near > far:
			return false
	return near <= far and far >= 0 and near <= 1

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
