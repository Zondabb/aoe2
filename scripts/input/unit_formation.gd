extends RefCounted

const Iso := preload("res://scripts/presentation/iso_math.gd")
const KINDS := [&"line", &"box", &"staggered", &"flank"]

static func normalize_kind(kind: StringName) -> StringName:
	return kind if kind in KINDS else &"line"

static func position_of(unit: Node2D) -> Vector2:
	var logical: Variant = unit.get("sim_pos")
	return logical if logical is Vector2 else Iso.screen_to_world(unit.global_position)

static func center(units: Array) -> Vector2:
	var result := Vector2.ZERO
	var count := 0
	for unit in units:
		if is_instance_valid(unit):
			result += position_of(unit)
			count += 1
	return result / maxf(count, 1)

static func role(unit: Node2D) -> int:
	var definition := unit.get("def") as UnitDef
	if definition == null:
		return 0
	if definition.id in [&"monk", &"missionary", &"villager"]:
		return 2
	return 1 if definition.is_ranged else 0

## Offsets use x across the front and y toward the destination.
static func offsets(count: int, kind: StringName, spacing: float) -> Array[Vector2]:
	var points: Array[Vector2] = []
	if count <= 0:
		return points
	if count == 1:
		return [Vector2.ZERO]
	kind = normalize_kind(kind)
	var cols := maxi(2, int(ceil(sqrt(float(count) * (1.0 if kind == &"box" else 2.0)))))
	cols = mini(cols, count)
	if kind == &"flank":
		var wing_count := int(ceil(float(count) / 2.0))
		var wing_cols := maxi(1, int(ceil(sqrt(float(wing_count)))))
		for i in count:
			var side := -1.0 if i % 2 == 0 else 1.0
			var wing_index := int(i / 2)
			points.append(Vector2(side * (1.5 + wing_index % wing_cols), -int(wing_index / wing_cols)) * spacing)
	else:
		var rows := int(ceil(float(count) / cols))
		for row in rows:
			var row_count := mini(cols, count - row * cols)
			for col in row_count:
				var x := float(col) - float(row_count - 1) * 0.5
				if kind == &"staggered":
					x = x * 1.5 + (0.375 if row % 2 == 0 else -0.375)
				points.append(Vector2(x, -row * (1.5 if kind == &"staggered" else 1.0)) * spacing)
	var mean := Vector2.ZERO
	for point in points:
		mean += point
	mean /= count
	for i in points.size():
		points[i] -= mean
	if kind == &"box":
		# Assign outer positions to melee troops and shelter fragile units inside.
		points.sort_custom(func(a: Vector2, b: Vector2) -> bool:
			var ar := maxf(absf(a.x), absf(a.y))
			var br := maxf(absf(b.x), absf(b.y))
			return ar > br if not is_equal_approx(ar, br) else a.y > b.y)
	else:
		points.sort_custom(func(a: Vector2, b: Vector2) -> bool:
			return a.y > b.y if not is_equal_approx(a.y, b.y) else a.x < b.x)
	return points

## Results map to input order, so the same positions can be sent to the host.
## Preserve each role's current left/right order while choosing nearby slots.
static func destinations(units: Array, target: Vector2, kind: StringName = &"line") -> PackedVector2Array:
	var result := PackedVector2Array()
	if units.is_empty():
		return result
	var origin := center(units)
	var forward := (target - origin).normalized()
	if forward.is_zero_approx():
		forward = Vector2(1, 1).normalized()
	var right := Vector2(forward.y, -forward.x)
	var spacing := 1.65
	for unit in units:
		var definition := unit.get("def") as UnitDef
		if definition != null:
			spacing = maxf(spacing, definition.resolved_footprint_radius() * 2.0 + 0.35)
	var slots := offsets(units.size(), kind, spacing)
	var indices: Array[int] = []
	for i in units.size():
		indices.append(i)
		result.append(target)
	indices.sort_custom(func(a: int, b: int) -> bool:
		var ar := role(units[a])
		var br := role(units[b])
		if ar != br: return ar < br
		var ax := (position_of(units[a]) - origin).dot(right)
		var bx := (position_of(units[b]) - origin).dot(right)
		return ax < bx if not is_equal_approx(ax, bx) else units[a].get_instance_id() < units[b].get_instance_id())
	var first := 0
	while first < indices.size():
		var end := first + 1
		while end < indices.size() and role(units[indices[end]]) == role(units[indices[first]]):
			end += 1
		var available: Array[Vector2] = slots.slice(first, end)
		for i in range(first, end):
			var index := indices[i]
			var relative := position_of(units[index]) - origin
			var local := Vector2(relative.dot(right), relative.dot(forward))
			var best := 0
			for candidate in range(1, available.size()):
				if local.distance_squared_to(available[candidate]) < local.distance_squared_to(available[best]):
					best = candidate
			var slot := available[best]
			available.remove_at(best)
			result[index] = target + right * slot.x + forward * slot.y
		first = end
	return result
