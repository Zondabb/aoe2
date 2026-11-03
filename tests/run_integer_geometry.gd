extends SceneTree

const Fixed := preload("res://scripts/core/sim_fixed.gd")
const Collision := preload("res://scripts/systems/collision_resolver.gd")
const Wall := preload("res://scripts/systems/wall_system.gd")
const Fog := preload("res://scripts/systems/fog_of_war_service.gd")
const Spatial := preload("res://scripts/systems/spatial_hash.gd")
const Grid := preload("res://scripts/systems/nav_grid_service.gd")

class Body extends RefCounted:
	var sim_pos := Vector2.ZERO

var checks := 0
var failures := 0

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(label)

func _initialize() -> void:
	_test_cells_and_radius()
	_test_sweeps()
	_test_wall_axes()
	_test_fog_lattice()
	_test_integer_path_costs()
	print("INTEGER GEOMETRY: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _test_integer_path_costs() -> void:
	var grid := Grid.new()
	grid.setup(-6, 6, 1.0)
	check(grid._grid._compute_cost(Vector2i.ZERO, Vector2i(1, 0)) == 10, "cardinal path cost is an exact integer")
	check(grid._grid._compute_cost(Vector2i.ZERO, Vector2i(1, 1)) == 14, "diagonal path cost avoids square root")
	check(grid._grid._estimate_cost(Vector2i(-3, -4), Vector2i(2, 3)) == 90, "octile lower bound is integer across negative cells")
	grid._grid.set_point_solid(Vector2i.ZERO, true)
	var first: Array = grid._grid.get_id_path(Vector2i(-4, 0), Vector2i(4, 0))
	var total := 0
	for i in range(1, first.size()):
		total += int(grid._grid._compute_cost(first[i - 1], first[i]))
	check(total == 88 and not first.has(Vector2i.ZERO), "integer grid selects minimal 88-cost detour around one blocked cell")
	check(first == grid._grid.get_id_path(Vector2i(-4, 0), Vector2i(4, 0)), "equal-cost path tie order is stable")
	var rng := RandomNumberGenerator.new()
	rng.seed = 91823
	for trial in 96:
		var size := 9
		var start := Vector2i(0, 0)
		var goal := Vector2i(size - 1, size - 1)
		grid.setup(0, size)
		for y in size:
			for x in size:
				var p := Vector2i(x, y)
				if p != start and p != goal and rng.randi_range(0, 99) < 29: grid._grid.set_point_solid(p, true)
		var route: Array[Vector2i] = grid._grid.get_id_path(start, goal)
		var cost := 0 if not route.is_empty() else -1
		var safe := true
		for i in range(1, route.size()):
			var p := route[i - 1]
			var direction := (route[i] - p).sign()
			while p != route[i]:
				if not _can_step(grid._grid, p, direction):
					safe = false
					break
				p += direction
				cost += 14 if direction.x != 0 and direction.y != 0 else 10
		check(safe and cost == _shortest_cost(grid._grid, start, goal), "jumped path avoids closed corners and has minimal cost on map %d" % trial)

func _can_step(grid: AStarGrid2D, at: Vector2i, direction: Vector2i) -> bool:
	var next := at + direction
	if not grid.region.has_point(next) or grid.is_point_solid(next): return false
	if direction.x == 0 or direction.y == 0: return true
	return not grid.is_point_solid(at + Vector2i(direction.x, 0)) and not grid.is_point_solid(at + Vector2i(0, direction.y))

## Independent Dijkstra reference for small grids. Use adjacent steps only.
func _shortest_cost(grid: AStarGrid2D, start: Vector2i, goal: Vector2i) -> int:
	var best: Dictionary = {start: 0}
	var pending: Dictionary = {start: 0}
	while not pending.is_empty():
		var at: Vector2i = pending.keys()[0]
		for other: Vector2i in pending:
			if pending[other] < pending[at]: at = other
		var cost: int = pending[at]
		if at == goal: return cost
		pending.erase(at)
		for y in range(-1, 2):
			for x in range(-1, 2):
				var direction := Vector2i(x, y)
				if direction == Vector2i.ZERO or not _can_step(grid, at, direction): continue
				var next := at + direction
				var next_cost := cost + (14 if x != 0 and y != 0 else 10)
				if next_cost < int(best.get(next, 2147483647)):
					best[next] = next_cost
					pending[next] = next_cost
	return -1

func _test_cells_and_radius() -> void:
	check(Fixed.floor_div(-1, 1024) == -1 and Fixed.ceil_div(-1, 1024) == 0, "negative fractional cell floors away from zero")
	check(Fixed.floor_div(-1024, 1024) == -1 and Fixed.ceil_div(-1024, 1024) == -1, "negative exact cell edge")
	check(Fixed.floor_div(1025, 1024) == 1 and Fixed.ceil_div(1025, 1024) == 2, "positive fractional cell")
	check(Fixed.length_sq(Vector2i(500000, -500000)) == 500000000000, "map-scale squared distances promote beyond int32")
	var hash := Spatial.new()
	hash.setup(1.0)
	var grid := Grid.new()
	grid.setup(-240, 240, 1.0)
	for point in [Vector2(-0.0009765625, -1.0), Vector2(-240, 239.9990234375), Vector2(0, 0)]:
		check(hash.world_to_cell(point) == Vector2i(floori(point.x), floori(point.y)), "spatial negative coordinate indexing")
		check(grid.world_to_cell(point) == hash.world_to_cell(point), "navigation and spatial cells agree")
	var edge := Body.new()
	var outside := Body.new()
	edge.sim_pos = Vector2(-3, -4)
	outside.sim_pos = Vector2(-3, -4.0009765625)
	hash.insert(edge, edge.sim_pos)
	hash.insert(outside, outside.sim_pos)
	var selected := hash.query_radius(Vector2.ZERO, 5.0)
	check(selected.has(edge) and not selected.has(outside), "exact radius edge includes tangent and excludes one quantum outside")

func _test_sweeps() -> void:
	var half := Vector2.ONE
	check(Collision.segment_hits_box(Vector2(-5, 0), Vector2(5, 0), half), "horizontal crossing")
	check(Collision.segment_hits_box(Vector2(5, 0), Vector2(-5, 0), half), "reverse crossing")
	check(Collision.segment_hits_box(Vector2(0, -5), Vector2(0, 5), half), "vertical crossing")
	check(not Collision.segment_hits_box(Vector2(-5, 1), Vector2(5, 1), half), "tangential boundary movement is permitted")
	check(not Collision.segment_hits_box(Vector2(-5, -1), Vector2(5, -1), half), "negative tangential boundary movement is permitted")
	check(Collision.segment_hits_box(Vector2(-5, 1.0 - 2.0 / 1024.0), Vector2(5, 1.0 - 2.0 / 1024.0), half), "two quanta inside boundary is blocked")
	check(not Collision.segment_hits_box(Vector2(-5, 0), Vector2(-2, 0), half), "box beyond endpoint does not collide")
	check(not Collision.segment_hits_box(Vector2(2, 0), Vector2(5, 0), half), "box behind origin does not collide")
	check(Collision.segment_hits_box(Vector2(-480, -480), Vector2(480, 480), half), "full-map diagonal sweep remains within int64")
	check(not Collision.segment_hits_box(Vector2(0.9, 0), Vector2(2, 0), half), "embedded body can leave nearest face")
	check(Collision.segment_hits_box(Vector2(0.9, 0), Vector2(0.1, 0), half), "embedded body cannot move deeper")

func _test_wall_axes() -> void:
	var directions := [Vector2i(8, 0), Vector2i(8, 8), Vector2i(0, 8), Vector2i(-8, 8), Vector2i(-8, 0), Vector2i(-8, -8), Vector2i(0, -8), Vector2i(8, -8)]
	for axis in directions.size():
		check(Wall._integer_axis(directions[axis]) == axis, "wall integer octant %d" % axis)
	check(Wall._integer_axis(Vector2i(12, 4)) == 0, "wall just below diagonal sector")
	check(Wall._integer_axis(Vector2i(12, 5)) == 1, "wall just above diagonal sector")
	check(Wall._integer_axis(Vector2i(-12, -4)) == 4, "negative wall sector symmetry")
	check(Wall._integer_axis(Vector2i(-12, -5)) == 5, "negative diagonal sector symmetry")

func _test_fog_lattice() -> void:
	# Independent per-cell squared-distance oracle: no production row spans,
	# square root, division helper or source cache are used to derive coverage.
	var fog := Fog.new()
	for size in [0.5, 0.7509765625, 1.0]:
		fog.setup_rect(Vector2(-4, -3), Vector2(5, 4), size)
		for point in [Vector2(-1.5, -0.5), Vector2(0, 0), Vector2(1.0 / 1024.0, -1.0 / 1024.0)]:
			for radius in [0.5, 1.0, 2.5]:
				var mask := PackedByteArray()
				mask.resize(fog.grid_size.x * fog.grid_size.y)
				mask.fill(0)
				var lo := PackedInt32Array()
				var hi := PackedInt32Array()
				lo.resize(fog.grid_size.y)
				hi.resize(fog.grid_size.y)
				lo.fill(fog.grid_size.x)
				hi.fill(-1)
				fog._stamp(mask, point, radius, lo, hi)
				var matches := true
				for y in fog.grid_size.y:
					for x in fog.grid_size.x:
						var dx: float = fog.map_origin.x + (x + 0.5) * fog.cell_size - point.x
						var dy: float = fog.map_origin.y + (y + 0.5) * fog.cell_size - point.y
						var expected: bool = dx * dx + dy * dy <= radius * radius
						if (mask[y * fog.grid_size.x + x] != 0) != expected: matches = false
				check(matches, "integer fog agrees with cell-center geometry including odd quantum cell size")
