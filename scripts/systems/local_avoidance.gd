class_name LocalAvoidance
extends RefCounted
## Bounded velocity sampling with prediction and a consistent passing side,
## in integer fixed-point arithmetic only. It changes this step's velocity,
## never the static A* route.
##
## Units: lengths 1/1024 tile, velocities 1/1024 tile per second, time
## Fixed.TIME_SCALE (30720) per second. Every intermediate product is bounded
## (inputs clamped) to fit in signed 64 bits, and divisions use Fixed.mul_div
## rounding, so the GDExtension port (native/aoe_sim/src/avoidance.cpp) gives
## bit-identical results on every platform. Keep both files in step.
##
## Water shorelines are the only float geometry left; units near water use
## this script on every peer (the native solver accepts axis-aligned boxes).

const Fixed := preload("res://scripts/core/sim_fixed.gd")
const ShoreGeometry := preload("res://scripts/world/shore_geometry.gd")

const TIME_SCALE := 30720
## Prediction horizon, 0.9 s.
const HORIZON_TIME := 27648
## Extra clearance kept from predicted contacts, 0.12 tile.
const MARGIN_Q := 123
const SCORE_ONE := 65536
const RISK_INF := 1 << 60
const SCORE_INF := 1 << 62
## 0.18 × SCORE_ONE: continuity with the previous velocity.
const PREVIOUS_WEIGHT := 11796
## 0.08 × SCORE_ONE: prefer passing on the positive-angle side.
const SIDE_PENALTY := 5243
## 4 × SCORE_ONE at contact, falling linearly to 0 at the horizon.
const CONTACT_WEIGHT := 262144
const STATIC_LOOKAHEAD_PENALTY := 131072
## A solved direction is reused for up to 0.25 s (it was re-solved every
## 0.1 s, and every step for groups under 12 neighbours). Each reused step is
## still validated against current bodies, walls and map bounds.
const STEERING_INTERVAL_TIME := 7680
const REUSE_RISK_INCREASE := 16384
const REUSE_SPEED_PERCENT := 1
## cos(5°) in parts per million.
const REUSE_DIRECTION_PPM := 996195
## Same input clamps as UnitFieldScript / the native field.
const V_MAX := 8192
const RADIUS_MAX := 8192
## Positions, goals, boxes and bounds (16384 tiles; maps are far smaller).
const POS_MAX := 1 << 24
const STEP_TIME_MAX := 30720
## Candidate directions: [negative side, cos, sin] × 2^15, in search order
## 0, ±15, ±30, ±45, ±60, ±90, ±120, ±150, 180 degrees.
const ANGLES := [
	[0, 32768, 0], [0, 31651, 8481], [1, 31651, -8481], [0, 28378, 16384], [1, 28378, -16384],
	[0, 23170, 23170], [1, 23170, -23170], [0, 16384, 28378], [1, 16384, -28378], [0, 0, 32768],
	[1, 0, -32768], [0, -16384, 28378], [1, -16384, -28378], [0, -28378, 16384], [1, -28378, -16384],
	[0, -32768, 0]]

## Motion record shared with the native solver (PackedInt64Array):
## 0 from_x, 1 from_y, 2 radius, 3 preferred_vx, 4 preferred_vy,
## 5 previous_vx, 6 previous_vy, 7 step_time, 8 goal_x, 9 goal_y,
## 10 has_goal, 11 phase_key (net_id, spreads first re-solves over 6 phases).
## Boxes (stride 5): center_x, center_y, half_x, half_y, water index or -1;
## halves already include the unit radius. Bounds: enabled, min_x, min_y,
## max_x, max_y. Bodies (stride 5): rel_x, rel_y, vel_x, vel_y, combined radius.
static func motion_record(from: Vector2i, radius: int, preferred: Vector2i, previous: Vector2i, step_time: int, goal: Vector2i, has_goal: bool, phase_key: int) -> PackedInt64Array:
	return PackedInt64Array([from.x, from.y, radius, preferred.x, preferred.y, previous.x, previous.y, step_time, goal.x, goal.y, 1 if has_goal else 0, phase_key])

