extends SceneTree
## CPU cost of lockstep frames (3 fixed steps + frame checksum) on the default
## map with a mid-game army, in one process. The final exhaustive state hash
## lets two code versions be compared for identical simulation results.
##   godot --headless --path . --script res://tests/bench_lockstep_frame.gd -- [units_per_side] [frames]
const Runtime := preload("res://scripts/network/network_match.gd")
const Simulation := preload("res://scripts/network/lockstep_simulation.gd")
const Loader := preload("res://scripts/world/map_loader.gd")
const FogAccess := preload("res://scripts/systems/fog_access.gd")

class FrameProbe extends Node:
	func send_frame(_tick: int, _commands: Array, _checksum: String) -> bool: return true
	func leave() -> void: pass
	func finish_match(_winner: int) -> void: pass

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var per_side := int(args[0]) if args.size() > 0 else 60
	var frames := int(args[1]) if args.size() > 1 else 60
	var game := root.get_node("GameSession")
	game.online_active = false
	game.online_spectator = false
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
	var centers := {}
	for entity in runtime.entities.get_children():
		if entity is BuildingAgent and entity.def.id == &"town_center": centers[int(entity.team)] = entity
	# Mid-game load: per side, a third villagers gathering, the rest an army
	# marching to the map centre where both armies meet.
	var kinds := ["villager", "archer", "man_at_arms", "spearman"]
	for side in [0, 1]:
		var base: Vector2 = centers[side].sim_pos
		var toward := (Vector2.ZERO - base).normalized()
		for i in per_side:
			var id: String = kinds[0] if i < per_side / 3 else kinds[1 + i % 3]
			var offset := Vector2(float(i % 10) * 1.5 - 7.0, float(i / 10) * 1.5 + 6.0)
			var record := {"id": "bench%d_%d" % [side, i], "type": "unit", "unit_id": id, "team": "player" if side == 0 else "ai", "pos": [base.x + toward.x * 10 + offset.x, base.y + toward.y * 10 + offset.y]}
			Loader.spawn_entity(record, runtime.entities, runtime.match_state, false, runtime._civs)
	await process_frame
	var sim := Simulation.new()
	sim.setup(runtime)
	runtime.simulation = sim
	var probe := FrameProbe.new()
	scene.add_child(probe)
	runtime.session = probe
	runtime.synchronized = true
	var counts := {}
	for id in runtime._net_entities:
		var kind: String = runtime._entity_kind(runtime._net_entities[id])
		counts[kind] = counts.get(kind, 0) + 1
	print("BENCH entities: ", counts, " children=", runtime.entities.get_child_count())
	var resources: Array = []
	for entity in runtime.entities.get_children():
		if entity is ResourceNode: resources.append(entity)
	for entity in runtime.entities.get_children():
		if entity is not UnitAgent: continue
		var side := int(entity.team)
		if entity.def.id == &"villager":
			var best: Node = null
			for resource in resources:
				if not FogAccess.state_can_see(runtime.match_state, side, resource): continue
				if best == null or resource.sim_pos.distance_squared_to(entity.sim_pos) < best.sim_pos.distance_squared_to(entity.sim_pos): best = resource
			# Each side commands its own units (submit_command speaks for the host team only).
			if best != null: runtime._queue_command({"op": "gather", "unit_id": runtime.entity_id(entity), "target_id": runtime.entity_id(best)}, side)
		else:
			runtime._queue_command({"op": "move", "unit_id": runtime.entity_id(entity), "pos": [float(side * 2 - 1) * 4.0, float(side * 2 - 1) * 4.0]}, side)
	# Warm up: execute queued orders and let the first path batch resolve.
	for _i in 3:
		runtime._advance_host_frame()
		runtime._guest_ack_tick = runtime.tick
	var frame_costs: Array = []
	var checksum_costs: Array = []
	var step_costs: Array = []
	var presentation_costs: Array = []
	var sprite_costs: Array = []
	var fog: Node = scene.get_node_or_null("FogOfWar")
	for _frame in frames:
		var frame_started := Time.get_ticks_usec()
		for _step in 3:
			var step_started := Time.get_ticks_usec()
			sim.step()
			step_costs.append(Time.get_ticks_usec() - step_started)
		var started := Time.get_ticks_usec()
		var _digest: String = sim.frame_checksum()
		checksum_costs.append(Time.get_ticks_usec() - started)
		runtime.tick += 3
		frame_costs.append(Time.get_ticks_usec() - frame_started)
		# One presentation pass per 100 ms frame, as FogOfWar does on render frames.
		if fog != null:
			started = Time.get_ticks_usec()
			fog._presentation_usec = 0
			fog._process(0.0)
			presentation_costs.append(Time.get_ticks_usec() - started)
		# Unit sprites drawn once per rendered frame (deferred during lockstep steps).
		started = Time.get_ticks_usec()
		for entity in runtime.entities.get_children():
			if entity is UnitAgent and entity.has_method("_flush_billboard_frame"): entity._flush_billboard_frame()
		sprite_costs.append(Time.get_ticks_usec() - started)
	frame_costs.sort()
	checksum_costs.sort()
	step_costs.sort()
	presentation_costs.sort()
	sprite_costs.sort()
	print("BENCH units/side=%d frames=%d" % [per_side, frames])
	print("BENCH frame (3 steps + frame checksum) ms: median %.1f p95 %.1f max %.1f" % [frame_costs[frames / 2] / 1000.0, frame_costs[int(frames * 0.95)] / 1000.0, frame_costs[-1] / 1000.0])
	print("BENCH single step ms: median %.2f p95 %.2f max %.2f" % [step_costs[step_costs.size() / 2] / 1000.0, step_costs[int(step_costs.size() * 0.95)] / 1000.0, step_costs[-1] / 1000.0])
	print("BENCH frame checksum ms: median %.2f max %.2f" % [checksum_costs[frames / 2] / 1000.0, checksum_costs[-1] / 1000.0])
	if not presentation_costs.is_empty():
		print("BENCH fog presentation pass ms: median %.2f max %.2f" % [presentation_costs[presentation_costs.size() / 2] / 1000.0, presentation_costs[-1] / 1000.0])
	print("BENCH unit sprite pass ms: median %.2f max %.2f" % [sprite_costs[sprite_costs.size() / 2] / 1000.0, sprite_costs[-1] / 1000.0])
	var started := Time.get_ticks_usec()
	var deep: String = sim.checksum()
	print("BENCH deep checksum ms %.1f" % [(Time.get_ticks_usec() - started) / 1000.0])
	print("BENCH final tick %d deep state %s" % [runtime.tick, deep])
	started = Time.get_ticks_usec()
	var full: Dictionary = sim.capture()
	var keyframe_text := JSON.stringify(full, "", true, true)
	print("BENCH keyframe capture+json ms %.1f size %d" % [(Time.get_ticks_usec() - started) / 1000.0, keyframe_text.length()])
	scene.queue_free()
	await process_frame
	quit(0)
