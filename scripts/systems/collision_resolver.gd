class_name CollisionResolver
extends RefCounted

const DEFAULT_RADIUS := 0.35
const UNIT_SOFT_FACTOR := 0.5
const UNIT_QUERY_RANGE := 3.0
const BUILDING_ITERATIONS := 3

static func unit_radius(unit: Object) -> float:
	if unit == null:
		return DEFAULT_RADIUS
	var unit_def := unit.get("def") as UnitDef
	if unit_def != null and unit_def.collision_radius > 0.0:
		return unit_def.collision_radius
	return DEFAULT_RADIUS

static func resolve_move(
	unit: Object,
	from_pos: Vector2,
	desired_pos: Vector2,
	units: Array,
	buildings: Array,
	path_blockers: Array = []
) -> Vector2:
	var radius := unit_radius(unit)
	var solids: Array = []
	solids.append_array(buildings)
	solids.append_array(path_blockers)
	var pos := _slide_against_buildings(from_pos, desired_pos, radius, solids)
	for _i in BUILDING_ITERATIONS:
		pos = _push_out_buildings(pos, radius, solids)
	pos = _soft_separate_units(unit, pos, radius, units)
	for _i in BUILDING_ITERATIONS:
		pos = _push_out_buildings(pos, radius, solids)
	return pos

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
		return building_def.footprint * 0.5 + Vector2(radius, radius)
	var size_variant: Variant = blocker.get("block_size")
	if size_variant is Vector2:
		return (size_variant as Vector2) * 0.5 + Vector2(radius, radius)
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

static func _soft_separate_units(
	unit: Object,
	pos: Vector2,
	radius: float,
	units: Array
) -> Vector2:
	var result := pos
	for value in units:
		var other := value as Object
		if other == null or other == unit or not is_instance_valid(other):
			continue
		var other_pos: Vector2 = other.get("sim_pos")
		var offset := result - other_pos
		var dist := offset.length()
		if dist > UNIT_QUERY_RANGE:
			continue
		var other_r := unit_radius(other)
		var min_dist := radius + other_r
		if dist >= min_dist:
			continue
		if dist <= 0.0001:
			offset = Vector2(1, 0)
			dist = 1.0
		var overlap := min_dist - dist
		result += offset.normalized() * (overlap * UNIT_SOFT_FACTOR)
	return result
