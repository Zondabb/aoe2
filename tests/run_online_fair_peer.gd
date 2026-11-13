extends "res://tests/run_incremental_peer.gd"

var submitted: Array = []
var resolved: Array = []
var timeline: Array = []
var timing_samples: Array = []
var predicted := 0
var invariant_checks := 0
var hooked := false
var last_sample_tick := -1
var movement_probe: Dictionary = {}
var movement_samples: Array = []
var probe_unit: UnitAgent
var probe_started := false

class MotionSampler extends Node:
	var test: SceneTree
	func _process(_delta: float) -> void:
		test._sample_motion()

func _map() -> Dictionary:
	var data := super._map()
	# Keep a separate worker away from construction, combat and other walkers.
	# This straight unobstructed path distinguishes reconciliation regressions
	# from a legitimate route reversal around an obstacle.
	for side in [0, 1]:
		var direction := -1 if side == 0 else 1
		data.entities.append({"id": "fair_mover%d" % side, "type": "unit", "unit_id": "villager", "team": "player" if side == 0 else "ai", "pos": [direction * 50, direction * 30]})
	return data

func _process(delta: float) -> bool:
	if arena != null and not hooked:
		var net := arena.get_node_or_null("NetworkMatch")
		if net != null:
			hooked = true
			net.command_submitted.connect(func(seq: int, source: int, target: int): submitted.append({"seq": seq, "source": source, "target": target, "wall_usec": Time.get_ticks_usec()}))
			net.command_resolved.connect(_resolved)
			var sampler := MotionSampler.new()
			sampler.test = self
			sampler.process_priority = 100
			arena.add_child(sampler)
	var result := super._process(delta)
	if runtime != null and runtime.synchronized and runtime.tick != last_sample_tick:
		last_sample_tick = runtime.tick
		timeline.append([runtime.tick, Time.get_unix_time_from_system() * 1000.0])
		if runtime.fair != null:
			timing_samples.append([runtime.tick, runtime.fair.rtt_usec / 1000.0, runtime.fair.input_delay_ticks, runtime.fair.delay_schedule.duplicate(true)])
	if runtime != null and runtime.synchronized and not runtime.spectator and runtime.tick >= 120 and not probe_started and not default_map:
		_start_motion_probe()
	return result

func _resolved(seq: int, accepted: bool, at_tick: int) -> void:
	var now := Time.get_ticks_usec()
	var elapsed := -1.0
	for item in submitted:
		if int(item.seq) == seq:
			elapsed = float(now - int(item.wall_usec)) / 1000.0
			break
	resolved.append({"seq": seq, "accepted": accepted, "tick": at_tick, "wall_usec": now, "confirmation_ms": elapsed})
	if not movement_probe.is_empty() and int(movement_probe.seq) == seq:
		movement_probe["accepted"] = accepted
		movement_probe["confirmation_ms"] = elapsed
		movement_probe["resolved"] = true

func _start_motion_probe() -> void:
	probe_started = true
	var side := -1 if int(runtime.local_team) == 0 else 1
	var expected := Vector2(side * 50, side * 30)
	for unit in runtime.entities.get_children():
		# map_id is editor metadata and is deliberately absent from keyframes.
		if unit is UnitAgent and unit.team == runtime.local_team and unit.def.id == &"villager" and unit.sim_pos.distance_squared_to(expected) < 0.01:
			probe_unit = unit
			break
	if probe_unit == null:
		_fail("isolated movement probe missing")
		return
	var target := probe_unit.sim_pos + Vector2(5, 0)
	var origin := probe_unit.render_global_transform(probe_unit).origin
	var screen_goal: Vector2 = runtime.entities.to_global(preload("res://scripts/presentation/iso_math.gd").world_to_screen(target))
	movement_probe = {"seq": runtime._local_input_seq + 1, "wall_usec": Time.get_ticks_usec(), "origin": origin, "direction": (screen_goal - origin).normalized(),
		"sim_origin": probe_unit.sim_pos, "visual_ms": -1.0, "authority_ms": -1.0, "confirmation_ms": -1.0, "resolved": false, "accepted": false,
		"previous_projection": 0.0, "maximum_projection": 0.0, "max_backward_px": 0.0, "max_backward_after_confirmation_px": 0.0, "max_retreat_after_confirmation_px": 0.0, "samples": 0}
	_send({"op": "move", "unit_id": runtime.entity_id(probe_unit), "pos": [target.x, target.y]})
	if not submitted.is_empty():
		movement_probe["source_tick"] = int(submitted.back().source)
		movement_probe["target_tick"] = int(submitted.back().target)
		movement_probe["delay_ticks"] = int(submitted.back().target) - int(submitted.back().source)
		movement_probe["match_speed"] = runtime.match_speed
		movement_probe["delay_schedule"] = runtime.fair.delay_schedule.duplicate(true)

