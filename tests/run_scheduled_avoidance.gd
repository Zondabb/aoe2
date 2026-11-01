extends SceneTree
## Integer local avoidance in crowds: a narrow gate, opposing groups and a
## worker stopping beside a resource. Every step must respect swept bodies
## and walls, all units must arrive, scheduled steering must be reused, and
## changed goals/speed/direction/obstacles must force a fresh choice.
## With the GDExtension loaded, each scenario also runs through the native
## solver and must produce exactly the same trajectories as the script.
const Avoidance := preload("res://scripts/systems/local_avoidance.gd")
const Field := preload("res://scripts/systems/unit_field.gd")
const Fixed := preload("res://scripts/core/sim_fixed.gd")

class Body extends RefCounted:
	var pos := Vector2i.ZERO
	var goal := Vector2i.ZERO
	var velocity := Vector2i.ZERO
	var radius := 358 # 0.35 tile
	var cache := {}
	var key := 0

var checks := 0
var failures := 0
const STEP_TIME := 1024 # 1/30 s
const SPEED := 3277 # 3.2 tiles per second
const ARRIVAL := 307 # 0.3 tile
var step_time := STEP_TIME
var native := false

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		if failures < 10: push_error(message)

func _run() -> void:
	if "--double-delta" in OS.get_cmdline_user_args(): step_time *= 2
	var modes := [false]
	if Field.native_available(): modes.append(true)
	var traces := {}
	for mode in modes:
		native = mode
		traces[mode] = _scenarios()
		_test_invalidation()
	if modes.size() == 2:
		check(traces[false] == traces[true], "native and script solvers produce identical trajectories")
		print("SCHEDULED AVOIDANCE native/script trajectories identical: ", traces[false] == traces[true])
	else:
		print("SCHEDULED AVOIDANCE: native extension not loaded, script solver only")
	print("SCHEDULED AVOIDANCE: %d checks, %d failures, step time %d" % [checks, failures, step_time])
	quit(0 if failures == 0 else 1)

func _field() -> RefCounted:
	return ClassDB.instantiate("AoeUnitField") if native else Field.new()

func _q(value: Vector2) -> Vector2i:
	return Fixed.vector(value)

func _scenarios() -> Array:
	var trace: Array = []
	var through: Array[Body] = []
	for index in 24:
		var body := Body.new()
		# A convoy's front units park furthest beyond the gate, leaving the
		# entrance open for units that follow.
		body.pos = _q(Vector2(-8 - index * 1.1, 0))
		body.goal = _q(Vector2(8 + (23 - index) * 1.1, 0))
		through.append(body)
	var gate := _boxes([[Vector2(0, -7), Vector2(0.5, 5.3)], [Vector2(0, 7), Vector2(0.5, 5.3)]], 358)
	trace.append(_simulate("24 units through narrow gate", through, gate, 1800))
	var opposing: Array[Body] = []
	for index in 16:
		var body := Body.new()
		var side := -1.0 if index < 8 else 1.0
		var slot := index % 8
		body.pos = _q(Vector2(side * 8, (slot - 3.5) * 4))
		body.goal = Vector2i(-body.pos.x, body.pos.y)
		opposing.append(body)
	trace.append(_simulate("opposing crowd", opposing, PackedInt64Array(), 1500))
	var worker := Body.new()
	worker.pos = _q(Vector2(-8, 0))
	worker.goal = _q(Vector2(8.6, 0))
	var gathering: Array[Body] = [worker]
	for index in 12:
		var idle := Body.new()
		idle.pos = _q(Vector2(-10 + index, 10))
		idle.goal = idle.pos
		gathering.append(idle)
	trace.append(_simulate("resource approach and stop", gathering, _boxes([[Vector2(10, 0), Vector2.ONE]], 358), 400))
	check(_length(worker.goal - worker.pos) <= ARRIVAL, "worker stops beside resource within movement arrival tolerance")
	return trace

func _boxes(rects: Array, radius: int) -> PackedInt64Array:
	var boxes := PackedInt64Array()
	for rect in rects:
		var center := _q(rect[0])
		var half := _q(rect[1])
		boxes.append_array([center.x, center.y, half.x + radius, half.y + radius, -1])
	return boxes

func _length(vector: Vector2i) -> int:
	return Fixed.isqrt(int(vector.x) * vector.x + int(vector.y) * vector.y)

