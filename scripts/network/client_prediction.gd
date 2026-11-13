extends Node2D

## A bounded visual preview, never a second gameplay simulation. Input records
## live only on the issuing peer. Confirmed frames remain the source of truth.
const Iso := preload("res://scripts/presentation/iso_math.gd")
const FogAccess := preload("res://scripts/systems/fog_access.gd")
const MAX_PENDING := 256
const PENDING_TIMEOUT_SEC := 3.0
const PREDICTION_HORIZON_SEC := 0.45
const MAX_DISPLACEMENT := 2.0
const CORRECTION_RATE := 18.0
## An accepted straight move consumes its visual lead by moving more slowly
## than the confirmed unit. It must not be lerped backwards to an older pose.
const CATCHUP_VISUAL_SPEED := 0.35
const CATCHUP_STALL_SEC := 0.75
const CATCHUP_LATERAL_LIMIT := 0.35
const PREVIEW_COLOR := Color(0.95, 0.78, 0.22, 0.85)
const MOTION_OPS := ["move", "stop", "attack", "gather", "build"]
const LABELS := {
	"train": "训练待确认", "cancel_train": "取消待确认",
	"research_age": "升级待确认", "cancel_research_age": "取消待确认",
	"research_technology": "研究待确认", "cancel_technology": "取消待确认",
	"set_gate_state": "城门待确认",
}

var network: Node
var pending: Dictionary = {}
var _motions: Dictionary = {}
var _highest_seq := 0
var _wall_clock_usec := 0
var _nav: Object


func setup(runtime: Node) -> void:
	clear()
	network = runtime
	process_priority = 50 # after sprite refresh, before the occlusion mask
	z_index = 80
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_wall_clock_usec = Time.get_ticks_usec()
	if is_instance_valid(network) and network.get_parent() != null:
		var holder := network.get_parent().get_node_or_null("NavService")
		if holder != null: _nav = holder.get("nav")
	set_process(true)


## Call only after successful local submission. A sequence number is local to
## this player; the transport associates the peer identity with the command.
func submit(seq: int, command: Dictionary) -> bool:
	if not _can_predict() or seq <= _highest_seq or pending.size() >= MAX_PENDING:
		return false
	_highest_seq = seq
	var op := str(command.get("op", ""))
	if op not in MOTION_OPS and op not in LABELS and op not in ["place_building", "place_wall"]:
		return false
	var actor_id := int(command.get("unit_id", command.get("builder_id", command.get("building_id", -1))))
	var actor := _entity(actor_id)
	if actor == null or actor.get("team") != network.get("local_team") or not _alive(actor): return false
	var entry := {"command": command.duplicate(true), "actor_id": actor_id, "age": 0.0}
	pending[seq] = entry
	if op in MOTION_OPS and actor is UnitAgent:
		var unit := actor as UnitAgent
		var position := unit.sim_pos
		if _motions.has(actor_id): position = _motions[actor_id].position
		var goal: Variant = _goal(command, unit)
		if goal != null:
			_motions[actor_id] = {"seq": seq, "unit": weakref(unit), "position": position,
				"goal": position if op == "stop" else goal, "age": 0.0, "returning": false,
				"accepted": false, "authority_position": unit.sim_pos, "stalled": 0.0,
				"direction": (goal as Vector2).direction_to(position) * -1.0,
				"speed": _speed(unit, command), "op": op, "target_id": int(command.get("target_id", command.get("building_id", -1)))}
			unit.set_prediction_presentation(position)
	queue_redraw()
	return true


## Resolve after applying the corresponding authoritative frame, not merely
## after receiving it. A successful forward move keeps its displayed position
## and lets truth catch up. Only rejected/changed routes need a return motion.
func resolve(seq: int, accepted: bool) -> void:
	if not pending.has(seq): return
	var id: int = pending[seq].actor_id
	pending.erase(seq)
	if _motions.has(id) and int(_motions[id].seq) == seq:
		var motion: Dictionary = _motions[id]
		var unit: Variant = motion.unit.get_ref()
		motion.accepted = accepted and is_instance_valid(unit) and _matches_authority(unit, motion)
		motion.returning = not motion.accepted
		if is_instance_valid(unit): motion.authority_position = unit.sim_pos
		motion.stalled = 0.0
	queue_redraw()


func clear() -> void:
	for motion in _motions.values():
		var unit: Variant = motion.unit.get_ref()
		if is_instance_valid(unit): unit.clear_prediction_presentation()
	_motions.clear()
	pending.clear()
	if is_inside_tree(): queue_redraw()


func _exit_tree() -> void:
	clear()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var wall := float(now - _wall_clock_usec) / 1000000.0 if _wall_clock_usec > 0 else 0.0
	_wall_clock_usec = now
	advance(wall)


