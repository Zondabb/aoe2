extends SceneTree
const Avoidance := preload("res://scripts/systems/local_avoidance.gd")
const Collision := preload("res://scripts/systems/collision_resolver.gd")

class Body extends RefCounted:
	var sim_pos := Vector2.ZERO
	var def := UnitDef.new()
	var hp := 40.0
	var velocity := Vector2.ZERO
	var goal := Vector2.ZERO
	var cache := {}
	func _init() -> void:
		def.footprint_radius = 0.35
	func locomotion_velocity() -> Vector2:
		return velocity

class Box extends RefCounted:
	var sim_pos := Vector2.ZERO
	var block_half := Vector2.ONE

var checks := 0
var failures := 0
const DELTA := 1.0 / 30.0
const SPEED := 3.2
var simulation_delta := DELTA
var reference_mode := false

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		if failures < 10: push_error(message)

func _run() -> void:
	if "--double-delta" in OS.get_cmdline_user_args(): simulation_delta *= 2
	reference_mode = "--reference" in OS.get_cmdline_user_args()
	Collision.clear_map_bounds()
	_test_invalidation()
	var through: Array[Body] = []
	for index in 24:
		var body := Body.new()
		# A convoy's front units park furthest beyond the gate, leaving the
		# entrance open for units that follow.
		body.sim_pos = Vector2(-8 - index * 1.1, 0)
		body.goal = Vector2(8 + (23 - index) * 1.1, 0)
		through.append(body)
	var upper := Box.new()
	upper.sim_pos = Vector2(0, -7)
	upper.block_half = Vector2(0.5, 5.3)
	var lower := Box.new()
	lower.sim_pos = Vector2(0, 7)
	lower.block_half = Vector2(0.5, 5.3)
	_simulate("24 units through narrow gate", through, [upper, lower], 1800)
	var opposing: Array[Body] = []
	for index in 16:
		var body := Body.new()
		var side := -1.0 if index < 8 else 1.0
		var slot := index % 8
		body.sim_pos = Vector2(side * 8, (slot - 3.5) * 4)
		body.goal = Vector2(-body.sim_pos.x, body.sim_pos.y)
		opposing.append(body)
	_simulate("opposing crowd", opposing, [], 1500)
	var worker := Body.new()
	worker.sim_pos = Vector2(-8, 0)
	worker.goal = Vector2(8.6, 0)
	var gathering: Array[Body] = [worker]
	for index in 12:
		var idle := Body.new()
		idle.sim_pos = Vector2(-10 + index, 10)
		idle.goal = idle.sim_pos
		gathering.append(idle)
	var resource := Box.new()
	resource.sim_pos = Vector2(10, 0)
	_simulate("resource approach and stop", gathering, [resource], 400)
	check(worker.sim_pos.distance_to(worker.goal) <= 0.3, "worker stops beside resource within movement arrival tolerance")
	print("SCHEDULED AVOIDANCE: %d checks, %d failures, delta %.4f" % [checks, failures, simulation_delta])
	quit(0 if failures == 0 else 1)

func _simulate(label: String, bodies: Array[Body], solids: Array, frames: int) -> void:
	var unsafe := 0
	for frame in ceili(frames * DELTA / simulation_delta):
		var arrived := 0
		for body in bodies:
			var from := body.sim_pos
			var offset := body.goal - from
			if offset.length() <= 0.3:
				body.velocity = Vector2.ZERO
				arrived += 1
				continue
			# The real unit follows A* corners before its final reserved goal.
			# Supply the corresponding doorway corner to this isolated solver.
			if label == "24 units through narrow gate" and body.sim_pos.x < 1.0:
				offset = Vector2(2, clampf(body.goal.y, -0.9, 0.9)) - from
			var preferred := offset.limit_length(SPEED * simulation_delta) / simulation_delta
			var to := Avoidance.step(body, preferred, body.velocity, simulation_delta, bodies, solids, body.goal) if reference_mode else Avoidance.step_scheduled(body, preferred, body.velocity, simulation_delta, bodies, solids, body.goal, body.cache)
			if not Collision.is_step_safe(body, from, to, bodies, solids): unsafe += 1
			body.sim_pos = to
			body.velocity = (to - from) / simulation_delta
		if arrived == bodies.size(): break
	var arrived := 0
	var reused := 0
	var solved := 0
	for body in bodies:
		if body.sim_pos.distance_to(body.goal) <= 0.3: arrived += 1
		reused += int(body.cache.get("reused", 0))
		solved += int(body.cache.get("solved", 0))
	check(unsafe == 0, label + ": every physics step respects swept bodies and walls")
	check(arrived == bodies.size(), "%s: all units reach their goals (%d/%d)" % [label, arrived, bodies.size()])
	if not reference_mode: check(reused > 0, label + ": exercises steering reuse")
	print("SCHEDULED AVOIDANCE CASE ", JSON.stringify({"case": label, "arrived": arrived, "units": bodies.size(), "solved": solved, "reused": reused, "unsafe_steps": unsafe}))

