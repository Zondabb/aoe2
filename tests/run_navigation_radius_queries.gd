extends SceneTree
## Mixed-unit clearance checks must not rewrite A* until a route needs it.
const Grid := preload("res://scripts/systems/nav_grid_service.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")

class CountingGrid extends Grid:
	var synchronizations := 0
	func _sync_grid_from_solid() -> void:
		synchronizations += 1
		super._sync_grid_from_solid()

class Box extends RefCounted:
	var sim_pos := Vector2.ZERO
	var block_half := Vector2(1, 4)

class Body extends RefCounted:
	var sim_pos := Vector2(-4, 0)
	var def: UnitDef = Catalog.get_unit("villager")

class SlowGrid extends Grid:
	func find_path_avoiding_units(from: Vector2, to: Vector2, _radius: float, _units: Array) -> PackedVector2Array:
		# A controlled slow search makes the queue budget test independent of
		# map complexity and machine speed.
		OS.delay_usec(Grid.PATH_TIME_BUDGET_USEC + 1000)
		return PackedVector2Array([from, to])

var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _run() -> void:
	var nav := CountingGrid.new()
	nav.setup(-20, 20)
	var box := Box.new()
	nav.rebuild_from_blockers([box])
	for iteration in 100:
		for radius in [0.35, 0.7, 1.3]:
			check(not nav.is_world_walkable_with_radius(Vector2.ZERO, radius), "wall blocks mixed-radius clearance")
			check(nav.is_world_walkable_with_radius(Vector2(-10, 0), radius), "open area stays walkable")
			check(nav.nearest_walkable_world(Vector2.ZERO, radius) != Vector2.ZERO, "embedded query finds escape")
	check(nav.synchronizations == 0, "clearance and placement queries never synchronize A*")
	var from := Vector2(-10, 0)
	var to := Vector2(10, 0)
	for radius in [0.35, 1.3, 0.7, 0.35]:
		var reference := Grid.new()
		reference.setup(-20, 20)
		reference.rebuild_from_blockers([box])
		var expected := reference.find_path(from, to, radius)
		var actual := nav.find_path(from, to, radius)
		check(not actual.is_empty() and actual == expected, "path matches fresh grid at radius %.2f" % radius)
	var syncs := nav.synchronizations
	for radius in [1.3, 0.7, 0.35, 1.3]:
		nav.is_segment_walkable(Vector2(-10, -8), Vector2(10, -8), radius)
		nav.find_path(from, to, radius)
	check(nav.synchronizations == syncs, "cached routes and segment checks do not synchronize A*")

	# The live A* layer can differ from the last queried clearance layer when
	# temporary crowd obstacles or explicit debug/map-editor marks are applied.
	var body := Body.new()
	for radius in [1.3, 0.35, 0.7]:
		nav.is_world_walkable_with_radius(from, 0.35 if radius > 0.35 else 1.3)
		var reference := Grid.new()
		reference.setup(-20, 20)
		reference.rebuild_from_blockers([box])
		var expected := reference.find_path_avoiding_units(from, to, radius, [body])
		check(nav.find_path_avoiding_units(from, to, radius, [body]) == expected, "temporary crowd marks use the requested radius %.2f" % radius)
		check(nav.find_path(from, to, radius) == reference.find_path(from, to, radius), "crowd marks are restored before a static route")

	nav.find_path(Vector2(-9, -8), Vector2(9, -8), 0.35)
	nav.is_world_walkable_with_radius(from, 1.3)
	nav.set_cell_solid(Vector2i(-5, -8), true)
	var reference := Grid.new()
	reference.setup(-20, 20)
	reference.rebuild_from_blockers([box])
	check(nav.find_path(Vector2(-9, -8), Vector2(9, -7), 0.35) == reference.find_path(Vector2(-9, -8), Vector2(9, -7), 0.35), "editing a different queried layer cannot leave a phantom A* blocker")
	box.sim_pos = Vector2(5, 0)
	nav.rebuild_from_blockers([box])
	reference.rebuild_from_blockers([box])
	check(nav.find_path(from, to, 1.3) == reference.find_path(from, to, 1.3), "geometry changes invalidate deferred grid contents")
	nav.clear_solids()
	check(not nav.find_path(from, to, 0.35).is_empty(), "clear_solids resets deferred grid contents")
	_test_unreachable_cache()
	_test_queue_budget()
	_test_line_probe_equivalence()
	print("NAVIGATION RADIUS QUERIES: %d checks, %d failures, %d A* synchronizations" % [checks, failures, nav.synchronizations])
	quit(0 if failures == 0 else 1)

func _test_unreachable_cache() -> void:
	var nav := Grid.new()
	nav.setup(-20, 20)
	var wall := Box.new()
	wall.block_half = Vector2(1, 30)
	nav.rebuild_from_blockers([wall])
	var from := Vector2(-10, 0)
	var to := Vector2(10, 0)
	check(nav.find_path(from, to).is_empty(), "full closed wall prevents crossing")
	check(nav._path_cache.size() == 1, "unreachable static route is cached")
	check(nav.find_path(from, to).is_empty(), "cached unreachable route stays blocked")
	wall.sim_pos = Vector2(100, 0)
	nav.rebuild_from_blockers([wall])
	check(not nav.find_path(from, to).is_empty(), "removing a wall invalidates cached failures and reopens route")

func _test_queue_budget() -> void:
	var nav := SlowGrid.new()
	nav.setup(-20, 20)
	for id in range(1, 7):
		nav.enqueue_path(id, Vector2(-10, id), Vector2(10, id))
	var delivered: Array = []
	for frame in 6:
		var result := nav.flush_pending_paths()
		check(result.size() == 1, "time-limited queue completes at least one slow route and yields the rest")
		delivered.append_array(result.keys())
	check(delivered == [1, 2, 3, 4, 5, 6], "deferred requests preserve FIFO and every later unit receives its route")
	check(nav.pending_count() == 0, "time budget eventually drains the queue")
	check(nav.flush_pending_paths().is_empty(), "completed requests do not repeat")

func _test_line_probe_equivalence() -> void:
	var nav := Grid.new()
	nav.setup_rect(Vector2i(-31, -17), Vector2i(37, 23), 0.75)
	var random := RandomNumberGenerator.new()
	random.seed = 623088
	for index in 160:
		nav.set_cell_solid(Vector2i(random.randi_range(-31, 36), random.randi_range(-17, 22)), true)
	for scenario in 1200:
		var from := Vector2(random.randf_range(-25, 30), random.randf_range(-15, 20))
		var to := Vector2(random.randf_range(-25, 30), random.randf_range(-15, 20))
		if scenario % 8 == 0: from = from.round() * 0.75
		if scenario % 9 == 0: to = from + Vector2.ONE * 0.0001
		check(nav._line_clear(from, to) == _reference_line_clear(nav, from, to), "inline visibility samples match original bounds/solid queries at scenario %d" % scenario)

func _reference_line_clear(nav: NavGridService, from: Vector2, to: Vector2) -> bool:
	var distance := from.distance_to(to)
	if distance < 0.001: return not nav.is_world_solid(from)
	var steps := maxi(2, int(ceil(distance / (nav.cell_size * 0.35))))
	for sample in range(0, steps + 1):
		var point := from.lerp(to, float(sample) / float(steps))
		if nav.is_world_solid(point): return false
	return true