## Real seconds; caller and tests need not depend on Engine.time_scale. Long
## render stalls expire previews but never teleport them far ahead of truth.
func advance(wall_delta: float) -> void:
	if not is_finite(wall_delta) or wall_delta < 0.0: return
	if not _can_predict():
		clear()
		return
	var step := minf(wall_delta, 0.1)
	for seq in pending.keys():
		pending[seq].age += wall_delta
		var actor := _entity(int(pending[seq].actor_id))
		if actor == null or not _alive(actor) or float(pending[seq].age) >= PENDING_TIMEOUT_SEC:
			resolve(int(seq), false)
	for id in _motions.keys():
		var motion: Dictionary = _motions[id]
		var actor: Variant = motion.unit.get_ref()
		if not is_instance_valid(actor) or not _alive(actor) or actor.get("team") != network.get("local_team"):
			if is_instance_valid(actor): actor.clear_prediction_presentation()
			_motions.erase(id)
			continue
		var unit := actor as UnitAgent
		motion.age += wall_delta
		if motion.accepted and not motion.returning:
			if _advance_accepted(unit, motion, wall_delta):
				unit.clear_prediction_presentation()
				_motions.erase(id)
				continue
		if motion.returning:
			motion.position = (motion.position as Vector2).lerp(unit.sim_pos, 1.0 - exp(-CORRECTION_RATE * step))
			if (motion.position as Vector2).distance_squared_to(unit.sim_pos) < 0.0004:
				unit.clear_prediction_presentation()
				_motions.erase(id)
				continue
		elif not motion.accepted and float(motion.age) <= PREDICTION_HORIZON_SEC:
			var goal: Vector2 = motion.goal
			var current: Vector2 = motion.position
			var remaining := current.distance_to(goal)
			# Interactions stop before the target. No speculative hit, resource
			# transfer, construction work or vision update is ever performed.
			if motion.op in ["attack", "gather", "build"]:
				var target := _entity(int(motion.target_id))
				if target == null or not FogAccess.state_can_see(unit.match_state, int(unit.team), target):
					motion.returning = true
				else:
					remaining = maxf(0.0, remaining - _interaction_distance(target, unit))
			var amount := minf(remaining, float(motion.speed) * step * _match_speed())
			if not motion.returning and amount > 0.0:
				var candidate := current.move_toward(goal, amount)
				if candidate.distance_to(unit.sim_pos) <= MAX_DISPLACEMENT and _safe_segment(unit, current, candidate):
					motion.position = candidate
		# The horizon freezes the visual preview; only confirmation or timeout
		# starts correction. Never drift forward indefinitely on a lost packet.
		unit.set_prediction_presentation(motion.position)
	if not pending.is_empty(): queue_redraw()


## No speculative state is replayed: this only changes a canvas position.
## Return true once the authority has actually reached/passed the drawn pose.
func _advance_accepted(unit: UnitAgent, motion: Dictionary, wall_delta: float) -> bool:
	var actual := unit.sim_pos
	var previous: Vector2 = motion.authority_position
	var travelled := actual - previous
	var direction: Vector2 = motion.direction
	var visual: Vector2 = motion.position
	motion.authority_position = actual
	if not _matches_authority(unit, motion) or direction.is_zero_approx() or not _safe_segment(unit, actual, visual):
		motion.returning = true
		return false
	var gap := visual - actual
	var lead := gap.dot(direction)
	var lateral := gap - direction * lead
	# Collision avoidance, a changed path or a displaced interaction target
	# can invalidate the visual route even when the input itself was accepted.
	if lateral.length() > CATCHUP_LATERAL_LIMIT or travelled.dot(direction) < -0.0001 or (travelled.length_squared() > 0.000001 and travelled.normalized().dot(direction) < 0.5):
		motion.returning = true
		return false
	if lead <= 0.0:
		motion.position = actual
		return true
	if travelled.dot(direction) > 0.0001:
		motion.stalled = 0.0
		motion.position = visual + travelled * CATCHUP_VISUAL_SPEED
	else:
		motion.stalled += wall_delta
		if float(motion.stalled) >= CATCHUP_STALL_SEC: motion.returning = true
	return false


func _matches_authority(unit: UnitAgent, motion: Dictionary) -> bool:
	match str(motion.op):
		"move":
			return unit.order == Enums.OrderType.MOVE and unit._requested_move_target.distance_squared_to(motion.goal) < 0.002
		"attack":
			return unit.order == Enums.OrderType.ATTACK and unit._attack_target == _entity(int(motion.target_id))
		"gather":
			return unit.order == Enums.OrderType.GATHER and unit._gather_target == _entity(int(motion.target_id))
		"build":
			return unit.order == Enums.OrderType.BUILD and unit._build_target == _entity(int(motion.target_id))
	return false


func _can_predict() -> bool:
	if not is_instance_valid(network) or network.get("spectator") == true: return false
	if network.get("local_team") not in [0, 1] or network.get("synchronized") != true: return false
	if network.get("_terminal") == true or network.get("_awaiting_keyframe") == true: return false
	var state: Variant = network.get("match_state")
	return state != null and state.get("frozen") != true


func _entity(id: int) -> Node2D:
	if not is_instance_valid(network) or id < 0: return null
	return network.call("_resolve", id) as Node2D