func _simulate(label: String, bodies: Array[Body], boxes: PackedInt64Array, frames: int) -> Array:
	var field := _field()
	var unbounded := PackedInt64Array([0, 0, 0, 0, 0])
	for index in bodies.size():
		bodies[index].key = index + 1
		field.set_unit(bodies[index].key, bodies[index].pos, bodies[index].radius, bodies[index].velocity, true)
	var unsafe := 0
	var positions: Array = []
	for frame in ceili(frames * STEP_TIME / float(step_time)):
		var arrived := 0
		for body in bodies:
			var from := body.pos
			var offset := body.goal - from
			if _length(offset) <= ARRIVAL:
				body.velocity = Vector2i.ZERO
				field.set_unit(body.key, body.pos, body.radius, body.velocity, true)
				arrived += 1
				continue
			# The real unit follows A* corners before its final reserved goal.
			# Supply the corresponding doorway corner to this isolated solver.
			if label == "24 units through narrow gate" and from.x < 1024:
				offset = Vector2i(2048, clampi(body.goal.y, -922, 922)) - from
			var limit := Fixed.mul_div(SPEED, step_time, Fixed.TIME_SCALE)
			var length := _length(offset)
			if length > limit: offset = Vector2i(Fixed.mul_div(offset.x, limit, length), Fixed.mul_div(offset.y, limit, length))
			var preferred := Vector2i(Fixed.mul_div(offset.x, Fixed.TIME_SCALE, step_time), Fixed.mul_div(offset.y, Fixed.TIME_SCALE, step_time))
			var motion := Avoidance.motion_record(from, body.radius, preferred, body.velocity, step_time, body.goal, true, body.key)
			var to: Vector2i = field.steer(body.key, motion, boxes, unbounded, body.cache) if native else Avoidance.steer_with_field(field, body.key, motion, boxes, [], unbounded, body.cache)
			if not _step_safe(body, from, to, bodies, boxes): unsafe += 1
			body.pos = to
			var moved := to - from
			body.velocity = Vector2i(Fixed.mul_div(moved.x, Fixed.TIME_SCALE, step_time), Fixed.mul_div(moved.y, Fixed.TIME_SCALE, step_time))
			field.set_unit(body.key, body.pos, body.radius, body.velocity, true)
		if arrived == bodies.size(): break
	var arrived := 0
	var reused := 0
	var solved := 0
	for body in bodies:
		if _length(body.goal - body.pos) <= ARRIVAL: arrived += 1
		reused += int(body.cache.get("reused", 0))
		solved += int(body.cache.get("solved", 0))
		positions.append(body.pos)
	check(unsafe == 0, label + ": every physics step respects swept bodies and walls")
	check(arrived == bodies.size(), "%s: all units reach their goals (%d/%d)" % [label, arrived, bodies.size()])
	check(reused > 0, label + ": exercises steering reuse")
	print("SCHEDULED AVOIDANCE CASE ", JSON.stringify({"case": label, "native": native, "arrived": arrived, "units": bodies.size(), "solved": solved, "reused": reused, "unsafe_steps": unsafe}))
	return positions

## Same integer swept test as the solver's hard constraint (CollisionResolver
## .is_step_safe on the fixed lattice), plus walls.
func _step_safe(body: Body, from: Vector2i, to: Vector2i, bodies: Array[Body], boxes: PackedInt64Array) -> bool:
	var motion := to - from
	for index in range(0, boxes.size(), 5):
		if Avoidance.box_hit(from - Vector2i(boxes[index], boxes[index + 1]), motion, Vector2i(boxes[index + 2] - 1, boxes[index + 3] - 1)): return false
	for other in bodies:
		if other == body: continue
		var limit := (body.radius + other.radius) * (body.radius + other.radius)
		var offset := from - other.pos
		if int(offset.x) * offset.x + int(offset.y) * offset.y < limit:
			if int(motion.x) * offset.x + int(motion.y) * offset.y < 0: return false
			continue
		var nearest := from
		var length_sq := int(motion.x) * motion.x + int(motion.y) * motion.y
		if length_sq > 0:
			var projection := clampi(-(int(offset.x) * motion.x + int(offset.y) * motion.y), 0, length_sq)
			nearest += Vector2i(Fixed.mul_div(motion.x, projection, length_sq), Fixed.mul_div(motion.y, projection, length_sq))
		var gap := nearest - other.pos
		if int(gap.x) * gap.x + int(gap.y) * gap.y < limit: return false
	return true

