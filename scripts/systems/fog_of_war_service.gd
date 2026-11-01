class_name FogOfWarService
extends RefCounted
const Fixed := preload("res://scripts/core/sim_fixed.gd")

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
var _static_sources: Dictionary = {}
var _static_masks: Dictionary = {}
var _static_rows: Dictionary = {}
## The FogOfWarHolder showing this fog, if any (cached_static_seen()).
var static_cache: Object = null
## Native circle stamping and exploration (aoe_sim GDExtension). Integer
## results identical to _stamp() and the script loops below.
static var _kernel: RefCounted = ClassDB.instantiate("AoeSimKernel") if ClassDB.class_exists("AoeSimKernel") and ClassDB.class_has_method("AoeSimKernel", "fog_stamp") else null

func setup(minimum: float, maximum: float, size := 1.0) -> void:
	setup_rect(Vector2(minimum, minimum), Vector2(maximum, maximum), size)

func setup_rect(minimum: Vector2, maximum: Vector2, size := 1.0) -> void:
	map_origin = Fixed.quantize_vector(minimum)
	map_end = Fixed.quantize_vector(maximum)
	map_min = map_origin.x
	map_max = map_end.x
	var size_q := maxi(Fixed.coord(0.1), Fixed.coord(size))
	cell_size = Fixed.to_float(size_q)
	var extent := Fixed.vector(map_end) - Fixed.vector(map_origin)
	grid_size = Vector2i(maxi(1, Fixed.ceil_div(extent.x, size_q)), maxi(1, Fixed.ceil_div(extent.y, size_q)))
	side = grid_size.x
	reset()

func reset() -> void:
	_static_sources.clear()
	_static_masks.clear()
	_static_rows.clear()
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
	var point := Fixed.vector(pos)
	var origin := Fixed.vector(map_origin)
	var end := Fixed.vector(map_end)
	if point.x < origin.x or point.y < origin.y or point.x > end.x or point.y > end.y:
		return Vector2i(-1, -1)
	var size := maxi(1, Fixed.coord(cell_size))
	return Vector2i(clampi(Fixed.floor_div(point.x - origin.x, size), 0, side-1),
		clampi(Fixed.floor_div(point.y - origin.y, size), 0, grid_size.y-1))

func state_at(team: int, pos: Vector2) -> int:
	var cell := cell_at(pos)
	if cell.x < 0 or not explored.has(team):
		return State.UNEXPLORED
	var index := cell.y * side + cell.x
	if visible_now[team][index] != 0:
		return State.VISIBLE
	return State.EXPLORED if explored[team][index] != 0 else State.UNEXPLORED

func footprint_visible(team: int, pos: Vector2, footprint: Vector2, require_all := false) -> bool:
	return rect_visible(team, footprint_cells(pos, footprint), require_all)

## footprint_visible(team, point, footprint, true) for many points sharing one
## footprint: 1 where every covered cell is visible now, else 0. Same cell
## rectangle as footprint_cells (cell_at of both corners on the fixed-point
## lattice, exclusive right/bottom edges) and the same all-cells test as
## rect_visible, without the per-point calls; planning grids test thousands of
## obstacle cells at once.
@warning_ignore("integer_division")
func footprints_fully_visible(team: int, points: PackedVector2Array, footprint: Vector2) -> PackedByteArray:
	var result := PackedByteArray()
	result.resize(points.size())
	result.fill(0)
	if not visible_now.has(team): return result
	var mask: PackedByteArray = visible_now[team]
	var origin := Fixed.vector(map_origin)
	var end := Fixed.vector(map_end)
	var size := maxi(1, Fixed.coord(cell_size))
	var half := Fixed.vector(footprint * 0.5)
	var far := (half - Vector2i.ONE).max(Vector2i.ZERO)
	var last_x := side - 1
	var last_y := grid_size.y - 1
	for index in points.size():
		var point := Fixed.vector(points[index])
		var low := point - half
		var high := point + far
		if low.x < origin.x or low.y < origin.y or low.x > end.x or low.y > end.y: continue
		if high.x < origin.x or high.y < origin.y or high.x > end.x or high.y > end.y: continue
		# Both corners lie inside the map, so the offsets are non-negative and
		# integer division equals Fixed.floor_div.
		var x0 := mini((low.x - origin.x) / size, last_x)
		var y0 := mini((low.y - origin.y) / size, last_y)
		var x1 := mini((high.x - origin.x) / size, last_x)
		var y1 := mini((high.y - origin.y) / size, last_y)
		var visible := true
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				if mask[y * side + x] == 0:
					visible = false
					break
			if not visible: break
		if visible: result[index] = 1
	return result

