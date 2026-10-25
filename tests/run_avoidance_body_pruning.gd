extends SceneTree
## Compare every velocity candidate against the complete original neighbour set.
const Avoidance := preload("res://scripts/systems/local_avoidance.gd")
const Collision := preload("res://scripts/systems/collision_resolver.gd")

class Body extends RefCounted:
	var sim_pos := Vector2.ZERO
	var def := UnitDef.new()
	var hp := 40.0
	var velocity := Vector2.ZERO
	func locomotion_velocity() -> Vector2:
		return velocity

var checks := 0
var failures := 0
var discarded := 0

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		if failures < 8: push_error(message)

func _initialize() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 994513
	var unit := Body.new()
	for scenario in 250:
		unit.sim_pos = Vector2(random.randf_range(-50, 50), random.randf_range(-50, 50))
		unit.def.footprint_radius = random.randf_range(0.2, 2.0)
		var radius := Collision.unit_radius(unit)
		var speed := random.randf_range(0.01, 12)
		var delta := random.randf_range(0.005, 1.8)
		var preferred := Vector2.from_angle(random.randf_range(-PI, PI)) * speed
		var neighbors: Array = [unit]
		var complete: Array[Dictionary] = []
		for index in 28:
			var body := Body.new()
			body.def.footprint_radius = random.randf_range(0.2, 2)
			body.velocity = Vector2(random.randf_range(-12, 12), random.randf_range(-12, 12))
			var combined := radius + Collision.unit_radius(body)
			var direction := Vector2.from_angle(random.randf_range(-PI, PI))
			var distance: float
			match index % 7:
				0: distance = random.randf_range(0.0, combined) # Current overlaps.
				1: distance = combined + speed * delta # Swept circle boundary.
				2: distance = combined + Avoidance.MARGIN + (speed + body.velocity.length()) * maxf(Avoidance.HORIZON, delta)
				3: distance = (combined + Avoidance.MARGIN + (speed + body.velocity.length()) * maxf(Avoidance.HORIZON, delta)) * 1.00001
				_: distance = random.randf_range(0, 60)
			body.sim_pos = unit.sim_pos + direction * distance
			neighbors.append(body)
			var relative := body.sim_pos - unit.sim_pos
			complete.append({"relative": relative, "distance_sq": relative.length_squared(), "velocity": body.velocity, "radius": combined})
		var pruned := Avoidance._snapshot_bodies(unit, unit.sim_pos, radius, speed, delta, neighbors)
		discarded += complete.size() - pruned.size()
		for scale in [1.0, 0.5, 0.0]:
			for angle in Avoidance.ANGLES:
				var velocity := preferred.rotated(deg_to_rad(angle)) * float(scale)
				var expected := _reference_risk(velocity, delta, complete)
				var actual := Avoidance._snapshot_risk(velocity, delta, pruned)
				check((is_inf(expected) and is_inf(actual)) or is_equal_approx(expected, actual), "full risk unchanged at scenario %d / %s / %s" % [scenario, scale, angle])
				var limit := random.randf_range(0.01, 12)
				var bounded := Avoidance._snapshot_risk(velocity, delta, pruned, limit)
				check((expected >= limit and bounded >= limit) or (expected < limit and is_equal_approx(expected, bounded)), "bounded candidate eligibility unchanged")
	check(discarded > 1000, "random cases exercise distant-body pruning")
	print("AVOIDANCE BODY PRUNING: %d checks, %d failures, %d discarded neighbours" % [checks, failures, discarded])
	quit(0 if failures == 0 else 1)

func _reference_risk(velocity: Vector2, delta: float, bodies: Array[Dictionary]) -> float:
	var score := 0.0
	var motion := velocity * delta
	for body in bodies:
		var relative: Vector2 = body.relative
		var radius: float = body.radius
		if relative.length_squared() < radius * radius - 0.0001:
			if motion.dot(-relative) < -0.00001: return INF
		else:
			var closest := Geometry2D.get_closest_point_to_segment(relative, Vector2.ZERO, motion)
			if closest.distance_squared_to(relative) < radius * radius - 0.0001: return INF
		var contact := Avoidance.collision_time(relative, velocity - body.velocity, radius + Avoidance.MARGIN)
		if contact < Avoidance.HORIZON: score += 4.0 * (1.0 - contact / Avoidance.HORIZON)
	return score
