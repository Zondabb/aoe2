extends SceneTree
## Real-renderer comparisons reload the same save for each scenario. Never writes
## the input file. Microprofile advances exactly one 1/60 simulation tick per sample.
const SAMPLE_SECONDS := 5.0
const WARMUP_SECONDS := 2.0
var world: Node
var results := {}
var save_path := "res://.godot/performance-user-save.json"
var label := "before"
var scenarios: Array[String] = ["saved_camera", "no_ai", "no_fog", "no_minimap", "no_outline", "render_only", "zoom_1", "selected_worker", "selected_town_center"]

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if "--components-only" in args: scenarios.clear()
	for option in ["--save", "--label", "--scenario"]:
		var at := args.find(option)
		if at < 0 or at + 1 >= args.size(): continue
		if option == "--save": save_path = args[at + 1]
		elif option == "--label": label = args[at + 1].validate_filename()
		else: scenarios.assign([args[at + 1]])
	Engine.max_fps = 0
	if DisplayServer.get_name() != "headless": DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	root.size = Vector2i(1280, 720)
	UnitDebugFocus.set_spectator_mode(true)
	results = {"renderer": DisplayServer.get_name(), "gpu": RenderingServer.get_video_adapter_name(), "sample_seconds": SAMPLE_SECONDS,
		"warmup_seconds": WARMUP_SECONDS, "resolution": [1280, 720], "scenarios": {}}
	for scenario in scenarios:
		if not await _load_match(): return
		_configure(scenario)
		results.scenarios[scenario] = await _sample()
		print("SAVED MATCH ", scenario, " ", JSON.stringify(results.scenarios[scenario]))
		await _unload()
	if "--live-only" not in args:
		if not await _load_match(): return
		results["components"] = await _profile_components()
		results["details"] = _profile_details()
		await _unload()
	var file := FileAccess.open("res://.godot/saved-match-performance-%s.json" % label, FileAccess.WRITE)
	file.store_string(JSON.stringify(results, "  "))
	file.close()
	print("SAVED MATCH PERFORMANCE saved: .godot/saved-match-performance-%s.json" % label)
	quit()

func _load_match() -> bool:
	var saves: GDScript = load("res://scripts/core/save_game_service.gd")
	var error: String = saves.prepare_load(save_path)
	if not error.is_empty():
		push_error(error)
		quit(1)
		return false
	world = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(world)
	current_scene = world
	for frame in 4: await process_frame
	world.get_node("Camera2D").set_process(false)
	var ai := world.get_node_or_null("AiController")
	if ai != null and ai.decision_log != null: ai.decision_log.enabled = false
	return true

func _outline() -> Node:
	return root.get_meta("unit_occlusion_renderer", null)

func _configure(scenario: String) -> void:
	match scenario:
		"no_ai": world.get_node("AiController").set_process(false)
		"no_fog": world.get_node("FogOfWar").set_physics_process(false)
		"no_minimap": world.get_node("UILayer/HUD/Minimap").set_process(false)
		"no_outline":
			var outline := _outline()
			if outline != null: outline.enabled = false
		"render_only":
			world.get_node("AiController").set_process(false)
			world.get_node("NavService").set_process(false)
			world.get_node("LandSupport").set_process(false)
			for entity in world.get_node("Entities").get_children(): entity.set_physics_process(false)
		"zoom_1": world.get_node("Camera2D").zoom = Vector2.ONE
		"selected_worker", "selected_town_center":
			for entity in world.get_node("Entities").get_children():
				if entity.get("team") != 0: continue
				if scenario == "selected_worker" and entity is UnitAgent and entity.def.id == &"villager" or scenario == "selected_town_center" and entity is BuildingAgent and entity.def.id == &"town_center":
					world.get_node("UILayer/SelectionController")._add_selection(entity)
					UnitDebugFocus.clear_focus()
					break

func _sample() -> Dictionary:
	var until := Time.get_ticks_msec() + int(WARMUP_SECONDS * 1000)
	while Time.get_ticks_msec() < until: await process_frame
	var samples := {"frame_ms": [], "process_ms": [], "physics_ms": [], "outline_ms": [], "draw_calls": [], "nav_pending": []}
	var previous := Time.get_ticks_usec()
	until = Time.get_ticks_msec() + int(SAMPLE_SECONDS * 1000)
	while Time.get_ticks_msec() < until:
		await process_frame
		var now := Time.get_ticks_usec()
		samples.frame_ms.append((now - previous) / 1000.0)
		previous = now
		samples.process_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		samples.physics_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		samples.draw_calls.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		var outline := _outline()
		samples.outline_ms.append(outline.last_update_usec / 1000.0 if outline != null else 0.0)
		samples.nav_pending.append(world.get_node("NavService").nav.pending_count())
	var report := {"units": get_nodes_in_group("units").size(), "buildings": get_nodes_in_group("buildings").size(),
		"resources": get_nodes_in_group("resource_nodes").size(), "entity_children": world.get_node("Entities").get_child_count(), "frames": samples.frame_ms.size()}
	for key in samples: report[key] = _stats(samples[key])
	return report