func _sample_motion() -> void:
	if done or movement_probe.is_empty() or not is_instance_valid(probe_unit): return
	var age := float(Time.get_ticks_usec() - int(movement_probe.wall_usec)) / 1000.0
	# Sample through confirmation and catch-up, before the intentional keyframe
	# corruption at tick 210. Recovery deliberately clears all previews.
	if runtime.tick >= 195: return
	var drawn := probe_unit.render_global_transform(probe_unit).origin
	var projection := (drawn - (movement_probe.origin as Vector2)).dot(movement_probe.direction)
	var previous := float(movement_probe.previous_projection)
	var backwards := maxf(0.0, previous - projection)
	if float(movement_probe.visual_ms) < 0.0 and projection > 0.1: movement_probe.visual_ms = age
	if float(movement_probe.authority_ms) < 0.0 and probe_unit.sim_pos.distance_to(movement_probe.sim_origin) > 0.001: movement_probe.authority_ms = age
	movement_probe.max_backward_px = maxf(float(movement_probe.max_backward_px), backwards)
	if bool(movement_probe.resolved):
		movement_probe.max_backward_after_confirmation_px = maxf(float(movement_probe.max_backward_after_confirmation_px), backwards)
		movement_probe.max_retreat_after_confirmation_px = maxf(float(movement_probe.max_retreat_after_confirmation_px), float(movement_probe.maximum_projection) - projection)
	movement_probe.maximum_projection = maxf(float(movement_probe.maximum_projection), projection)
	movement_probe.previous_projection = projection
	movement_probe.samples += 1
	movement_samples.append([age, projection, probe_unit.sim_pos.x, probe_unit.sim_pos.y, bool(movement_probe.resolved), probe_unit._prediction_presentation_active])

func _send(command: Dictionary) -> void:
	var before: String = runtime.simulation.checksum()
	super._send(command)
	if runtime.prediction != null:
		if runtime.prediction.pending.has(runtime._local_input_seq): predicted += 1
		# The real render loop advances prediction. Do not inject artificial
		# time here, which would distort input-to-feedback measurements.
		runtime.prediction.advance(0.0)
	if before != runtime.simulation.checksum(): _fail("local prediction changed authoritative simulation")
	invariant_checks += 1

func _build() -> void:
	super._build()
	for unit in runtime.entities.get_children():
		if unit is UnitAgent and unit.team == runtime.local_team:
			_send({"op": "move", "unit_id": runtime.entity_id(unit), "pos": [999999, 999999]})
			_send({"op": "stop", "unit_id": runtime.entity_id(unit)})
			_send({"op": "move", "unit_id": runtime.entity_id(unit), "pos": [unit.sim_pos.x + 1, unit.sim_pos.y + 1]})
			break

func _write_report() -> void:
	super._write_report()
	var file := FileAccess.open(output, FileAccess.READ)
	var report: Dictionary = JSON.parse_string(file.get_as_text())
	file.close()
	report["submitted"] = submitted
	report["resolved"] = resolved
	report["timeline"] = timeline
	report["timing_samples"] = timing_samples
	report["predicted"] = predicted
	report["prediction_invariants"] = invariant_checks
	report["pending_predictions"] = runtime.prediction.pending.size() if runtime.prediction != null else 0
	var motion := movement_probe.duplicate(true)
	for key in ["origin", "direction", "sim_origin"]: motion.erase(key)
	report["movement_probe"] = motion
	report["movement_samples"] = movement_samples
	if runtime.fair != null:
		report["match_speed"] = runtime.match_speed
		report["rtt_ms"] = runtime.fair.rtt_usec / 1000.0
		report["input_delay_ticks"] = runtime.fair.input_delay_ticks
		report["delay_schedule"] = runtime.fair.delay_schedule.duplicate(true)
	file = FileAccess.open(output, FileAccess.WRITE)
	file.store_string(JSON.stringify(report))
