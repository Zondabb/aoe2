extends SceneTree
## The aoe_sim GDExtension must be bit-identical to the GDScript reference, so
## peers with and without it (web export, missing library) never desync.
## Randomized sequences drive both unit fields with the same updates and
## compare every steering destination, every scheduled-cache state and every
## neighbour set, including clamped/edge inputs; the native waypoint sampler is
## compared with the script loop on the default map's navigation layers.
const Avoidance := preload("res://scripts/systems/local_avoidance.gd")
const Field := preload("res://scripts/systems/unit_field.gd")
const Fixed := preload("res://scripts/core/sim_fixed.gd")

var checks := 0
var failures := 0
var rng := RandomNumberGenerator.new()

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		if failures < 12: push_error("NATIVE EQUIVALENCE: " + message)

func _run() -> void:
	if not Field.native_available():
		print("NATIVE EQUIVALENCE SKIPPED: aoe_sim extension not loaded")
		quit(0)
		return
	rng.seed = 20261031
	var steers := 0
	var solved := 0
	var reused := 0
	for scenario in 160:
		var counts := _scenario(scenario)
		steers += counts[0]
		solved += counts[1]
		reused += counts[2]
	var samples := await _line_samples()
	print("NATIVE EQUIVALENCE: %d checks, %d failures; %d steering calls (%d solves, %d reuses), %d waypoint probes" % [checks, failures, steers, solved, reused, samples])
	quit(0 if failures == 0 else 1)

func _pick(values: Array) -> Variant:
	return values[rng.randi_range(0, values.size() - 1)]

func _velocity(scale: int) -> Vector2i:
	match rng.randi_range(0, 9):
		0: return Vector2i.ZERO
		1: return Vector2i(rng.randi_range(-20000, 20000), rng.randi_range(-20000, 20000)) # beyond clamps
		2: return Vector2i(rng.randi_range(-3, 3), rng.randi_range(-3, 3))
	return Vector2i(rng.randi_range(-scale, scale), rng.randi_range(-scale, scale))