## Static entities reuse this cell rectangle instead of converting their world
## footprint separately for both teams on every visibility / memory pass.
func footprint_cells(pos: Vector2, footprint: Vector2) -> Rect2i:
	var point := Fixed.vector(pos)
	var half := Fixed.vector(footprint * 0.5)
	var lo := cell_at(Fixed.to_vector(point - half))
	# Right/bottom edges are exclusive except a point-sized query.
	var hi := cell_at(Fixed.to_vector(point + (half - Vector2i.ONE).max(Vector2i.ZERO)))
	if lo.x < 0 or hi.x < 0:
		return Rect2i(-1, -1, 0, 0)
	return Rect2i(lo, hi - lo + Vector2i.ONE)

func rect_visible(team: int, cells: Rect2i, require_all := false) -> bool:
	if cells.position.x < 0 or cells.size.x <= 0 or cells.size.y <= 0 or not visible_now.has(team):
		return false
	var mask: PackedByteArray = visible_now[team]
	# Trees and ore usually cover at most two rows/columns. Avoid constructing
	# nested ranges for the thousands of identical tiny queries each fog refresh.
	if cells.size.x <= 2 and cells.size.y <= 2:
		var first := cells.position.y * side + cells.position.x
		var last_row := (cells.end.y - 1) * side + cells.position.x
		var right := cells.size.x - 1
		if require_all:
			return mask[first] != 0 and mask[first + right] != 0 and mask[last_row] != 0 and mask[last_row + right] != 0
		return mask[first] != 0 or mask[first + right] != 0 or mask[last_row] != 0 or mask[last_row + right] != 0
	for y in range(cells.position.y, cells.end.y):
		for x in range(cells.position.x, cells.end.x):
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
	if not ready: return false
	# Trees, mines and buildings: the holder's per-revision record answers
	# with the same cells; anything changed or uncached takes the live test.
	if static_cache != null and is_instance_valid(static_cache):
		var cached: int = static_cache.cached_static_seen(team, entity)
		if cached >= 0: return cached == 1
	return footprint_visible(team, entity.get("sim_pos"), footprint_of(entity))

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
	# A completed wall ring contributes hundreds of stationary circles. Cache
	# their union; moving units still stamp their exact position each refresh.
	# Use value signatures so moves, upgrades, deaths and team changes invalidate
	# immediately, including callers that directly mutate simulation fields.
	var stationary := {0: [], 1: []}
	# Moving sources as fixed-point [x, y, radius] triples, the values _stamp() uses.
	var moving := {0: PackedInt64Array(), 1: PackedInt64Array()}
	var moving_counts := {0: 0, 1: 0}
	for entity in entities:
		if not is_instance_valid(entity): continue
		if entity is UnitAgent:
			# Typed reads of the same values as the generic path below.
			var unit: UnitAgent = entity
			if unit.team != Enums.Team.PLAYER and unit.team != Enums.Team.AI: continue
			if unit.hp_q <= 0: continue
			var unit_radius := unit.resolved_vision_radius()
			if unit_radius <= 0: continue
			moving[unit.team].append_array([unit._sim_pos_q.x, unit._sim_pos_q.y, maxi(0, Fixed.coord(unit_radius))])
			moving_counts[unit.team] += 1
			continue
		var team: Variant = entity.get("team")
		if not stationary.has(team): continue
		if entity.get("is_placement_ghost") == true or entity.get("hp") == null or float(entity.get("hp")) <= 0: continue
		var radius := radius_of(entity)
		if radius <= 0: continue
		if entity.get("def") is BuildingDef:
			stationary[team].append([entity.get("sim_pos"), radius])
		else:
			var point := Fixed.vector(entity.get("sim_pos"))
			moving[team].append_array([point.x, point.y, maxi(0, Fixed.coord(radius))])
			moving_counts[team] += 1
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
		if not _static_sources.has(team) or _static_sources[team] != stationary[team]:
			var sources := PackedInt64Array()
			for source in stationary[team]:
				var point := Fixed.vector(source[0])
				sources.append_array([point.x, point.y, maxi(0, Fixed.coord(source[1]))])
			var stamped := _stamp_all(mask, row_min, row_max, sources)
			mask = stamped[0]
			row_min = stamped[1]
			row_max = stamped[2]
			_static_sources[team] = stationary[team]
			_static_masks[team] = mask.duplicate()
			_static_rows[team] = [row_min.duplicate(), row_max.duplicate()]
		else:
			mask = _static_masks[team].duplicate()
			row_min = _static_rows[team][0].duplicate()
			row_max = _static_rows[team][1].duplicate()
		mask = _stamp_all(mask, row_min, row_max, moving[team])[0]
		changed = changed or visible_now[team] != mask
		visible_now[team] = mask
		var history: PackedByteArray = explored[team]
		if _kernel != null:
			history = _kernel.fog_explore(history, mask)
		else:
			for i in mask.size():
				if mask[i] != 0:
					history[i] = 255
		explored[team] = history
		source_counts[team] = stationary[team].size() + int(moving_counts[team])
	ready = true
	dirty = false
	if changed:
		revision += 1
	elapsed_ms = float(Time.get_ticks_usec() - started) / 1000.0

