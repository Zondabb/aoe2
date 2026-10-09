extends SceneTree

const Memory := preload("res://scripts/presentation/fog_memory.gd")
var report: Dictionary = {}
var crowd_tick := 0

func _initialize() -> void:
	call_deferred("_run")

func _measure(action: Callable, count: int) -> float:
	for warmup in 3: action.call()
	var started := Time.get_ticks_usec()
	for repetition in count: action.call()
	return float(Time.get_ticks_usec() - started) / (1000.0 * count)

func _sample(label: String, world: Node2D, holder: Node, moving: Array[UnitAgent] = []) -> void:
	var nodes: Array = world.get_node("Entities").get_children()
	var phases := {
		"entities": nodes.size(),
		"known": holder.fog.memories[0].size(),
		"proxies": holder.get("_memory_views").size(),
		"idle_physics_ms": _measure(func(): holder._physics_process(1.0 / 60.0), 60),
		"rebuild_ms": _measure(func(): holder.rebuild_now(), 30),
		"service_ms": _measure(func(): holder.fog.rebuild(nodes), 30),
		"memories_ms": _measure(func(): holder._update_memories(nodes), 30),
		"visibility_ms": _measure(func(): holder._apply_visibility(), 30),
	}
	report[label] = phases
	var timings: Array[float] = []
	for repetition in 100:
		if not moving.is_empty():
			crowd_tick += 1
			for index in moving.size(): moving[index].sim_pos = Vector2(-135 + (index % 8) * 6 + sin(crowd_tick * 0.07) * 16, -185 + floori(index / 8.0) * 6 + cos(crowd_tick * 0.09) * 16)
		var started := Time.get_ticks_usec()
		holder.rebuild_now()
		timings.append((Time.get_ticks_usec() - started) / 1000.0)
	timings.sort()
	phases["rebuild_p95_ms"] = timings[94]
	phases["rebuild_max_ms"] = timings[-1]
	print("DENSE FOG ", label, " ", JSON.stringify(phases))

func _run() -> void:
	var session := root.get_node("GameSession")
	session.match_ai_mode = "sandbox"
	session.match_map_data = {}
	var world := load("res://scenes/match_2d.tscn").instantiate() as Node2D
	root.add_child(world)
	await process_frame
	await process_frame
	var state: MatchState = world.get_node("Bootstrap").match_state
	state.frozen = true
	for entity in world.get_node("Entities").get_children(): entity.set_physics_process(false)
	var holder: Node = world.get_meta("fog_holder")
	holder.set_physics_process(false)
	_sample("opening", world, holder)
	var scout: UnitAgent = world.get_node("Entities/PlayerScout")
	var origin := scout.sim_pos
	scout.set_vision_radius(48.0)
	for node in world.get_node("Entities").get_children():
		if node.has_meta("map_record") and node.get_meta("map_record").get("resource_type") == "wood" and String(node.get_meta("map_record").id).ends_with("Tree001"):
			scout.sim_pos = node.sim_pos
			holder.rebuild_now()
			await process_frame
	scout.sim_pos = origin
	holder.rebuild_now()
	await process_frame
	_sample("explored_forests", world, holder)
	var moving: Array[UnitAgent] = []
	for index in 48:
		var worker := load("res://scenes/entities/unit_view.tscn").instantiate() as UnitAgent
		worker.def = GameCatalog.get_unit(&"villager")
		worker.team = 0
		worker.match_state = state
		worker.sim_pos = Vector2(-135 + (index % 8) * 6, -185 + floori(index / 8.0) * 6)
		world.get_node("Entities").add_child(worker)
		worker.set_physics_process(false)
		moving.append(worker)
	holder.rebuild_now()
	_sample("moving_crowd_48", world, holder, moving)
	var live_tree: Node2D = world.get_node("Entities/PlayerTree")
	report["tree_capture_ms"] = _measure(func(): Memory.capture(live_tree), 100)
	print("DENSE FOG tree_capture_ms=", report.tree_capture_ms)
	var output := "res://.godot/dense-fog-profile.json"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="): output = argument.trim_prefix("--output=")
	var file := FileAccess.open(output, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  ") + "\n")
	world.free()
	await process_frame
	quit()
