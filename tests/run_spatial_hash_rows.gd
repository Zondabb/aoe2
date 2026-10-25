extends SceneTree
## Ordered radius-query equivalence against the original rectangular scan,
## including row lifecycle and invalid objects removed during a query.
const Hash := preload("res://scripts/systems/spatial_hash.gd")

class Body extends Node2D:
	var sim_pos: Variant = Vector2.ZERO

class Reference extends RefCounted:
	var cell_size := 2.0
	var buckets := {}
	var cells := {}
	func cell_at(pos: Vector2) -> Vector2i:
		return Vector2i(floori(pos.x / cell_size), floori(pos.y / cell_size))
	func clear() -> void:
		buckets.clear()
		cells.clear()
	func insert(value: Object, pos: Vector2) -> void:
		if not is_instance_valid(value): return
		var id := value.get_instance_id()
		if cells.has(id):
			move(value, pos)
			return
		var cell := cell_at(pos)
		cells[id] = cell
		if not buckets.has(cell): buckets[cell] = []
		buckets[cell].append(value)
	func move(value: Object, pos: Vector2) -> void:
		if not is_instance_valid(value): return
		var id := value.get_instance_id()
		if not cells.has(id):
			insert(value, pos)
			return
		var cell := cell_at(pos)
		if cells[id] == cell: return
		remove(value)
		insert(value, pos)
	func remove(value: Object) -> void:
		if value == null: return
		var id := value.get_instance_id()
		if not cells.has(id): return
		var cell: Vector2i = cells[id]
		cells.erase(id)
		buckets[cell].erase(value)
		if buckets[cell].is_empty(): buckets.erase(cell)
	func query_radius(center: Vector2, radius: float) -> Array:
		var result: Array = []
		if radius < 0: return result
		var radius_sq := radius * radius
		var minimum := cell_at(center - Vector2.ONE * radius)
		var maximum := cell_at(center + Vector2.ONE * radius)
		for cy in range(minimum.y, maximum.y + 1):
			for cx in range(minimum.x, maximum.x + 1):
				var cell := Vector2i(cx, cy)
				if not buckets.has(cell): continue
				var bucket: Array = buckets[cell]
				var write := 0
				for index in bucket.size():
					var candidate: Variant = bucket[index]
					if not is_instance_valid(candidate): continue
					var value := candidate as Object
					bucket[write] = value
					write += 1
					var pos: Variant = value.get("sim_pos")
					if pos is Vector2 and center.distance_squared_to(pos) <= radius_sq: result.append(value)
				if write < bucket.size():
					bucket.resize(write)
					if write == 0: buckets.erase(cell)
		return result

var checks := 0
var failures := 0
var rng := RandomNumberGenerator.new()
var hash := Hash.new()
var reference := Reference.new()
var bodies: Array[Body] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)

func add_body(pos: Vector2) -> Body:
	var value := Body.new()
	value.sim_pos = pos
	bodies.append(value)
	hash.insert(value, pos)
	reference.insert(value, pos)
	return value

func check_rows(label: String) -> void:
	var expected := {}
	for cell: Vector2i in hash._buckets:
		if not expected.has(cell.y): expected[cell.y] = PackedInt32Array()
		var columns: PackedInt32Array = expected[cell.y]
		columns.append(cell.x)
		expected[cell.y] = columns
	for row in expected:
		var columns: PackedInt32Array = expected[row]
		columns.sort()
		expected[row] = columns
	check(hash._row_columns == expected, "%s: occupied rows match exact sorted nonempty buckets" % label)
	check(hash._buckets == reference.buckets, "%s: buckets match original index" % label)

func compare(center: Vector2, radius: float, label: String) -> void:
	check(hash.query_radius(center, radius) == reference.query_radius(center, radius), "%s: identical ordered query" % label)
	check_rows(label)

func clear_bodies() -> void:
	hash.clear()
	reference.clear()
	for value in bodies:
		if is_instance_valid(value): value.free()
	bodies.clear()

