class_name LocalAvoidance
extends RefCounted
const Fixed := preload("res://scripts/core/sim_fixed.gd")

## Bounded velocity sampling with prediction and a consistent passing side.
## It changes this frame's velocity, never the static A* route.
const Collision := preload("res://scripts/systems/collision_resolver.gd")
const HORIZON := 0.9
const NEIGHBOR_RANGE := 10.0
const MARGIN := 0.12
const ANGLES := [0.0, 15.0, -15.0, 30.0, -30.0, 45.0, -45.0, 60.0, -60.0, 90.0, -90.0, 120.0, -120.0, 150.0, -150.0, 180.0]
const STEERING_INTERVAL := 0.1
const SCHEDULED_NEIGHBORS := 12
const REUSE_RISK_INCREASE := 0.25
const REUSE_DIRECTION_DOT := 0.996194698 # Five degrees.

class BodySnapshot extends RefCounted:
	var relative: Vector2
	var velocity: Vector2
	var distance_sq: float
	var radius: float
	var radius_sq: float
	var gap: float
	func _init(offset: Vector2, motion: Vector2, combined_radius: float) -> void:
		relative = offset
		velocity = motion
		distance_sq = offset.length_squared()
		radius = combined_radius
		radius_sq = radius * radius
		gap = distance_sq - (radius + MARGIN) * (radius + MARGIN)

static func step(unit: Object, preferred: Vector2, previous: Vector2, delta: float, neighbors: Array, solids: Array, goal := Vector2.INF, result_state: Variant = null, prepared_bodies: Variant = null) -> Vector2:
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
	var bodies: Array[BodySnapshot] = prepared_bodies if prepared_bodies != null else _snapshot_bodies(unit, from, radius, speed, delta, neighbors)
	var direct_risk := _snapshot_risk(preferred, delta, bodies)
	if direct_risk == 0 and Collision.clamp_to_map(from + preferred * delta, radius).is_equal_approx(from + preferred * delta) and Collision.static_geometry_step_safe(from, from + preferred * static_horizon, nearby_solids):
		if result_state is Dictionary: result_state.risk = 0.0
		return from + preferred * delta
	var best := Vector2.ZERO
	var best_score := INF
	var best_risk := INF
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
			var risk := _snapshot_risk(velocity, delta, bodies, best_score - score)
			score += risk
			if score >= best_score or not Collision.static_geometry_step_safe(from, destination, nearby_solids):
				continue
			if not Collision.static_geometry_step_safe(from, from + velocity * static_horizon, nearby_solids):
				score += 2.0
			if score < best_score:
				best_score = score
				best = velocity
				best_risk = risk
	if result_state is Dictionary: result_state.risk = best_risk
	return from + best * delta