## Steering for one unit: native field without water, otherwise this script.
## Returns the destination for this step; `cache` carries the scheduled choice.
static func steer(field: RefCounted, self_key: int, motion: PackedInt64Array, boxes: PackedInt64Array, water: Array, bounds: PackedInt64Array, cache: Dictionary) -> Vector2i:
	if water.is_empty() and field.is_native():
		return field.steer(self_key, motion, boxes, bounds, cache)
	return steer_with_field(field, self_key, motion, boxes, water, bounds, cache)

static func steer_with_field(field: RefCounted, self_key: int, motion: PackedInt64Array, boxes: PackedInt64Array, water: Array, bounds: PackedInt64Array, cache: Dictionary) -> Vector2i:
	var from := Vector2i(clampi(motion[0], -POS_MAX, POS_MAX), clampi(motion[1], -POS_MAX, POS_MAX))
	var radius := clampi(motion[2], 0, RADIUS_MAX)
	var preferred := Vector2i(clampi(motion[3], -V_MAX, V_MAX), clampi(motion[4], -V_MAX, V_MAX))
	var previous := Vector2i(clampi(motion[5], -V_MAX, V_MAX), clampi(motion[6], -V_MAX, V_MAX))
	var step_time := clampi(motion[7], 0, STEP_TIME_MAX)
	var goal := Vector2i(clampi(motion[8], -POS_MAX, POS_MAX), clampi(motion[9], -POS_MAX, POS_MAX))
	var has_goal: bool = motion[10] != 0
	boxes = _bounded_boxes(boxes)
	bounds = _bounded_record(bounds)
	var speed_sq := _len_sq(preferred)
	if speed_sq == 0 or step_time <= 0:
		cache.clear()
		return from
	var speed := Fixed.isqrt(speed_sq)
	var horizon := maxi(HORIZON_TIME, step_time)
	var bodies: PackedInt64Array = field.gather(self_key, from, radius, speed, horizon)
	var near := nearby_boxes(from, speed, horizon, boxes)
	var static_time := static_horizon(from, speed, step_time, goal, has_goal)
	var initialized := cache.has("vx")
	var remaining: int = int(cache.get("rt", 0)) - step_time
	cache["rt"] = remaining
	if initialized and remaining > 0 and int(cache.gx) == goal.x and int(cache.gy) == goal.y and int(cache.hg) == int(has_goal) and int(cache.px) == from.x and int(cache.py) == from.y:
		var old := Vector2i(int(cache.ux), int(cache.uy))
		var old_speed := Fixed.isqrt(_len_sq(old))
		# Speed within 1 % and direction within 5° of the solved preference.
		if old_speed > 0 and absi(old_speed - speed) * 100 <= speed * REUSE_SPEED_PERCENT and _dot(old, preferred) * 1000000 >= REUSE_DIRECTION_PPM * old_speed * speed:
			var direct_risk := risk(preferred, step_time, bodies, RISK_INF)
			var direct_to := from + motion_for(preferred, step_time)
			if direct_risk == 0 and map_ok(direct_to, radius, bounds) and static_safe(from, from + motion_for(preferred, static_time), near, boxes, water, radius):
				cache["vx"] = preferred.x
				cache["vy"] = preferred.y
				cache["ux"] = preferred.x
				cache["uy"] = preferred.y
				cache["px"] = direct_to.x
				cache["py"] = direct_to.y
				cache["risk"] = 0
				cache["reused"] = int(cache.get("reused", 0)) + 1
				return direct_to
			var velocity := Vector2i(Fixed.mul_div(int(cache.vx), speed, old_speed), Fixed.mul_div(int(cache.vy), speed, old_speed))
			var velocity_sq := _len_sq(velocity)
			if velocity_sq > speed_sq:
				var length := Fixed.isqrt(velocity_sq)
				velocity = Vector2i(Fixed.mul_div(velocity.x, speed, length), Fixed.mul_div(velocity.y, speed, length))
				velocity_sq = _len_sq(velocity)
			var to := from + motion_for(velocity, step_time)
			# A stopped/blocked choice is reconsidered at once: a retained zero
			# velocity would turn temporary congestion into a stall.
			if velocity_sq * 100 > speed_sq and map_ok(to, radius, bounds):
				var retained := risk(velocity, step_time, bodies, RISK_INF)
				if retained < RISK_INF and retained <= int(cache.risk) + REUSE_RISK_INCREASE and direct_risk + REUSE_RISK_INCREASE >= retained and static_safe(from, to, near, boxes, water, radius) and static_safe(from, from + motion_for(velocity, static_time), near, boxes, water, radius):
					cache["px"] = to.x
					cache["py"] = to.y
					cache["reused"] = int(cache.get("reused", 0)) + 1
					return to
	var result := solve(from, radius, preferred, previous, step_time, bodies, near, boxes, water, bounds, static_time)
	var best := Vector2i(result[0], result[1])
	var destination := from + motion_for(best, step_time)
	cache["vx"] = best.x
	cache["vy"] = best.y
	cache["ux"] = preferred.x
	cache["uy"] = preferred.y
	cache["gx"] = goal.x
	cache["gy"] = goal.y
	cache["hg"] = int(has_goal)
	cache["px"] = destination.x
	cache["py"] = destination.y
	cache["risk"] = result[2]
	cache["rt"] = STEERING_INTERVAL_TIME if initialized else Fixed.mul_div(STEERING_INTERVAL_TIME, posmod(motion[11], 6) + 1, 6)
	cache["solved"] = int(cache.get("solved", 0)) + 1
	return destination

