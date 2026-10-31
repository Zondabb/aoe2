extends SceneTree
## Lockstep frames through a melee/archer battle: units, targets and arrows are
## freed while the step order, interpolation hold and frame digest still hold
## references to them. Any engine or script error raised meanwhile (such as
## "Left operand of 'is' is a previously freed instance") fails the test.
const Runtime := preload("res://scripts/network/network_match.gd")
const Simulation := preload("res://scripts/network/lockstep_simulation.gd")
const Loader := preload("res://scripts/world/map_loader.gd")

class ErrorCounter extends Logger:
	var errors: Array[String] = []
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])
	func _log_message(_message: String, _error: bool) -> void:
		pass

class FrameProbe extends Node:
	func send_frame(_tick: int, _commands: Array, _checksum: String) -> bool: return true
	func leave() -> void: pass
	func finish_match(_winner: int) -> void: pass

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var logger := ErrorCounter.new()
	var game := root.get_node("GameSession")
	game.online_active = false
	game.match_ai_mode = "sandbox"
	game.match_map_data = {}
	game.pending_save_data = {}
	var scene: Node = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	await process_frame
	await process_frame
	var bootstrap: Node = scene.get_node("Bootstrap")
	var runtime: Node = Runtime.new()
	runtime.name = "NetworkMatch"
	scene.add_child(runtime)
	runtime.match_state = bootstrap.match_state
	runtime.entities = scene.get_node("Entities")
	runtime.map_bounds = bootstrap.map_bounds
	runtime._civs = {0: bootstrap.player_civ, 1: bootstrap.ai_civ}
	runtime.is_host = true
	runtime._playing = true
	runtime.set_process(false)
	runtime.set_physics_process(false)
	var kinds := ["man_at_arms", "archer", "spearman"]
	for side in [0, 1]:
		for i in 18:
			var pos := Vector2(float(i % 6) * 1.4 - 3.5, (1.5 + float(i / 6) * 1.4) * (1.0 if side == 1 else -1.0))
			Loader.spawn_entity({"id": "fight%d_%d" % [side, i], "type": "unit", "unit_id": kinds[i % 3], "team": "player" if side == 0 else "ai", "pos": [pos.x, pos.y]}, runtime.entities, runtime.match_state, false, runtime._civs)
	await process_frame
	var sim := Simulation.new()
	sim.setup(runtime)
	runtime.simulation = sim
	runtime.session = FrameProbe.new()
	scene.add_child(runtime.session)
	runtime.synchronized = true
	runtime._guest_ack_tick = 0
	var fighters: Array = []
	for entity in runtime.entities.get_children():
		if entity is UnitAgent and entity.has_meta("map_id") and String(entity.get_meta("map_id")).begins_with("fight"): fighters.append(entity)
	for unit in fighters:
		var nearest: Node = null
		for other in fighters:
			if other.team != unit.team and (nearest == null or other.sim_pos.distance_squared_to(unit.sim_pos) < nearest.sim_pos.distance_squared_to(unit.sim_pos)): nearest = other
		runtime._queue_command({"op": "attack", "unit_id": runtime.entity_id(unit), "target_id": runtime.entity_id(nearest)}, int(unit.team))
	var start := fighters.size()
	OS.add_logger(logger)
	for frame in 300:
		runtime._begin_host_frame()
		while runtime._frame_step < 3:
			runtime._step_frame()
			# Physics ticks without a step run between steps in live play.
			sim.hold_interpolation()
		runtime._finish_host_frame()
		runtime._guest_ack_tick = runtime.tick
		sim.hold_interpolation()
		var alive := 0
		for unit in fighters:
			if is_instance_valid(unit) and not unit.is_queued_for_deletion(): alive += 1
		if alive <= start / 2 and frame > 30: break
	OS.remove_logger(logger)
	var survivors := 0
	for unit in fighters:
		if is_instance_valid(unit) and not unit.is_queued_for_deletion(): survivors += 1
	for error in logger.errors.slice(0, 5): print("  error: ", error)
	var ok := survivors < start and logger.errors.is_empty()
	print("LOCKSTEP COMBAT FRAMES %s: %d of %d fighters left after tick %d, %d errors" % ["PASSED" if ok else "FAILED", survivors, start, runtime.tick, logger.errors.size()])
	scene.queue_free()
	await process_frame
	quit(0 if ok else 1)