func _initialize() -> void:
	rng.seed = 280641
	_test_lifecycle()
	_test_randomized()
	if "--benchmark" in OS.get_cmdline_user_args(): _benchmark()
	clear_bodies()
	print("SPATIAL HASH ROWS: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _test_lifecycle() -> void:
	hash.setup(2)
	for x in [14.0, -10.0, 0.0, -2.0, 8.0, -18.0, 4.0]: add_body(Vector2(x, -3))
	add_body(Vector2(0.4, -3.5))
	compare(Vector2(0, -3), 40, "unordered insertion preserves cx and same-bucket order")
	for radius in [-1.0, 0.0, 2.0, 10.0]: compare(Vector2(0, -3), radius, "radius %s" % radius)
	var moving := bodies[0]
	moving.sim_pos = Vector2(-15, 5)
	hash.move(moving, moving.sim_pos)
	reference.move(moving, moving.sim_pos)
	compare(Vector2.ZERO, 40, "move creates new row and removes old column")
	hash.insert(moving, moving.sim_pos)
	reference.insert(moving, moving.sim_pos)
	compare(Vector2.ZERO, 40, "duplicate insertion keeps order")
	for index in range(1, bodies.size()):
		hash.remove(bodies[index])
		reference.remove(bodies[index])
	compare(Vector2.ZERO, 40, "remove last member removes complete row")
	hash.remove(moving)
	reference.remove(moving)
	check(hash._row_columns.is_empty(), "remove last bucket clears every row")
	for pos in [Vector2(-6, 0), Vector2(-2, 0), Vector2(2, 0), Vector2(6, 0), Vector2(0, 4)]:
		add_body(pos).free()
	var survivor := add_body(Vector2(10, 0))
	# Freed neighbouring columns must not shift the iterator past this survivor.
	compare(Vector2.ZERO, 20, "freed objects prune adjacent columns and an empty row")
	check(hash._row_columns.keys() == [0] and hash._row_columns[0] == PackedInt32Array([5]), "invalid-only buckets leave just the survivor column")
	var cell := hash.world_to_cell(survivor.sim_pos)
	hash._buckets[cell].append(null)
	reference.buckets[cell].append(null)
	compare(Vector2.ZERO, 20, "null alongside a living object preserves bucket order")
	survivor.sim_pos = "no position"
	compare(Vector2.ZERO, 20, "non-vector position excluded without deleting living object")
	survivor.sim_pos = Vector2(10, 0)
	survivor.free()
	compare(Vector2.ZERO, 20, "last freed object removes last occupied row")
	check(hash._row_columns.is_empty(), "no stale row columns after invalid cleanup")
	add_body(Vector2(-4, 0))
	compare(Vector2.ZERO, 10, "reinsert into a cleaned row")
	hash.setup(0.1)
	reference.clear()
	reference.cell_size = 0.25
	check(hash._row_columns.is_empty() and hash._buckets.is_empty() and hash.entity_count() == 0, "setup clears rows, buckets and entity cells")
	clear_bodies()

func _test_randomized() -> void:
	for size in [0.5, 2.0, 8.0]:
		clear_bodies()
		hash.setup(size)
		reference.cell_size = size
		for index in 120: add_body(Vector2(rng.randf_range(-50, 50), rng.randf_range(-35, 35)))
		for step in 180:
			var value: Body = bodies[rng.randi_range(0, bodies.size() - 1)]
			match step % 4:
				0, 1:
					value.sim_pos = Vector2(rng.randf_range(-50, 50), rng.randf_range(-35, 35))
					hash.move(value, value.sim_pos)
					reference.move(value, value.sim_pos)
				2:
					hash.remove(value)
					reference.remove(value)
				3:
					hash.insert(value, value.sim_pos)
					reference.insert(value, value.sim_pos)
			compare(Vector2(rng.randf_range(-50, 50), rng.randf_range(-35, 35)), rng.randf_range(0, 18), "cell %s step %d" % [size, step])

func _benchmark() -> void:
	for scenario in ["unit_cluster", "sparse_map", "dense_walls"]:
		clear_bodies()
		hash.setup(2)
		reference.cell_size = 2
		for index in 180:
			var pos := Vector2(rng.randf_range(-25, 25), rng.randf_range(-25, 25))
			if scenario == "sparse_map": pos *= 8
			add_body(pos)
		if scenario == "dense_walls":
			for y in range(-18, 19):
				for x in range(-18, 19): add_body(Vector2(x, y))
		var queries: Array[Vector2] = []
		for index in 180: queries.append(bodies[index].sim_pos)
		var before := 0
		var after := 0
		var checksum_before := 0
		var checksum_after := 0
		# Alternate implementations on the same immutable fixture and query list.
		for round_index in 6:
			var started := Time.get_ticks_usec()
			for pos in queries: checksum_before += reference.query_radius(pos, 10).size()
			var elapsed := Time.get_ticks_usec() - started
			if round_index > 0: before += elapsed
			started = Time.get_ticks_usec()
			for pos in queries: checksum_after += hash.query_radius(pos, 10).size()
			elapsed = Time.get_ticks_usec() - started
			if round_index > 0: after += elapsed
		check(checksum_before == checksum_after, "%s benchmark result checksum" % scenario)
		print("SPATIAL ROW BENCH ", JSON.stringify({"scenario": scenario, "queries": 900, "original_ms": before / 1000.0, "rows_ms": after / 1000.0, "speedup": float(before) / maxf(after, 1)}))
