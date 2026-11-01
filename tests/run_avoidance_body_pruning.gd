extends SceneTree
## Neighbour pruning (the field's reach test and the solver's swept prefilter)
## must not change any candidate's integer risk compared with evaluating the
## complete neighbour set, including bodies placed exactly on each boundary.
## Runs the script field, and the native field when the extension is loaded.
const Avoidance := preload("res://scripts/systems/local_avoidance.gd")
const Field := preload("res://scripts/systems/unit_field.gd")
const Fixed := preload("res://scripts/core/sim_fixed.gd")

var checks := 0
var failures := 0
var discarded := 0

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		if failures < 8: push_error(message)

func _initialize() -> void:
	var fields: Array = [Field.new()]
	if Field.native_available(): fields.append(ClassDB.instantiate("AoeUnitField"))
	for field in fields:
		_run(field)
	print("AVOIDANCE BODY PRUNING: %d checks, %d failures, %d discarded neighbours, fields %d" % [checks, failures, discarded, fields.size()])
	quit(0 if failures == 0 else 1)

func _run(field: RefCounted) -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 994513
	for scenario in 250:
		field.clear()
		var from := Vector2i(random.randi_range(-50000, 50000), random.randi_range(-50000, 50000))
		var radius := random.randi_range(200, 2048)
		var speed := random.randi_range(10, 8000)
		var step_time := random.randi_range(150, 30720)
		var horizon := maxi(Avoidance.HORIZON_TIME, step_time)
		var angle := random.randf_range(-PI, PI)
		var preferred := Vector2i(roundi(cos(angle) * speed), roundi(sin(angle) * speed))
		speed = Fixed.isqrt(int(preferred.x) * preferred.x + int(preferred.y) * preferred.y)
		var complete := PackedInt64Array()
		for index in 28:
			var body_radius := random.randi_range(200, 2048)
			var velocity := Vector2i(random.randi_range(-8000, 8000), random.randi_range(-8000, 8000))
			var combined := radius + body_radius
			var other_speed := Fixed.isqrt(int(velocity.x) * velocity.x + int(velocity.y) * velocity.y)
			var reach: int = combined + Avoidance.MARGIN_Q + Fixed.mul_div(speed + other_speed, horizon, Fixed.TIME_SCALE)
			var distance: int
			match index % 7:
				0: distance = random.randi_range(0, combined) # Current overlaps.
				1: distance = combined + Fixed.mul_div(speed, step_time, Fixed.TIME_SCALE) # Swept circle boundary.
				2: distance = reach # Exactly on the pruning boundary.
				3: distance = reach + 1
				_: distance = random.randi_range(0, 60000)
			var direction := random.randf_range(-PI, PI)
			var offset := Vector2i(roundi(cos(direction) * distance), roundi(sin(direction) * distance))
			field.set_unit(100 + index, from + offset, body_radius, velocity, true)
			complete.append_array([offset.x, offset.y, velocity.x, velocity.y, combined])
		field.set_unit(1, from, radius, Vector2i.ZERO, true)
		var pruned: PackedInt64Array = field.gather(1, from, radius, speed, horizon)
		discarded += (complete.size() - pruned.size()) / 5
		for scale in 3:
			for entry in Avoidance.ANGLES:
				var velocity := Vector2i.ZERO
				if scale < 2:
					velocity = Avoidance.rotate(preferred, entry[1], entry[2])
					if scale == 1: velocity = Vector2i(Fixed.mul_div(velocity.x, 1, 2), Fixed.mul_div(velocity.y, 1, 2))
				var expected := _reference_risk(velocity, step_time, complete)
				var actual := Avoidance.risk(velocity, step_time, pruned, Avoidance.RISK_INF)
				check(expected == actual, "full risk unchanged at scenario %d / %d (%d != %d)" % [scenario, scale, expected, actual])
				var limit := random.randi_range(1, 800000)
				var bounded := Avoidance.risk(velocity, step_time, pruned, limit)
				check((expected >= limit and bounded >= limit) or (expected < limit and expected == bounded), "bounded candidate eligibility unchanged")
	check(discarded > 1000, "random cases exercise distant-body pruning")

## Every body, no swept prefilter: the closest point is always evaluated.
@warning_ignore("integer_division")
func _reference_risk(velocity: Vector2i, step_time: int, bodies: PackedInt64Array) -> int:
	var motion := Avoidance.motion_for(velocity, step_time)
	var motion_sq := int(motion.x) * motion.x + int(motion.y) * motion.y
	var total := 0
	for index in range(0, bodies.size(), 5):
		var rx: int = bodies[index]
		var ry: int = bodies[index + 1]
		var combined: int = bodies[index + 4]
		var distance_sq := rx * rx + ry * ry
		if distance_sq < combined * combined:
			if motion.x * rx + motion.y * ry > 0: return Avoidance.RISK_INF
		else:
			var projection := clampi(rx * motion.x + ry * motion.y, 0, motion_sq)
			var cx := Fixed.mul_div(motion.x, projection, motion_sq) if motion_sq > 0 else 0
			var cy := Fixed.mul_div(motion.y, projection, motion_sq) if motion_sq > 0 else 0
			if (rx - cx) * (rx - cx) + (ry - cy) * (ry - cy) < combined * combined: return Avoidance.RISK_INF
		var rvx: int = velocity.x - bodies[index + 2]
		var rvy: int = velocity.y - bodies[index + 3]
		var closing := rx * rvx + ry * rvy
		if closing <= 0: continue
		var padded := combined + Avoidance.MARGIN_Q
		var gap := distance_sq - padded * padded
		if gap <= 0:
			total += Avoidance.CONTACT_WEIGHT
			continue
		var relative_sq := rvx * rvx + rvy * rvy
		if relative_sq == 0: continue
		var discriminant := closing * closing - relative_sq * gap
		if discriminant < 0: continue
		var numerator := closing - Fixed.isqrt(discriminant)
		if 10 * numerator < 9 * relative_sq:
			total += Avoidance.CONTACT_WEIGHT - Fixed.mul_div(Avoidance.CONTACT_WEIGHT * 10, numerator, 9 * relative_sq)
	return total