## Full candidate search. Returns [velocity_x, velocity_y, risk].
static func solve(from: Vector2i, radius: int, preferred: Vector2i, previous: Vector2i, step_time: int, bodies: PackedInt64Array, near: PackedInt32Array, boxes: PackedInt64Array, water: Array, bounds: PackedInt64Array, static_time: int) -> PackedInt64Array:
	var speed_sq := _len_sq(preferred)
	var direct_risk := risk(preferred, step_time, bodies, RISK_INF)
	if direct_risk == 0 and map_ok(from + motion_for(preferred, step_time), radius, bounds) and static_safe(from, from + motion_for(preferred, static_time), near, boxes, water, radius):
		return PackedInt64Array([preferred.x, preferred.y, 0])
	var best := Vector2i.ZERO
	var best_score := SCORE_INF
	var best_risk := RISK_INF
	for scale in 3:
		for index in ANGLES.size():
			if scale == 2 and index != 0: continue
			var velocity := Vector2i.ZERO
			if scale < 2:
				var angle: Array = ANGLES[index]
				velocity = rotate(preferred, angle[1], angle[2])
				if scale == 1: velocity = Vector2i(Fixed.mul_div(velocity.x, 1, 2), Fixed.mul_div(velocity.y, 1, 2))
			var destination := from + motion_for(velocity, step_time)
			if not map_ok(destination, radius, bounds): continue
			var score := Fixed.mul_div(_len_sq(velocity - preferred), SCORE_ONE, speed_sq) + Fixed.mul_div(_len_sq(velocity - previous), PREVIOUS_WEIGHT, speed_sq) + scale * SCORE_ONE
			if scale < 2 and int(ANGLES[index][0]) != 0: score += SIDE_PENALTY
			if score >= best_score: continue
			var candidate_risk := risk(velocity, step_time, bodies, best_score - score)
			score += candidate_risk
			if score >= best_score or not static_safe(from, destination, near, boxes, water, radius): continue
			if not static_safe(from, from + motion_for(velocity, static_time), near, boxes, water, radius):
				score += STATIC_LOOKAHEAD_PENALTY
			if score < best_score:
				best_score = score
				best = velocity
				best_risk = candidate_risk
	return PackedInt64Array([best.x, best.y, best_risk])