## _stamp_q() for every [x, y, radius] triple in order; [mask, row_min, row_max].
func _stamp_all(mask: PackedByteArray, row_min: PackedInt32Array, row_max: PackedInt32Array, sources: PackedInt64Array) -> Array:
	if sources.is_empty(): return [mask, row_min, row_max]
	if _kernel != null:
		return _kernel.fog_stamp(mask, row_min, row_max, sources, Fixed.vector(map_origin), maxi(1, Fixed.coord(cell_size)), side, grid_size.y)
	for index in range(0, sources.size(), 3):
		_stamp_q(mask, Vector2i(sources[index], sources[index + 1]), sources[index + 2], row_min, row_max)
	return [mask, row_min, row_max]

func _stamp(mask: PackedByteArray, pos: Vector2, radius: float, row_min: PackedInt32Array, row_max: PackedInt32Array) -> void:
	_stamp_q(mask, Fixed.vector(pos), maxi(0, Fixed.coord(radius)), row_min, row_max)

## Native twin: AoeSimKernel.fog_stamp (native/aoe_sim/src/sim_kernel.cpp).
func _stamp_q(mask: PackedByteArray, point: Vector2i, radius_q: int, row_min: PackedInt32Array, row_max: PackedInt32Array) -> void:
	var origin := Fixed.vector(map_origin)
	var size := maxi(1, Fixed.coord(cell_size))
	var y0 := maxi(0, Fixed.floor_div(point.y - radius_q - origin.y, size))
	var y1 := mini(grid_size.y-1, Fixed.floor_div(point.y + radius_q - origin.y, size))
	# Double the lattice to represent cell centers exactly, even for odd sizes.
	var diameter: int = 2 * radius_q
	for y in range(y0, y1+1):
		var dy: int = 2 * int(origin.y) + (2*y + 1)*size - 2 * int(point.y)
		var remaining: int = diameter*diameter-dy*dy
		if remaining < 0:
			continue
		var dx := Fixed.isqrt(remaining)
		var x0 := maxi(0, Fixed.ceil_div(2 * int(point.x) - dx - 2 * int(origin.x) - size, 2*size))
		var x1 := mini(side-1, Fixed.floor_div(2 * int(point.x) + dx - 2 * int(origin.x) - size, 2*size))
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