func _profile_components() -> Dictionary:
	_disable_processing(world)
	var outline := _outline()
	if outline != null: outline.set_process(false)
	var samples := {}
	for name in ["fog", "units", "buildings", "support", "ai", "navigation", "minimap", "hud", "outline", "total_cpu"]: samples[name] = []
	for frame in 330:
		var started := Time.get_ticks_usec()
		_time(samples.fog, func(): world.get_node("FogOfWar")._physics_process(1.0 / 60.0))
		_time(samples.units, func():
			for unit in get_nodes_in_group("units"): unit._physics_process(1.0 / 60.0))
		_time(samples.buildings, func():
			for building in get_nodes_in_group("buildings"): building._physics_process(1.0 / 60.0))
		_time(samples.support, func(): world.get_node("LandSupport")._process(1.0 / 60.0))
		_time(samples.ai, func(): world.get_node("AiController")._process(1.0 / 60.0))
		_time(samples.navigation, func(): world.get_node("NavService")._process(1.0 / 60.0))
		_time(samples.minimap, func(): world.get_node("UILayer/HUD/Minimap")._process(1.0 / 60.0))
		_time(samples.hud, func(): world.get_node("UILayer/HUD")._process(1.0 / 60.0))
		_time(samples.outline, func():
			if outline != null: outline.update_mask())
		samples.total_cpu.append((Time.get_ticks_usec() - started) / 1000.0)
		await process_frame
		_disable_processing(world)
	var report := {}
	for name in samples: report[name] = _stats(samples[name].slice(30))
	print("SAVED MATCH COMPONENTS ", JSON.stringify(report))
	return report

func _profile_details() -> Dictionary:
	var fog: Node = world.get_node("FogOfWar")
	var mini: Control = world.get_node("UILayer/HUD/Minimap")
	var hud: Control = world.get_node("UILayer/HUD")
	var tasks := {
		"fog_masks": func(): fog.fog.rebuild(fog._vision_sources),
		"fog_memories": func(): fog._update_memories(fog._live_entities),
		"fog_record_checks": func():
			for record in fog._static_records: fog._refresh_static_record(record),
		"fog_rect_tests": func():
			for record in fog._static_records:
				for team in 2: fog.fog.rect_visible(team, record.cells),
		"fog_resource_snapshots": func():
			for record in fog._static_records:
				if record.kind == "resource" and (fog._static_seen[0].get(record.id, false) or fog._static_seen[1].get(record.id, false)):
					fog._resource_snapshot(record.entity, record.id),
		"fog_memory_proxies": func(): fog._sync_memory_views(),
		"fog_visibility": func(): fog._apply_visibility(true, true),
		"fog_texture": func():
			fog._texture_revision = -1
			fog._sync_texture(),
		"minimap_terrain": func():
			mini._terrain_key.clear()
			mini._sync_terrain(),
		"minimap_markers": func(): mini.refresh_markers(),
		"minimap_mesh": func(): mini._rebuild_marker_mesh(),
		"ai_evaluate_capture": func(): world.get_node("AiController").evaluate_capture(100),
	}
	var report := {}
	for name in tasks:
		var times: Array = []
		for step in 15: _time(times, tasks[name])
		report[name] = _stats(times.slice(3))
	for entity in world.get_node("Entities").get_children():
		if entity is UnitAgent and entity.team == 0 and entity.def.id == &"villager":
			world.get_node("UILayer/SelectionController")._add_selection(entity)
			UnitDebugFocus.clear_focus()
			break
	var times: Array = []
	for step in 30: _time(times, func(): hud._process(1.0 / 60.0))
	report["hud_selected_worker"] = _stats(times.slice(3))
	print("SAVED MATCH DETAILS ", JSON.stringify(report))
	return report

func _time(samples: Array, action: Callable) -> void:
	var started := Time.get_ticks_usec()
	action.call()
	samples.append((Time.get_ticks_usec() - started) / 1000.0)

func _disable_processing(node: Node) -> void:
	node.set_process(false)
	node.set_physics_process(false)
	for child in node.get_children(): _disable_processing(child)

func _unload() -> void:
	current_scene = null
	world.free()
	var outline := _outline()
	if outline != null: outline.free()
	root.remove_meta("unit_occlusion_renderer")
	for frame in 3: await process_frame

func _stats(values: Array) -> Dictionary:
	values.sort()
	var total := 0.0
	for value in values: total += float(value)
	return {"mean": snappedf(total / values.size(), 0.001), "p50": values[int(values.size() * 0.5)], "p95": values[int(values.size() * 0.95)], "max": values.back()}
