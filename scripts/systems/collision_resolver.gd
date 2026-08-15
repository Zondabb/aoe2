class_name CollisionResolver
extends RefCounted

const SpriteCatalogScript := preload("res://scripts/presentation/sprite_catalog.gd")
const ResourceNodeScript := preload("res://scripts/entities/resource_node.gd")

const DEFAULT_RADIUS := 0.42
const UNIT_SOFT_FACTOR := 1.0
const UNIT_SOFT_ITERATIONS := 6
const UNIT_SEPARATION_EXTRA := 0.10
const UNIT_COMBAT_CHASE_EXTRA := 0.04
const UNIT_QUERY_RANGE := 3.5
const BUILDING_ITERATIONS := 3
const ALLY_FORWARD_BLEND := 0.6

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


static func min_unit_separation(
	radius: float, other_radius: float, chase_combat: bool = false
) -> float:
	var extra := UNIT_COMBAT_CHASE_EXTRA if chase_combat else UNIT_SEPARATION_EXTRA
	return radius + other_radius + extra


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
	ignore_units: Array = [],
	chase_combat: bool = false
) -> Vector2:
	var radius := unit_radius(unit)
	var solids: Array = []
	solids.append_array(buildings)
	solids.append_array(path_blockers)
	var pos := _slide_against_buildings(from_pos, desired_pos, radius, solids)
	pos = _slide_against_units(
		from_pos, pos, radius, unit, units, solids, ignore_units, chase_combat
	)
	for _i in BUILDING_ITERATIONS:
		pos = _push_out_buildings(pos, radius, solids)
	for _i in UNIT_SOFT_ITERATIONS:
		pos = _soft_separate_units(
			unit, pos, radius, units, ignore_units, chase_combat
		)
	pos = _nudge_forward_through_allies(
		from_pos, desired_pos, pos, unit, radius, units, solids, ignore_units, chase_combat
	)
	for _i in BUILDING_ITERATIONS:
		pos = _push_out_buildings(pos, radius, solids)
	return clamp_to_map(pos, radius)


static func depack_unit(
	unit: Object,
	units: Array,
	max_passes: int = 6,
	ignore_units: Array = [],
	allies_only: bool = false,
	chase_combat: bool = false
) -> Vector2:
	if unit == null:
		return Vector2.ZERO
	var radius := unit_radius(unit)
	var pos: Vector2 = unit.get("sim_pos")
	for _pass in max_passes:
		var next := _soft_separate_units(
			unit, pos, radius, units, ignore_units, chase_combat, allies_only
		)
		if next.distance_squared_to(pos) < 0.000004:
			break
		pos = next
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

static func _push_out_buildings(pos: Vector2, radius: float, buildings: Array) -> Vector2:
	var result := pos
	for value in buildings:
		var building := value as Object
		if building == null or not is_instance_valid(building):
			continue
		var half := _blocker_half(building, radius)
		if half.x <= 0.0 or half.y <= 0.0:
			continue
		var center: Vector2 = building.get("sim_pos")
		var delta := result - center
		if absf(delta.x) >= half.x or absf(delta.y) >= half.y:
			continue
		var pen_x := half.x - absf(delta.x)
		var pen_y := half.y - absf(delta.y)
		if pen_x < pen_y:
			var sx := 1.0 if delta.x >= 0.0 else -1.0
			result.x = center.x + sx * half.x
		else:
			var sy := 1.0 if delta.y >= 0.0 else -1.0
			result.y = center.y + sy * half.y
	return result

static func _slide_against_buildings(
	from_pos: Vector2,
	desired_pos: Vector2,
	radius: float,
	buildings: Array
) -> Vector2:
	if not _hits_any_building(desired_pos, radius, buildings):
		return desired_pos
	var slide_x := Vector2(desired_pos.x, from_pos.y)
	var slide_y := Vector2(from_pos.x, desired_pos.y)
	var ok_x := not _hits_any_building(slide_x, radius, buildings)
	var ok_y := not _hits_any_building(slide_y, radius, buildings)
	if ok_x and ok_y:
		if absf(desired_pos.x - from_pos.x) >= absf(desired_pos.y - from_pos.y):
			return slide_x
		return slide_y
	if ok_x:
		return slide_x
	if ok_y:
		return slide_y
	return from_pos


static func _unit_blocks_position(
	pos: Vector2,
	radius: float,
	unit: Object,
	units: Array,
	ignore_units: Array,
	chase_combat: bool
) -> bool:
	for value in units:
		var other := value as Object
		if other == null or other == unit or not is_instance_valid(other):
			continue
		if _is_ignored_unit(other, ignore_units):
			continue
		if not _unit_blocks_hard(unit, other):
			continue
		var other_pos: Vector2 = other.get("sim_pos")
		var min_dist := min_unit_separation(radius, unit_radius(other), chase_combat)
		if pos.distance_squared_to(other_pos) < min_dist * min_dist - 0.0001:
			return true
	return false