func _steer(field: RefCounted, unit: Body, preferred: Vector2i, previous: Vector2i, time: int, boxes: PackedInt64Array) -> Vector2i:
	var motion := Avoidance.motion_record(unit.pos, unit.radius, preferred, previous, time, unit.goal, true, unit.key)
	var unbounded := PackedInt64Array([0, 0, 0, 0, 0])
	return field.steer(unit.key, motion, boxes, unbounded, unit.cache) if native else Avoidance.steer_with_field(field, unit.key, motion, boxes, [], unbounded, unit.cache)

func _test_invalidation() -> void:
	var field := _field()
	var unit := Body.new()
	unit.key = 1
	unit.goal = _q(Vector2(20, 0))
	field.set_unit(unit.key, unit.pos, unit.radius, Vector2i.ZERO, true)
	var idle: Array[Body] = []
	for index in 12:
		var body := Body.new()
		body.key = index + 2
		body.pos = _q(Vector2(index, 20))
		field.set_unit(body.key, body.pos, body.radius, Vector2i.ZERO, true)
		idle.append(body)
	var right := Vector2i(SPEED, 0)
	var tiny := 31 # 0.001 s
	unit.pos = _steer(field, unit, right, Vector2i.ZERO, tiny, PackedInt64Array())
	unit.cache["rt"] = 3072
	var before := int(unit.cache.solved)
	unit.pos = _steer(field, unit, right, right, tiny, PackedInt64Array())
	check(int(unit.cache.solved) == before and int(unit.cache.get("reused", 0)) > 0, "stable safe direction reuses solved steering")
	for change in ["goal", "speed", "direction", "teleport"]:
		unit.cache["rt"] = 3072
		before = int(unit.cache.solved)
		var preferred := right
		if change == "goal": unit.goal += Vector2i(1024, 0)
		elif change == "speed": preferred *= 2
		elif change == "direction": preferred = Vector2i(0, -SPEED)
		else: unit.pos += Vector2i(0, 1024)
		unit.pos = _steer(field, unit, preferred, right, tiny, PackedInt64Array())
		check(int(unit.cache.solved) == before + 1, change + " forces an immediate fresh steering choice")
	field.set_unit(unit.key, unit.pos, unit.radius, right, true)
	_retain(unit, right)
	var wall := _boxes([[Fixed.to_vector(unit.pos) + Vector2(0.75, 0), Vector2(0.4, 2)]], unit.radius)
	before = int(unit.cache.solved)
	var from := unit.pos
	var to := _steer(field, unit, right, right, STEP_TIME, wall)
	check(int(unit.cache.solved) == before + 1, "new static obstruction forces immediate recomputation")
	check(_step_safe(unit, from, to, [unit], wall), "new wall cannot be crossed by a retained velocity")
	_retain(unit, right)
	var blocker: Body = idle[0]
	blocker.pos = unit.pos + _q(Vector2(0.71, 0))
	field.set_unit(blocker.key, blocker.pos, blocker.radius, Vector2i.ZERO, true)
	before = int(unit.cache.solved)
	var everyone: Array[Body] = [unit, blocker]
	to = _steer(field, unit, right, right, STEP_TIME, PackedInt64Array())
	check(int(unit.cache.solved) == before + 1, "new predicted/body contact forces immediate recomputation")
	check(_step_safe(unit, unit.pos, to, everyone, PackedInt64Array()), "new nearby unit cannot be crossed by retained velocity")
	blocker.pos = _q(Vector2(0, 20))
	field.set_unit(blocker.key, blocker.pos, blocker.radius, Vector2i.ZERO, true)
	_retain(unit, Vector2i.ZERO)
	before = int(unit.cache.solved)
	_steer(field, unit, right, Vector2i.ZERO, STEP_TIME, wall)
	check(int(unit.cache.solved) == before + 1, "stopped steering is reconsidered immediately")

## A scheduled choice that is still valid for this position and goal.
func _retain(unit: Body, velocity: Vector2i) -> void:
	unit.cache["rt"] = 3072
	unit.cache["ux"] = SPEED
	unit.cache["uy"] = 0
	unit.cache["vx"] = velocity.x
	unit.cache["vy"] = velocity.y
	unit.cache["risk"] = 0
	unit.cache["px"] = unit.pos.x
	unit.cache["py"] = unit.pos.y
	unit.cache["gx"] = unit.goal.x
	unit.cache["gy"] = unit.goal.y
	unit.cache["hg"] = 1
