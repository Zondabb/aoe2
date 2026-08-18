class_name CollisionResolver
extends RefCounted

const SpriteCatalogScript := preload("res://scripts/presentation/sprite_catalog.gd")
const ResourceNodeScript := preload("res://scripts/entities/resource_node.gd")

const DEFAULT_RADIUS := 0.42

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


static func resolve_move(
	unit: Object,
	from_pos: Vector2,
	desired_pos: Vector2,
	buildings: Array,
	path_blockers: Array = []
) -> Vector2:
	var radius := unit_radius(unit)
	var solids: Array = []
	solids.append_array(buildings)
	solids.append_array(path_blockers)
	# Do not snap/push out of overlaps. Only reject newly entering a solid.
	var pos := desired_pos
	if _hits_any_building(desired_pos, radius, solids) and not _hits_any_building(from_pos, radius, solids):
		pos = from_pos
	return clamp_to_map(pos, radius)

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