static func _slide_against_units(
	from_pos: Vector2,
	desired_pos: Vector2,
	radius: float,
	unit: Object,
	units: Array,
	solids: Array,
	ignore_units: Array,
	chase_combat: bool
) -> Vector2:
	if not _unit_blocks_position(
		desired_pos, radius, unit, units, ignore_units, chase_combat
	):
		return desired_pos
	if _hits_any_building(desired_pos, radius, solids):
		return desired_pos
	var slide_x := Vector2(desired_pos.x, from_pos.y)
	var slide_y := Vector2(from_pos.x, desired_pos.y)
	var best := from_pos
	var best_dist := from_pos.distance_squared_to(desired_pos)
	for candidate in [slide_x, slide_y]:
		if _unit_blocks_position(candidate, radius, unit, units, ignore_units, chase_combat):
			continue
		if _hits_any_building(candidate, radius, solids):
			continue
		var dist_sq: float = candidate.distance_squared_to(desired_pos)
		if dist_sq < best_dist:
			best = candidate
			best_dist = dist_sq
	return best


static func _unit_blocks_hard(unit: Object, other: Object) -> bool:
	if other.get("team") != unit.get("team"):
		return true
	return int(other.get("order")) == Enums.OrderType.NONE


static func _unit_hard_overlaps(
	pos: Vector2,
	radius: float,
	unit: Object,
	units: Array,
	ignore_units: Array = [],
	chase_combat: bool = false
) -> bool:
	for value in units:
		var other := value as Object
		if other == null or other == unit or not is_instance_valid(other):
			continue
		if _is_ignored_unit(other, ignore_units):
			continue
		if not _unit_blocks_hard(unit, other):
			continue
		var other_pos: Vector2 = other.get("sim_pos")
		var min_dist := min_unit_separation(radius, unit_radius(other), chase_combat)
		if pos.distance_squared_to(other_pos) < min_dist * min_dist - 0.0001:
			return true
	return false


static func _nudge_forward_through_allies(
	from_pos: Vector2,
	desired_pos: Vector2,
	pos: Vector2,
	unit: Object,
	radius: float,
	units: Array,
	solids: Array,
	ignore_units: Array = [],
	chase_combat: bool = false
) -> Vector2:
	var forward := desired_pos - from_pos
	if forward.length_squared() < 0.0001:
		return pos
	var forward_dir := forward.normalized()
	var wanted := forward.length()
	var achieved := (pos - from_pos).dot(forward_dir)
	if achieved >= wanted * 0.3:
		return pos
	if _hits_any_building(desired_pos, radius, solids):
		return pos
	var step := maxf(achieved, wanted * ALLY_FORWARD_BLEND)
	var candidate := from_pos + forward_dir * step
	if _hits_any_building(candidate, radius, solids):
		return pos
	if _hits_any_building(candidate, radius, solids):
		return pos
	if _unit_hard_overlaps(candidate, radius, unit, units, ignore_units, chase_combat):
		return pos
	return candidate


static func _unit_overlaps(
	pos: Vector2,
	radius: float,
	unit: Object,
	units: Array,
	ignore_units: Array = [],
	chase_combat: bool = false
) -> bool:
	return _unit_hard_overlaps(pos, radius, unit, units, ignore_units, chase_combat)

static func _soft_separate_units(
	unit: Object,
	pos: Vector2,
	radius: float,
	units: Array,
	ignore_units: Array = [],
	chase_combat: bool = false,
	allies_only: bool = false
) -> Vector2:
	var result := pos
	for value in units:
		var other := value as Object
		if other == null or other == unit or not is_instance_valid(other):
			continue
		if _is_ignored_unit(other, ignore_units):
			continue
		if allies_only and other.get("team") != unit.get("team"):
			continue
		var other_pos: Vector2 = other.get("sim_pos")
		var offset := result - other_pos
		var dist := offset.length()
		if dist > UNIT_QUERY_RANGE:
			continue
		var other_r := unit_radius(other)
		var min_dist := min_unit_separation(radius, other_r, chase_combat)
		if dist >= min_dist:
			continue
		if dist <= 0.0001:
			offset = Vector2.from_angle(float(unit.get_instance_id() % 628) / 100.0)
			dist = 1.0
		var overlap := min_dist - dist
		result += offset.normalized() * (overlap * UNIT_SOFT_FACTOR)
	return result