func _test_invalidation() -> void:
	var unit := Body.new()
	unit.goal = Vector2(20, 0)
	var bodies: Array = [unit]
	for index in 12:
		var idle := Body.new()
		idle.sim_pos = Vector2(index, 20)
		bodies.append(idle)
	var cache := {}
	unit.sim_pos = Avoidance.step_scheduled(unit, Vector2.RIGHT * SPEED, Vector2.ZERO, 0.001, bodies, [], unit.goal, cache)
	cache.remaining = 0.1
	var before := int(cache.solved)
	unit.sim_pos = Avoidance.step_scheduled(unit, Vector2.RIGHT * SPEED, Vector2.RIGHT * SPEED, 0.001, bodies, [], unit.goal, cache)
	check(int(cache.solved) == before and int(cache.get("reused", 0)) > 0, "stable safe direction reuses solved steering")
	for change in ["goal", "speed", "direction", "teleport"]:
		cache.remaining = 0.1
		before = int(cache.solved)
		var preferred := Vector2.RIGHT * SPEED
		if change == "goal": unit.goal += Vector2.RIGHT
		elif change == "speed": preferred *= 2
		elif change == "direction": preferred = Vector2.UP * SPEED
		else: unit.sim_pos += Vector2(0, 1)
		unit.sim_pos = Avoidance.step_scheduled(unit, preferred, Vector2.RIGHT * SPEED, 0.001, bodies, [], unit.goal, cache)
		check(int(cache.solved) == before + 1, change + " forces an immediate fresh steering choice")
	cache.remaining = 0.1
	cache.preferred = Vector2.RIGHT * SPEED
	cache.velocity = Vector2.RIGHT * SPEED
	var wall := Box.new()
	wall.block_half = Vector2(0.4, 2)
	wall.sim_pos = unit.sim_pos + Vector2(0.75, 0)
	before = int(cache.solved)
	var from := unit.sim_pos
	var to := Avoidance.step_scheduled(unit, Vector2.RIGHT * SPEED, Vector2.RIGHT * SPEED, DELTA, bodies, [wall], unit.goal, cache)
	check(int(cache.solved) == before + 1, "new static obstruction forces immediate recomputation")
	check(Collision.is_step_safe(unit, from, to, bodies, [wall]), "new wall cannot be crossed by a retained velocity")
	cache.remaining = 0.1
	cache.preferred = Vector2.RIGHT * SPEED
	cache.velocity = Vector2.RIGHT * SPEED
	cache.risk = 0.0
	cache.position = unit.sim_pos
	var blocker: Body = bodies[1]
	blocker.sim_pos = unit.sim_pos + Vector2(0.71, 0)
	before = int(cache.solved)
	to = Avoidance.step_scheduled(unit, Vector2.RIGHT * SPEED, Vector2.RIGHT * SPEED, DELTA, bodies, [], unit.goal, cache)
	check(int(cache.solved) == before + 1, "new predicted/body contact forces immediate recomputation")
	check(Collision.is_step_safe(unit, from, to, bodies, []), "new nearby unit cannot be crossed by retained velocity")
	blocker.sim_pos = Vector2(0, 20)
	cache.remaining = 0.1
	cache.velocity = Vector2.ZERO
	before = int(cache.solved)
	Avoidance.step_scheduled(unit, Vector2.RIGHT * SPEED, Vector2.ZERO, DELTA, bodies, [wall], unit.goal, cache)
	check(int(cache.solved) == before + 1, "stopped steering is reconsidered immediately")
