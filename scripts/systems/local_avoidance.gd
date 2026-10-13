class_name LocalAvoidance
extends RefCounted

## Bounded velocity sampling with prediction and a consistent passing side.
## It changes this frame's velocity, never the static A* route.
const Collision := preload("res://scripts/systems/collision_resolver.gd")
const HORIZON := 0.9
const NEIGHBOR_RANGE := 10.0
const MARGIN := 0.12
const ANGLES := [0.0, 15.0, -15.0, 30.0, -30.0, 45.0, -45.0, 60.0, -60.0, 90.0, -90.0, 120.0, -120.0, 150.0, -150.0, 180.0]

static func step(unit: Object, preferred: Vector2, previous: Vector2, delta: float, neighbors: Array, solids: Array, goal := Vector2.INF) -> Vector2:
	var from: Vector2 = unit.get("sim_pos")
	var speed := preferred.length()
	if speed < 0.0001 or delta <= 0:
		return from
	# Stop predicting static travel at the destination. Workers intentionally
	# finish beside a resource; extending the velocity through that resource
	# penalizes every approach and can make standing still the best candidate.
	var static_horizon := maxf(HORIZON, delta)
	if is_finite(goal.x) and is_finite(goal.y):
		static_horizon = minf(static_horizon, maxf(delta, from.distance_to(goal) / speed))
	var nearby_solids: Array[Dictionary] = []
	var radius := Collision.unit_radius(unit)
	for solid in solids:
		if not is_instance_valid(solid):
			continue
		if solid.get("is_placement_ghost") == true:
			continue
		var footprint := Collision._blocker_half(solid, radius)
		if footprint.x <= 0.0 or footprint.y <= 0.0:
			continue
		var half := footprint + Vector2.ONE * speed * maxf(HORIZON, delta)
		var center: Vector2 = solid.get("sim_pos")
		if Rect2(center - half, half * 2).has_point(from):
			var geometry := {"center": center, "half": footprint}
			if solid.has_method("get_water_contours") and not solid.get_water_contours().is_empty():
				geometry["contours"] = solid.get_water_contours()
				geometry["radius"] = radius
			nearby_solids.append(geometry)
	# Snapshot neighbor properties once, outside the candidate loop.
	var bodies: Array[Dictionary] = []
	for other in neighbors:
		if other == unit or not is_instance_valid(other):
			continue
		var health: Variant = other.get("hp")
		if health != null and float(health) <= 0:
			continue
		var velocity := Vector2.ZERO
		if other.has_method("locomotion_velocity"):
			velocity = other.locomotion_velocity()
		var relative: Vector2 = other.get("sim_pos") - from
		bodies.append({"relative": relative, "distance_sq": relative.length_squared(), "velocity": velocity, "radius": radius + Collision.unit_radius(other)})
	var direct_risk := _body_risk(preferred, delta, bodies)
	if direct_risk == 0 and Collision.clamp_to_map(from + preferred * delta, radius).is_equal_approx(from + preferred * delta) and Collision.static_geometry_step_safe(from, from + preferred * static_horizon, nearby_solids):
		return from + preferred * delta
	var best := Vector2.ZERO
	var best_score := INF
	for scale in [1.0, 0.5, 0.0]:
		for angle in ANGLES:
			if scale == 0 and angle != 0:
				continue
			var velocity: Vector2 = preferred.rotated(deg_to_rad(angle)) * scale
			var destination := from + velocity * delta
			if not Collision.clamp_to_map(destination, radius).is_equal_approx(destination):
				continue
			var score := velocity.distance_squared_to(preferred) / (speed * speed)
			score += 0.18 * velocity.distance_squared_to(previous) / (speed * speed)
			# Safe lateral travel must beat standing still.
			score += (1.0 - scale) * 2.0
			if angle < 0:
				score += 0.08
			if score >= best_score:
				continue
			score += _body_risk(velocity, delta, bodies, best_score - score)
			if score >= best_score or not Collision.static_geometry_step_safe(from, destination, nearby_solids):
				continue
			if not Collision.static_geometry_step_safe(from, from + velocity * static_horizon, nearby_solids):
				score += 2.0
			if score < best_score:
				best_score = score
				best = velocity
	return from + best * delta

static func _body_risk(velocity: Vector2, delta: float, bodies: Array[Dictionary], limit: float = INF) -> float:
	var score := 0.0
	var motion := velocity * delta
	var motion_length := motion.length()
	for body in bodies:
		var relative: Vector2 = body.relative
		var radius: float = body.radius
		var distance_sq: float = body.distance_sq
		if distance_sq < radius * radius - 0.0001:
			if motion.dot(-relative) < -0.00001:
				return INF
		elif distance_sq < (radius + motion_length) * (radius + motion_length):
			# A farther body cannot be touched by this frame's swept circle.
			var closest := Geometry2D.get_closest_point_to_segment(relative, Vector2.ZERO, motion)
			if closest.distance_squared_to(relative) < radius * radius - 0.0001:
				return INF
		var relative_velocity: Vector2 = velocity - body.velocity
		var closing := relative.dot(relative_velocity)
		if closing <= 0.00001: continue
		var gap := distance_sq - (radius + MARGIN) * (radius + MARGIN)
		var contact := 0.0
		if gap > 0:
			var speed_sq := relative_velocity.length_squared()
			var discriminant := closing * closing - speed_sq * gap
			if discriminant < 0 or speed_sq < 0.00001: continue
			contact = (closing - sqrt(discriminant)) / speed_sq
		if contact < HORIZON:
			score += 4.0 * (1.0 - contact / HORIZON)
			# Risk only adds nonnegative terms. Once this candidate cannot beat
			# the best velocity, the remaining neighbors cannot rescue it.
			if score >= limit: return score
	return score

static func collision_time(relative: Vector2, velocity: Vector2, radius: float) -> float:
	var closing := relative.dot(velocity)
	if closing <= 0.00001:
		return INF
	var distance := relative.length_squared() - radius * radius
	if distance <= 0:
		return 0.0
	var speed_sq := velocity.length_squared()
	var discriminant := closing * closing - speed_sq * distance
	if discriminant < 0 or speed_sq < 0.00001:
		return INF
	return (closing - sqrt(discriminant)) / speed_sq