## Sum of predicted-contact penalties; RISK_INF when this step's swept circle
## would overlap a body (or push deeper into one already overlapping).
## Stops once the sum reaches `limit` (the caller then rejects the candidate).
@warning_ignore("integer_division")
static func risk(velocity: Vector2i, step_time: int, bodies: PackedInt64Array, limit: int) -> int:
	var motion := motion_for(velocity, step_time)
	var motion_sq := _len_sq(motion)
	var motion_length := Fixed.isqrt(motion_sq)
	if motion_length * motion_length < motion_sq: motion_length += 1
	var total := 0
	var index := 0
	var count := bodies.size()
	while index < count:
		var rx: int = bodies[index]
		var ry: int = bodies[index + 1]
		var ovx: int = bodies[index + 2]
		var ovy: int = bodies[index + 3]
		var combined: int = bodies[index + 4]
		index += 5
		var distance_sq := rx * rx + ry * ry
		var combined_sq := combined * combined
		if distance_sq < combined_sq:
			if motion.x * rx + motion.y * ry > 0: return RISK_INF
		elif distance_sq < (combined + motion_length) * (combined + motion_length):
			# Closest point of this step's segment to the body centre.
			var projection := clampi(rx * motion.x + ry * motion.y, 0, motion_sq)
			var cx := 0
			var cy := 0
			if motion_sq > 0:
				cx = Fixed.mul_div(motion.x, projection, motion_sq)
				cy = Fixed.mul_div(motion.y, projection, motion_sq)
			var ex := rx - cx
			var ey := ry - cy
			if ex * ex + ey * ey < combined_sq: return RISK_INF
		var rvx := velocity.x - ovx
		var rvy := velocity.y - ovy
		var closing := rx * rvx + ry * rvy
		if closing <= 0: continue
		var padded := combined + MARGIN_Q
		var gap := distance_sq - padded * padded
		var term := CONTACT_WEIGHT
		if gap > 0:
			var relative_sq := rvx * rvx + rvy * rvy
			if relative_sq == 0: continue
			var discriminant := closing * closing - relative_sq * gap
			if discriminant < 0: continue
			# Contact time num / relative_sq seconds; within 0.9 s ⇔ 10 num < 9 q.
			var numerator := closing - Fixed.isqrt(discriminant)
			if 10 * numerator >= 9 * relative_sq: continue
			term = CONTACT_WEIGHT - Fixed.mul_div(CONTACT_WEIGHT * 10, numerator, 9 * relative_sq)
		total += term
		if total >= limit: return total
	return total

static func static_horizon(from: Vector2i, speed: int, step_time: int, goal: Vector2i, has_goal: bool) -> int:
	# Stop predicting static travel at the destination. Workers finish beside
	# a resource; extending the velocity through it would penalize every approach.
	var horizon := maxi(HORIZON_TIME, step_time)
	if has_goal:
		var distance := Fixed.isqrt(_len_sq(goal - from))
		horizon = mini(horizon, maxi(step_time, Fixed.mul_div(distance, TIME_SCALE, speed)))
	return horizon

## Blockers whose footprint, widened by the full prediction reach, contains
## the unit (Rect2.has_point semantics: inclusive low, exclusive high edge).
static func nearby_boxes(from: Vector2i, speed: int, horizon: int, boxes: PackedInt64Array) -> PackedInt32Array:
	var near := PackedInt32Array()
	var reach := Fixed.mul_div(speed, horizon, TIME_SCALE)
	var index := 0
	while index < boxes.size():
		var hx: int = boxes[index + 2]
		var hy: int = boxes[index + 3]
		if hx > 0 and hy > 0:
			var ex := hx + reach
			var ey := hy + reach
			var cx: int = boxes[index]
			var cy: int = boxes[index + 1]
			if from.x >= cx - ex and from.x < cx + ex and from.y >= cy - ey and from.y < cy + ey:
				near.append(index)
		index += 5
	return near