func _alive(actor: Node2D) -> bool:
	return is_instance_valid(actor) and not actor.is_queued_for_deletion() and (actor.get("hp") == null or float(actor.get("hp")) > 0.0)


func _goal(command: Dictionary, unit: UnitAgent) -> Variant:
	var op := str(command.op)
	if op == "stop": return unit.sim_pos
	if op == "move":
		var raw: Variant = command.get("pos")
		if raw is not Array or raw.size() != 2: return null
		if not (raw[0] is int or raw[0] is float) or not (raw[1] is int or raw[1] is float): return null
		var result := Vector2(float(raw[0]), float(raw[1]))
		if not result.is_finite() or not (network.get("map_bounds") as Rect2).has_point(result): return null
		return result
	var target := _entity(int(command.get("target_id", command.get("building_id", -1))))
	if target == null or not FogAccess.state_can_see(unit.match_state, int(unit.team), target): return null
	return target.get("sim_pos")


func _speed(unit: UnitAgent, command: Dictionary) -> float:
	if unit.def == null: return 0.0
	var speed := unit.def.move_speed
	if command.get("formation_speed") is int or command.get("formation_speed") is float:
		var formation := float(command.formation_speed)
		if is_finite(formation) and formation > 0.0: speed = minf(speed, formation)
	return maxf(speed, 0.0)


func _match_speed() -> float:
	var speed: Variant = network.get("match_speed")
	return clampf(float(speed), 0.25, 4.0) if speed is int or speed is float else 1.0


func _interaction_distance(target: Node2D, unit: UnitAgent) -> float:
	var result := 0.8
	if target is BuildingAgent and target.def != null:
		result += maxf(target.def.footprint.x, target.def.footprint.y) * 0.5
	elif target is ResourceNode:
		result += maxf(target.block_size.x, target.block_size.y) * 0.5
	if unit.def != null and unit.def.is_ranged: result = maxf(result, unit.def.attack_range)
	return result


func _safe_segment(unit: UnitAgent, from: Vector2, to: Vector2) -> bool:
	var bounds: Rect2 = network.get("map_bounds")
	if not bounds.has_point(to): return false
	# Check known visibility before touching the navigation grid: unseen
	# obstacles cannot be inferred from a prediction stopping prematurely.
	var state := unit.match_state
	if state != null and state.fog_enabled:
		if state.fog == null: return false
		var radius := unit.def.resolved_footprint_radius() if unit.def != null else 0.4
		for point in [from, from.lerp(to, 0.5), to]:
			if not state.fog.footprint_visible(int(unit.team), point, Vector2.ONE * radius * 2.0, true): return false
	if _nav != null and is_instance_valid(_nav):
		return bool(_nav.call("_line_clear", from, to))
	return true


func _screen(world: Vector2) -> Vector2:
	var holder: Node2D = network.get("entities")
	return to_local(holder.to_global(Iso.world_to_screen(world))) if holder != null else Iso.world_to_screen(world)


func _draw() -> void:
	if not _can_predict(): return
	var labels: Dictionary = {}
	for entry in pending.values():
		var command: Dictionary = entry.command
		var op := str(command.op)
		var actor := _entity(int(entry.actor_id))
		if actor == null: continue
		if op == "place_building":
			var definition := GameCatalog.get_building(StringName(command.get("building_def_id", "")))
			var raw: Variant = command.get("pos")
			if definition != null and raw is Array and raw.size() == 2:
				var center := Vector2(float(raw[0]), float(raw[1]))
				var half := definition.footprint * 0.5
				var corners := PackedVector2Array()
				for offset in [Vector2(-half.x, -half.y), Vector2(half.x, -half.y), Vector2(half.x, half.y), Vector2(-half.x, half.y), Vector2(-half.x, -half.y)]:
					corners.append(_screen(center + offset))
				draw_polyline(corners, PREVIEW_COLOR, 2.0, true)
				_draw_label(_screen(center), "建造待确认")
		elif op == "place_wall":
			var a: Variant = command.get("start")
			var b: Variant = command.get("end")
			if a is Array and a.size() == 2 and b is Array and b.size() == 2:
				var start := _screen(Vector2(float(a[0]), float(a[1])))
				var end := _screen(Vector2(float(b[0]), float(b[1])))
				draw_dashed_line(start, end, PREVIEW_COLOR, 2.0, 6.0, true)
				_draw_label((start + end) * 0.5, "城墙待确认")
		elif op in LABELS:
			var id := int(entry.actor_id)
			if not labels.has(id): labels[id] = {"actor": actor, "text": LABELS[op], "count": 0}
			labels[id].count += 1
	for label in labels.values():
		_draw_label(_screen(label.actor.get("sim_pos")) + Vector2(0, -36), str(label.text) + (" ×%d" % label.count if label.count > 1 else ""))


func _draw_label(at: Vector2, value: String) -> void:
	var font := ThemeDB.fallback_font
	var width := font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
	var origin := at + Vector2(-width * 0.5, -12)
	draw_string_outline(font, origin, value, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, 3, Color(0.1, 0.08, 0.02))
	draw_string(font, origin, value, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, PREVIEW_COLOR)
