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
	print("INTEGER GEOMETRY: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

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