static func static_safe(from: Vector2i, to: Vector2i, near: PackedInt32Array, boxes: PackedInt64Array, water: Array, radius: int) -> bool:
	for index in near:
		var center := Vector2i(boxes[index], boxes[index + 1])
		var water_index: int = boxes[index + 4]
		if water_index >= 0:
			if ShoreGeometry.segment_hits(Fixed.to_vector(from), Fixed.to_vector(to), Fixed.to_float(radius), water[water_index]): return false
		elif box_hit(from - center, to - from, Vector2i(boxes[index + 2] - 1, boxes[index + 3] - 1)):
			return false
	return true

## Segment from `origin` (relative to the box centre) by `motion` against an
## open box of half-extent `extent` (already inset one quantum, so travel along
## a face is allowed). Rational slab intervals: no division, no rounding.
static func box_hit(origin: Vector2i, motion: Vector2i, extent: Vector2i) -> bool:
	if extent.x <= 0 or extent.y <= 0: return false
	if absi(origin.x) < extent.x and absi(origin.y) < extent.y:
		var depth_x := extent.x - absi(origin.x)
		var depth_y := extent.y - absi(origin.y)
		# Already embedded: permit sliding or moving out via the nearest face.
		if depth_x <= depth_y and motion.x * signi(origin.x) >= 0: return false
		if depth_y <= depth_x and motion.y * signi(origin.y) >= 0: return false
		return true
	var near_num := 0
	var near_den := 1
	var far_num := 1
	var far_den := 1
	for axis in 2:
		var move: int = motion.x if axis == 0 else motion.y
		var start: int = origin.x if axis == 0 else origin.y
		var half: int = extent.x if axis == 0 else extent.y
		if move == 0:
			if absi(start) >= half: return false
			continue
		var denominator := absi(move)
		var first := -half - start
		var second := half - start
		if move < 0:
			var swap := first
			first = -second
			second = -swap
		if first * near_den > near_num * denominator:
			near_num = first
			near_den = denominator
		if second * far_den < far_num * denominator:
			far_num = second
			far_den = denominator
		if near_num * far_den > far_num * near_den: return false
	return true

static func map_ok(point: Vector2i, radius: int, bounds: PackedInt64Array) -> bool:
	if bounds.is_empty() or bounds[0] == 0: return true
	return point.x >= bounds[1] + radius and point.x <= bounds[3] - radius and point.y >= bounds[2] + radius and point.y <= bounds[4] - radius

static func motion_for(velocity: Vector2i, time: int) -> Vector2i:
	return Vector2i(Fixed.mul_div(velocity.x, time, TIME_SCALE), Fixed.mul_div(velocity.y, time, TIME_SCALE))

static func rotate(vector: Vector2i, cosine: int, sine: int) -> Vector2i:
	return Vector2i(Fixed.mul_div(vector.x * cosine - vector.y * sine, 1, 32768), Fixed.mul_div(vector.x * sine + vector.y * cosine, 1, 32768))

## Clamp external geometry to POS_MAX (no copy in the normal case).
static func _bounded_boxes(boxes: PackedInt64Array) -> PackedInt64Array:
	for value in boxes:
		if value > POS_MAX or value < -POS_MAX:
			var bounded := boxes.duplicate()
			for index in bounded.size():
				bounded[index] = clampi(bounded[index], -POS_MAX, POS_MAX)
			return bounded
	return boxes

static func _bounded_record(bounds: PackedInt64Array) -> PackedInt64Array:
	if bounds.size() < 5 or bounds[0] == 0: return PackedInt64Array([0, 0, 0, 0, 0])
	return PackedInt64Array([1, clampi(bounds[1], -POS_MAX, POS_MAX), clampi(bounds[2], -POS_MAX, POS_MAX), clampi(bounds[3], -POS_MAX, POS_MAX), clampi(bounds[4], -POS_MAX, POS_MAX)])

static func _len_sq(vector: Vector2i) -> int:
	return int(vector.x) * vector.x + int(vector.y) * vector.y

static func _dot(a: Vector2i, b: Vector2i) -> int:
	return int(a.x) * b.x + int(a.y) * b.y