## Large crowds need a new 33-candidate steering choice at most every 0.1
## simulation seconds. Every intervening move still uses current swept-body
## tests, predicted contacts, static geometry and map bounds. Cache state belongs
## to the caller; there are no process-global unit references or lifetimes.
static func step_scheduled(unit: Object, preferred: Vector2, previous: Vector2, delta: float, neighbors: Array, solids: Array, goal: Vector2, cache: Dictionary) -> Vector2:
	var from: Vector2 = unit.get("sim_pos")
	var speed := preferred.length()
	if neighbors.size() < SCHEDULED_NEIGHBORS or speed < 0.0001 or delta <= 0:
		cache.clear()
		return step(unit, preferred, previous, delta, neighbors, solids, goal)
	var initialized := cache.has("velocity")
	var remaining: int = int(cache.get("remaining_time", Fixed.time_from_seconds(float(cache.get("remaining", 0.0)))))
	# Keep the old seconds field as a UI/test adapter, not the simulation clock.
	if cache.has("remaining") and float(cache.remaining) != Fixed.time_to_seconds(remaining):
		remaining = Fixed.time_from_seconds(float(cache.remaining))
	remaining -= Fixed.delta_time(delta, unit.has_meta("lockstep_entity"))
	cache.remaining_time = remaining
	cache.remaining = Fixed.time_to_seconds(remaining)
	var prepared_bodies: Variant = null
	if initialized and remaining > 0 and cache.goal == goal and from.distance_squared_to(cache.position) <= 0.0001:
		var old_preferred: Vector2 = cache.preferred
		var old_speed := old_preferred.length()
		# Small length differences come from float position subtraction. Scale
		# the retained direction to today's exact speed; actual speed/turn changes
		# invalidate it immediately instead of waiting for the interval.
		if old_speed > 0.0001 and absf(old_speed - speed) <= speed * 0.01 and old_preferred.dot(preferred) / (old_speed * speed) >= REUSE_DIRECTION_DOT:
			var radius := Collision.unit_radius(unit)
			var bodies := _snapshot_bodies(unit, from, radius, speed, delta, neighbors)
			prepared_bodies = bodies
			var horizon := maxf(HORIZON, delta)
			if is_finite(goal.x) and is_finite(goal.y):
				horizon = minf(horizon, maxf(delta, from.distance_to(goal) / speed))
			var direct_risk := _snapshot_risk(preferred, delta, bodies)
			var direct_to := from + preferred * delta
			if direct_risk == 0 and Collision.clamp_to_map(direct_to, radius).is_equal_approx(direct_to) and Collision.static_step_safe(from, from + preferred * horizon, radius, solids):
				cache.velocity = preferred
				cache.preferred = preferred
				cache.position = direct_to
				cache.risk = 0.0
				cache.reused = int(cache.get("reused", 0)) + 1
				return direct_to
			var velocity: Vector2 = cache.velocity * (speed / old_speed)
			if velocity.length_squared() > speed * speed:
				velocity = velocity.normalized() * speed
			var to := from + velocity * delta
			# A stopped/blocked choice must be reconsidered immediately. Retaining
			# a stale zero velocity would turn temporary congestion into a stall.
			if velocity.length_squared() > speed * speed * 0.01 and Collision.clamp_to_map(to, radius).is_equal_approx(to):
				var risk := _snapshot_risk(velocity, delta, bodies)
				if is_finite(risk) and risk <= float(cache.risk) + REUSE_RISK_INCREASE and direct_risk + REUSE_RISK_INCREASE >= risk and Collision.static_step_safe(from, to, radius, solids) and Collision.static_step_safe(from, from + velocity * horizon, radius, solids):
					cache.position = to
					cache.reused = int(cache.get("reused", 0)) + 1
					return to
	# A rejected retained velocity uses this same current-tick snapshot for the
	# full solve; do not read and allocate every neighbour a second time.
	var result := step(unit, preferred, previous, delta, neighbors, solids, goal, cache, prepared_bodies)
	cache.velocity = (result - from) / delta
	cache.preferred = preferred
	cache.goal = goal
	cache.position = result
	# Spread the first refresh over six phases, then each unit keeps its own
	# simulation-time clock. Pauses and game-speed changes follow delta.
	var interval := Fixed.time_from_seconds(STEERING_INTERVAL)
	cache.remaining_time = interval if initialized else Fixed.mul_div(interval, int(unit.get_meta("net_id", unit.get_instance_id())) % 6 + 1, 6)
	cache.remaining = Fixed.time_to_seconds(int(cache.remaining_time))
	cache.solved = int(cache.get("solved", 0)) + 1
	return result

## No candidate travels faster than preferred. A body beyond even the maximum
## relative travel plus both radii cannot overlap this frame or contact during
## prediction, in any candidate direction. Keep all nearer bodies in their
## original order, including overlaps and exact/tolerance boundary cases.
static func _snapshot_bodies(unit: Object, from: Vector2, radius: float, speed: float, delta: float, neighbors: Array) -> Array[BodySnapshot]:
	var bodies: Array[BodySnapshot] = []
	var horizon := maxf(HORIZON, delta)
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
		var distance_sq := relative.length_squared()
		var combined_radius := radius + Collision.unit_radius(other)
		var reach := combined_radius + MARGIN + (speed + velocity.length()) * horizon
		if distance_sq > reach * reach:
			continue
		bodies.append(BodySnapshot.new(relative, velocity, combined_radius))
	return bodies

## Dictionary input remains useful to deterministic geometry probes. The live
## candidate loop uses typed snapshots directly, without repeated hash lookups.
static func _body_risk(velocity: Vector2, delta: float, bodies: Array[Dictionary], limit: float = INF) -> float:
	var snapshots: Array[BodySnapshot] = []
	for body in bodies:
		snapshots.append(BodySnapshot.new(body.relative, body.velocity, body.radius))
	return _snapshot_risk(velocity, delta, snapshots, limit)

static func _snapshot_risk(velocity: Vector2, delta: float, bodies: Array[BodySnapshot], limit: float = INF) -> float:
	var score := 0.0
	var motion := velocity * delta
	var motion_length := motion.length()
	for body in bodies:
		var relative: Vector2 = body.relative
		var radius: float = body.radius
		var distance_sq: float = body.distance_sq
		if distance_sq < body.radius_sq - 0.0001:
			if motion.dot(-relative) < -0.00001:
				return INF
		elif distance_sq < (radius + motion_length) * (radius + motion_length):
			# A farther body cannot be touched by this frame's swept circle.
			var closest := Geometry2D.get_closest_point_to_segment(relative, Vector2.ZERO, motion)
			if closest.distance_squared_to(relative) < body.radius_sq - 0.0001:
				return INF
		var relative_velocity: Vector2 = velocity - body.velocity
		var closing := relative.dot(relative_velocity)
		if closing <= 0.00001: continue
		var gap := body.gap
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