func _scenario(index: int) -> Array:
	var script_field := Field.new()
	var native_field: RefCounted = ClassDB.instantiate("AoeUnitField")
	var spread: int = _pick([1500, 4000, 12000, 40000])
	var origin := Vector2i(rng.randi_range(-200000, 200000), rng.randi_range(-200000, 200000))
	# Out-of-range inputs exercise the shared clamps (POS_MAX = 2^24).
	var extreme := index % 10 == 9
	if extreme: origin = Vector2i(_pick([-1, 1]) * ((1 << 24) - spread / 2), _pick([-1, 1]) * ((1 << 24) + 5000))
	var count := rng.randi_range(1, 48)
	var keys: Array[int] = []
	var positions := {}
	var velocities := {}
	var radii := {}
	var caches_script := {}
	var caches_native := {}
	var goals := {}
	var speeds := {}
	for unit in count:
		var key := 1000 + unit * 7 + index
		keys.append(key)
		positions[key] = origin + Vector2i(rng.randi_range(-spread, spread), rng.randi_range(-spread, spread))
		velocities[key] = _velocity(2400)
		radii[key] = _pick([0, 300, 358, 430, 600, 900, 9000])
		var alive := rng.randf() > 0.1
		script_field.set_unit(key, positions[key], radii[key], velocities[key], alive)
		native_field.set_unit(key, positions[key], radii[key], velocities[key], alive)
		caches_script[key] = {}
		caches_native[key] = {}
		goals[key] = positions[key] + Vector2i(rng.randi_range(-30000, 30000), rng.randi_range(-30000, 30000))
		speeds[key] = rng.randi_range(200, 3400)
	# Removals and stale duplicates.
	for removal in rng.randi_range(0, 3):
		var key: int = _pick(keys)
		script_field.remove(key)
		native_field.remove(key)
	check(script_field.size() == native_field.size(), "field sizes after updates")
	var boxes := PackedInt64Array()
	for box in rng.randi_range(0, 10):
		var center := origin + Vector2i(rng.randi_range(-spread, spread), rng.randi_range(-spread, spread))
		boxes.append_array([center.x, center.y, rng.randi_range(-200, 4000), rng.randi_range(-200, 4000), -1])
	if extreme: boxes.append_array([1 << 40, -(1 << 40), 1 << 41, 3000, -1])
	var bounds := PackedInt64Array([0, 0, 0, 0, 0])
	if rng.randf() < 0.5:
		var margin: int = _pick([0, 600, 3000, 50000])
		bounds = PackedInt64Array([1, origin.x - spread - margin, origin.y - spread - margin, origin.x + spread + margin, origin.y + spread + margin])
	var steps := 0
	var solved := 0
	var reused := 0
	for frame in rng.randi_range(4, 40):
		var step_time: int = _pick([1024, 1024, 1024, 1024, 1024, 2048, 31, 0, 1, 512, 40000])
		for key in keys:
			if rng.randf() < 0.25: continue
			var from: Vector2i = positions[key]
			# Goals persist (so scheduled steering is reused) and occasionally change.
			if rng.randf() < 0.05: goals[key] = from + Vector2i(rng.randi_range(-30000, 30000), rng.randi_range(-30000, 30000))
			var goal: Vector2i = goals[key]
			var preferred := Vector2i.ZERO
			if rng.randf() < 0.1: preferred = _velocity(3400)
			elif goal != from:
				# Toward the goal at unit speed, as movement code does.
				var offset := goal - from
				var length := Fixed.isqrt(int(offset.x) * offset.x + int(offset.y) * offset.y)
				preferred = Vector2i(Fixed.mul_div(offset.x, speeds[key], length), Fixed.mul_div(offset.y, speeds[key], length))
			# Scheduled caches are mostly kept; sometimes their clock is forced.
			if rng.randf() < 0.15 and caches_script[key].has("rt"):
				var forced := rng.randi_range(-2000, 9000)
				caches_script[key]["rt"] = forced
				caches_native[key]["rt"] = forced
			var motion := Avoidance.motion_record(from, radii[key], preferred, velocities[key], step_time, goal, rng.randf() < 0.97, key)
			var expected := Avoidance.steer_with_field(script_field, key, motion, boxes, [], bounds, caches_script[key])
			var actual: Vector2i = native_field.steer(key, motion, boxes, bounds, caches_native[key])
			steps += 1
			check(expected == actual, "scenario %d frame %d key %d destination %s != %s" % [index, frame, key, expected, actual])
			check(caches_script[key] == caches_native[key], "scenario %d frame %d key %d cache %s != %s" % [index, frame, key, caches_script[key], caches_native[key]])
			if failures > 0 and failures < 3 and expected != actual: print("motion ", motion, " boxes ", boxes, " bounds ", bounds)
			var moved := expected - from
			var time := maxi(1, step_time)
			positions[key] = expected
			velocities[key] = Vector2i(Fixed.mul_div(moved.x, Fixed.TIME_SCALE, time), Fixed.mul_div(moved.y, Fixed.TIME_SCALE, time))
			var alive := rng.randf() > 0.03
			script_field.set_unit(key, positions[key], radii[key], velocities[key], alive)
			native_field.set_unit(key, positions[key], radii[key], velocities[key], alive)
		# Neighbour sets for arbitrary observers, as unordered sets of bodies.
		for query in 3:
			var at := origin + Vector2i(rng.randi_range(-spread, spread), rng.randi_range(-spread, spread))
			var self_key: int = _pick(keys)
			var radius: int = _pick([0, 358, 430, 20000])
			var speed := rng.randi_range(0, 40000)
			var horizon: int = _pick([27648, 30720, 1024, 0])
			check(_bodies(script_field.gather(self_key, at, radius, speed, horizon)) == _bodies(native_field.gather(self_key, at, radius, speed, horizon)), "scenario %d neighbour set" % index)
	for key in keys:
		solved += int(caches_script[key].get("solved", 0))
		reused += int(caches_script[key].get("reused", 0))
	return [steps, solved, reused]

func _bodies(packed: PackedInt64Array) -> Array:
	var rows: Array = []
	for index in range(0, packed.size(), 5):
		rows.append([packed[index], packed[index + 1], packed[index + 2], packed[index + 3], packed[index + 4]])
	rows.sort()
	return rows

## Native sampler vs script loop on the real map layers (trees, lake, cliffs).
func _line_samples() -> int:
	var game := root.get_node("GameSession")
	game.online_active = false
	game.match_ai_mode = "sandbox"
	game.match_map_data = {}
	var scene: Node = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame
	var nav = scene.get_node("NavService").nav
	var kernel: RefCounted = ClassDB.instantiate("AoeSimKernel")
	var samples := 0
	for probe in 6000:
		var radius: float = _pick([0.2, 0.35, 0.42, 0.5, 0.9])
		nav._query_radius = nav._quantize_radius(radius)
		nav._ensure_active_radius(nav._query_radius)
		var a := Vector2(rng.randf_range(-250, 250), rng.randf_range(-250, 250))
		var b := a + Vector2(rng.randf_range(-70, 70), rng.randf_range(-70, 70))
		var start := Fixed.vector(a)
		var offset := Fixed.vector(b) - start
		var size := maxi(1, Fixed.coord(nav.cell_size))
		var spacing := maxi(1, Fixed.mul_div(size, 35, 100))
		var dist := Fixed.isqrt(Fixed.length_sq(offset))
		if dist == 0: continue
		var steps := maxi(2, Fixed.ceil_div(dist, spacing))
		var expected: bool = nav._line_clear_samples(start, offset, size, steps)
		var actual: bool = kernel.line_clear(nav._solid, nav._width, nav._height, nav._origin_cell, size, start, offset, steps)
		check(expected == actual, "waypoint probe %s -> %s radius %.2f" % [a, b, radius])
		samples += 1
	scene.queue_free()
	await process_frame
	return samples
