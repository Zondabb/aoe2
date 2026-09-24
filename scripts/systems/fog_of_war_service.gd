class_name FogOfWarService
extends RefCounted

## Match-local, simulation-space visibility. Rendering never mutates these masks.
enum State { UNEXPLORED, EXPLORED, VISIBLE }
var map_min := -60.0
var map_max := 60.0
var cell_size := 1.0
var side := 120 # Row stride; retained for square-map callers.
var map_origin := Vector2(-60, -60)
var map_end := Vector2(60, 60)
var grid_size := Vector2i(120, 120)
var visible_now: Dictionary = {}
var explored: Dictionary = {}
var memories: Dictionary = {}
var source_counts: Dictionary = {}
var revision := 0
var elapsed_ms := 0.0
var ready := false
var dirty := false

func setup(minimum: float, maximum: float, size := 1.0) -> void:
	setup_rect(Vector2(minimum, minimum), Vector2(maximum, maximum), size)

func setup_rect(minimum: Vector2, maximum: Vector2, size := 1.0) -> void:
	map_origin = minimum
	map_end = maximum
	map_min = minimum.x
	map_max = maximum.x
	cell_size = maxf(size, 0.1)
	grid_size = Vector2i(maxi(1, ceili((maximum.x - minimum.x) / cell_size)), maxi(1, ceili((maximum.y - minimum.y) / cell_size)))
	side = grid_size.x
	reset()

func reset() -> void:
	for team in Enums.Team.values():
		var mask := PackedByteArray()
		mask.resize(grid_size.x * grid_size.y)
		mask.fill(0)
		visible_now[team] = mask.duplicate()
		explored[team] = mask.duplicate()
		memories[team] = {}
		source_counts[team] = 0
	ready = false
	dirty = true
	revision += 1

func cell_at(pos: Vector2) -> Vector2i:
	if pos.x < map_origin.x or pos.y < map_origin.y or pos.x > map_end.x or pos.y > map_end.y:
		return Vector2i(-1, -1)
	return Vector2i(clampi(floori((pos.x-map_origin.x)/cell_size), 0, side-1),
		clampi(floori((pos.y-map_origin.y)/cell_size), 0, grid_size.y-1))

func state_at(team: int, pos: Vector2) -> int:
	var cell := cell_at(pos)
	if cell.x < 0 or not explored.has(team):
		return State.UNEXPLORED
	var index := cell.y * side + cell.x
	if visible_now[team][index] != 0:
		return State.VISIBLE
	return State.EXPLORED if explored[team][index] != 0 else State.UNEXPLORED

func footprint_visible(team: int, pos: Vector2, footprint: Vector2, require_all := false) -> bool:
	var half := footprint * 0.5
	var lo := cell_at(pos - half)
	# Right/bottom edges are exclusive except a point-sized query.
	var hi := cell_at(pos + (half - Vector2.ONE * 0.00001).max(Vector2.ZERO))
	if lo.x < 0 or hi.x < 0 or not visible_now.has(team):
		return false
	var mask: PackedByteArray = visible_now[team]
	for y in range(lo.y, hi.y+1):
		for x in range(lo.x, hi.x+1):
			var seen := mask[y*side+x] != 0
			if require_all and not seen:
				return false
			if not require_all and seen:
				return true
	return require_all

static func footprint_of(entity: Object) -> Vector2:
	var definition: Variant = entity.get("def")
	if definition is BuildingDef:
		return definition.footprint
	if entity.get("block_size") is Vector2:
		return entity.get("block_size")
	if entity.has_method("extract"):
		return entity.call("selection_footprint", entity.get("resource_type"))
	return Vector2.ZERO

func can_see(team: int, entity: Object) -> bool:
	if not is_instance_valid(entity) or entity.get("sim_pos") == null:
		return false
	if entity.get("is_placement_ghost") == true:
		return entity.get("team") == team
	if entity.get("team") == team and entity.get("hp") != null and float(entity.get("hp")) > 0:
		return true
	return ready and footprint_visible(team, entity.get("sim_pos"), footprint_of(entity))

static func radius_of(entity: Object) -> float:
	if entity.has_method("resolved_vision_radius"):
		return entity.call("resolved_vision_radius")
	var definition: Variant = entity.get("def")
	if definition is BuildingDef:
		return definition.vision_radius if entity.get("is_complete") else definition.construction_vision_radius
	return 0.0

func rebuild(entities: Array) -> void:
	var started := Time.get_ticks_usec()
	var changed := not ready
	for team in Enums.Team.values():
		var mask := PackedByteArray()
		mask.resize(grid_size.x * grid_size.y)
		mask.fill(0)
		var row_min := PackedInt32Array()
		var row_max := PackedInt32Array()
		row_min.resize(grid_size.y)
		row_max.resize(grid_size.y)
		row_min.fill(side)
		row_max.fill(-1)
		var count := 0
		for entity in entities:
			if not is_instance_valid(entity) or entity.get("team") != team:
				continue
			if entity.get("is_placement_ghost") == true or entity.get("hp") == null or float(entity.get("hp")) <= 0:
				continue
			var radius := radius_of(entity)
			if radius <= 0:
				continue
			count += 1
			_stamp(mask, entity.get("sim_pos"), radius, row_min, row_max)
		changed = changed or visible_now[team] != mask
		visible_now[team] = mask
		var history: PackedByteArray = explored[team]
		for i in mask.size():
			if mask[i] != 0:
				history[i] = 255
		explored[team] = history
		source_counts[team] = count
	ready = true
	dirty = false
	if changed:
		revision += 1
	elapsed_ms = float(Time.get_ticks_usec() - started) / 1000.0

func _stamp(mask: PackedByteArray, pos: Vector2, radius: float, row_min: PackedInt32Array, row_max: PackedInt32Array) -> void:
	var y0 := maxi(0, floori((pos.y-radius-map_origin.y)/cell_size))
	var y1 := mini(grid_size.y-1, floori((pos.y+radius-map_origin.y)/cell_size))
	for y in range(y0, y1+1):
		var dy := map_origin.y + (y+0.5)*cell_size - pos.y
		var remaining := radius*radius-dy*dy
		if remaining < 0:
			continue
		var dx := sqrt(remaining)
		var x0 := maxi(0, ceili((pos.x-dx-map_origin.x)/cell_size-0.5))
		var x1 := mini(side-1, floori((pos.x+dx-map_origin.x)/cell_size-0.5))
		# Track a guaranteed continuous covered run per row. Overlapping circles
		# only write its exposed ends; disjoint runs never fill gaps accidentally.
		var lo := row_min[y]
		var hi := row_max[y]
		if x0 <= hi + 1 and x1 >= lo - 1:
			for x in range(x0, mini(lo, x1+1)):
				mask[y*side+x] = 255
			for x in range(maxi(hi+1, x0), x1+1):
				mask[y*side+x] = 255
			row_min[y] = mini(x0,lo)
			row_max[y] = maxi(x1,hi)
		else:
			for x in range(x0, x1+1):
				mask[y*side+x] = 255
			if x1-x0 > hi-lo:
				row_min[y] = x0
				row_max[y] = x1

func mask_image(team: int) -> Image:
	var pixels := PackedByteArray()
	pixels.resize(grid_size.x * grid_size.y * 2)
	var current: PackedByteArray = visible_now[team]
	var history: PackedByteArray = explored[team]
	for i in current.size():
		pixels[2*i] = current[i]
		pixels[2*i+1] = history[i]
	return Image.create_from_data(grid_size.x, grid_size.y, false, Image.FORMAT_RG8, pixels)
