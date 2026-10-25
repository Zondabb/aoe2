extends SceneTree
## Frame cost of a running match around the AI base: no wall, a completed
## perimeter with gates, or the same perimeter under construction.
## godot --headless --fixed-fps 60 --path . --script res://tests/benchmark_walls.gd -- --scenario none|walls|build
## --fixed-fps gives every frame the same simulation step, so the wall-clock
## time of a frame is its CPU cost. No timing assertions.
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Walls := preload("res://scripts/systems/wall_system.gd")
const Perimeter := preload("res://scripts/ai_gateway/defense_perimeter.gd")
const Context := preload("res://scripts/ai_gateway/command_execution_context.gd")
const Observation := preload("res://scripts/ai_gateway/observation_builder.gd")
const Protocol := preload("res://scripts/ai_gateway/ai_protocol.gd")
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const TEAM := 1
const WARMUP_FRAMES := 120
const SAMPLE_FRAMES := 900

var world: Node
var entities: Node2D
var state: MatchState
var civ: CivDef
var scenario := "none"
var results: Dictionary = {}
var gates: Array[Node2D] = []
var villagers: Array[Node2D] = []
var villager_count := 30
var military_count := 0
var sample_frames := SAMPLE_FRAMES
var ai_enabled := false
var both_bases := false
var initial_positions := {}
var observation_interval := 0.0
var observation_pending := false
var observation_times: Array[float] = []
var observation_build_times: Array[float] = []
var observation_prepare_times: Array[float] = []
var observation_main_slices: Array[float] = []
var observation_slice_started := 0
var observation_characters := 0
var observation_background := 0
var encoding_client: Node
var observation_budget_usec := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	UnitDebugFocus.set_spectator_mode(true)
	var args := OS.get_cmdline_user_args()
	var at := args.find("--scenario")
	if at >= 0 and at + 1 < args.size(): scenario = args[at + 1]
	for option in ["--villagers", "--military", "--samples", "--physics-hz"]:
		at = args.find(option)
		if at < 0 or at + 1 >= args.size(): continue
		var value := maxi(1, int(args[at + 1]))
		if option == "--villagers": villager_count = value
		elif option == "--military": military_count = value
		elif option == "--physics-hz": Engine.physics_ticks_per_second = value
		else: sample_frames = value
	ai_enabled = "--ai" in args
	both_bases = "--both-bases" in args
	at = args.find("--observation-interval")
	if at >= 0 and at + 1 < args.size(): observation_interval = maxf(0.0, float(args[at + 1]))
	if "--sync-observation" not in args:
		var observation_api: GDScript = load("res://scripts/ai_gateway/observation_builder.gd")
		for method: Dictionary in observation_api.get_script_method_list():
			if method.name == "build_budgeted": observation_budget_usec = 4000
	Engine.max_fps = 0
	if DisplayServer.get_name() != "headless": DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	seed(12345)
	var session := root.get_node("GameSession")
	session.match_map_data = {}
	session.match_ai_mode = "local" if ai_enabled else "sandbox"
	session.online_active = false
	session.player_civ_id = &"chinese"
	session.ai_civ_id = &"teutons"
	world = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(world)
	current_scene = world
	await process_frame
	await process_frame
	entities = world.get_node("Entities")
	state = world.get_node("Bootstrap").match_state
	civ = load("res://data/civs/teutons.tres")
	for team in 2:
		for type in 4: state.resources[team][type] = 20000
	# Gates need the Feudal Age; walls are normally built from then on.
	state.set_age(TEAM, 1)
	var tc := _town_center()
	var pieces := _perimeter(tc)
	_spawn_villagers(tc)
	if scenario == "walls": _place_walls(pieces, false)
	elif scenario == "build": _place_walls(pieces, true)
	if both_bases and scenario != "none":
		state.set_age(0, 1)
		var other_pieces := _perimeter(_town_center(0), 0)
		_place_walls(other_pieces, false, 0)
		pieces.append_array(other_pieces)
	_spawn_military(tc)
	await process_frame
	_assign_work(tc)
	world.get_node("Camera2D").position = tc.position
	world.get_node("Camera2D").zoom = Vector2(0.6, 0.6)
	world.get_node("Camera2D").set_process(false)
	world.get_node("FogOfWar").set_view(TEAM)
	var ai := world.get_node_or_null("AiController")
	if ai != null and ai.decision_log != null: ai.decision_log.enabled = false
	results["scenario"] = scenario
	results["ai"] = ai_enabled
	results["observation_interval_sim_sec"] = observation_interval
	results["observation_budget_usec"] = observation_budget_usec
	results["renderer"] = DisplayServer.get_name()
	results["gpu"] = RenderingServer.get_video_adapter_name()
	results["cpu"] = OS.get_processor_name()
	results["resolution"] = [root.size.x, root.size.y]
	results["physics_interpolation"] = ProjectSettings.get_setting("physics/common/physics_interpolation", false)
	results["initial_units"] = get_nodes_in_group("units").size()
	for unit in get_nodes_in_group("units"): initial_positions[unit.get_instance_id()] = unit.sim_pos
	results["time_scale"] = Engine.time_scale
	results["physics_hz"] = Engine.physics_ticks_per_second
	results["wall_pieces"] = pieces.size() if scenario != "none" else 0
	results["gates"] = gates.size()
	results["entity_children"] = entities.get_child_count()
	for _frame in WARMUP_FRAMES: await process_frame
	if "--profile" in args:
		await _profile_components()
		quit()
		return
	var intervals: Array[float] = []
	var gate_toggles := 0
	var fog_revisions := 0
	var previous_open := gates.map(func(gate): return gate.gate_open)
	var fog_revision: int = state.fog.revision
	var built_before := _complete_walls()
	var previous := Time.get_ticks_usec()
	var observation_elapsed := 0.0
	if observation_interval > 0.0:
		# Load after autoload initialization, like the match Gateway. Preloading
		# AiConfig from a SceneTree entry script precedes GameSession bindings.
		encoding_client = load("res://scripts/ai_gateway/http_ai_client.gd").new()
		root.add_child(encoding_client)
	for _frame in sample_frames:
		# Exercise the real synchronous gateway snapshot/JSON path alongside
		# the running local AI, without contacting a configured paid service.
		observation_elapsed += Engine.time_scale / 60.0
		if observation_interval > 0.0 and observation_elapsed >= observation_interval and not observation_pending:
			observation_elapsed = 0.0
			var prepare_started := Time.get_ticks_usec()
			_capture_observation(_frame * Engine.time_scale / 60.0)
			observation_prepare_times.append((Time.get_ticks_usec() - prepare_started) / 1000.0)
		await process_frame
		var now := Time.get_ticks_usec()
		intervals.append((now - previous) / 1000.0)
		previous = now
		for index in gates.size():
			if is_instance_valid(gates[index]) and gates[index].gate_open != previous_open[index]:
				gate_toggles += 1
				previous_open[index] = gates[index].gate_open
		if state.fog.revision != fog_revision:
			fog_revisions += 1
			fog_revision = state.fog.revision
	results["frame_ms"] = _stats(intervals)
	results["sample_frames"] = sample_frames
	while observation_pending: await process_frame
	if not observation_times.is_empty():
		results["observation_latency_ms"] = _stats(observation_times)
		results["observation_build_ms"] = _stats(observation_build_times)
		results["observation_prepare_ms"] = _stats(observation_prepare_times)
		results["observation_main_slice_ms"] = _stats(observation_main_slices)
		results["observation_ticks"] = observation_times.size()
		results["observation_characters"] = observation_characters
		results["observation_background_encodes"] = observation_background
	results["average_fps"] = snappedf(1000.0 / float(results.frame_ms.mean), 0.1)
	results["frames_over_16ms"] = intervals.filter(func(v): return v > 16.667).size()
	results["frames_over_33ms"] = intervals.filter(func(v): return v > 33.3).size()
	results["gate_toggles"] = gate_toggles
	results["fog_revisions"] = fog_revisions
	results["walls_completed_during_sample"] = _complete_walls() - built_before
	results["resources_gathered"] = state.get_resource(TEAM, Enums.ResourceType.WOOD) + state.get_resource(TEAM, Enums.ResourceType.FOOD) + state.get_resource(TEAM, Enums.ResourceType.GOLD) + state.get_resource(TEAM, Enums.ResourceType.STONE)
	var moved := 0
	var solved := 0
	var reused := 0
	for unit in get_nodes_in_group("units"):
		if initial_positions.has(unit.get_instance_id()) and unit.sim_pos.distance_to(initial_positions[unit.get_instance_id()]) > 1.0: moved += 1
		var steering: Variant = unit.get("_avoidance_cache")
		if steering is Dictionary:
			solved += int(steering.get("solved", 0))
			reused += int(steering.get("reused", 0))
	results["units_moved"] = moved
	results["steering_solved"] = solved
	results["steering_reused"] = reused
	print("WALL BENCHMARK ", JSON.stringify(results))
	quit()

func _capture_observation(time_sec: float) -> void:
	observation_pending = true
	var started := Time.get_ticks_usec()
	observation_slice_started = started
	var observation: Dictionary
	if observation_budget_usec > 0:
		observation = await Callable(Observation, "build_budgeted").call(state, entities, TEAM, 0, time_sec, 20.0,
			false, _wait_benchmark_observation_frame, observation_budget_usec)
	else:
		observation = Observation.build(state, entities, TEAM, 0, time_sec, 20.0)
	observation_main_slices.append((Time.get_ticks_usec() - observation_slice_started) / 1000.0)
	observation_build_times.append((Time.get_ticks_usec() - started) / 1000.0)
	if encoding_client.has_method("_encode_payload"):
		var encoded: Dictionary = await encoding_client.call("_encode_payload", observation)
		if not encoded.get("ok", false):
			push_error("Observation encoding failed: " + str(encoded))
			quit(1)
			return
		observation_characters = String(encoded.body).length()
		if encoded.get("background", false): observation_background += 1
	else:
		observation_characters = JSON.stringify(Protocol.json_safe(observation)).length()
	observation_times.append((Time.get_ticks_usec() - started) / 1000.0)
	observation_pending = false

func _wait_benchmark_observation_frame() -> bool:
	observation_main_slices.append((Time.get_ticks_usec() - observation_slice_started) / 1000.0)
	var generation: int = encoding_client._cancel_generation
	var resumed: bool = await encoding_client._wait_frame()
	observation_slice_started = Time.get_ticks_usec()
	return resumed and is_instance_valid(encoding_client) and encoding_client._cancel_generation == generation and is_instance_valid(world)

func _profile_components() -> void:
	world.process_mode = Node.PROCESS_MODE_DISABLED
	var outline: Node = root.get_meta("unit_occlusion_renderer") if root.has_meta("unit_occlusion_renderer") else null
	if outline != null: outline.set_process(false)
	var samples := {}
	for name in ["fog", "units", "buildings", "wall_art", "support", "ai", "navigation", "minimap", "hud", "outline", "total_cpu"]: samples[name] = []
	var physics_accumulator := 0.0
	for frame in sample_frames:
		var started := Time.get_ticks_usec()
		var physics_delta := Engine.time_scale / float(Engine.physics_ticks_per_second)
		# time_scale changes each physics delta, not the tick frequency.
		physics_accumulator += Engine.physics_ticks_per_second / 60.0
		var physics_steps := floori(physics_accumulator)
		physics_accumulator -= physics_steps
		for step in physics_steps:
			_time(samples.fog, func(): world.get_node("FogOfWar")._physics_process(physics_delta))
			_time(samples.units, func():
				for unit in get_nodes_in_group("units"): unit._physics_process(physics_delta))
			_time(samples.buildings, func():
				for building in get_nodes_in_group("buildings"): building._physics_process(physics_delta))
		_time(samples.wall_art, func():
			for building in get_nodes_in_group("buildings"):
				var art := building.get_node_or_null("FortificationVisual")
				if art != null: art._process(Engine.time_scale / 60.0))
		_time(samples.support, func(): world.get_node("LandSupport")._process(Engine.time_scale / 60.0))
		_time(samples.ai, func(): world.get_node("AiController")._process(Engine.time_scale / 60.0))
		_time(samples.navigation, func(): world.get_node("NavService")._process(Engine.time_scale / 60.0))
		_time(samples.minimap, func(): world.get_node("UILayer/HUD/Minimap")._process(Engine.time_scale / 60.0))
		_time(samples.hud, func(): world.get_node("UILayer/HUD")._process(Engine.time_scale / 60.0))
		_time(samples.outline, func():
			if outline != null: outline.update_mask())
		samples.total_cpu.append((Time.get_ticks_usec() - started) / 1000.0)
		await process_frame
	var report := {}
	for name in samples: report[name] = _stats(samples[name])
	results["components"] = report
	print("WALL COMPONENTS ", JSON.stringify(results))

func _time(samples: Array, action: Callable) -> void:
	var started := Time.get_ticks_usec()
	action.call()
	samples.append((Time.get_ticks_usec() - started) / 1000.0)

func _town_center(side := TEAM) -> Node2D:
	for node in entities.get_children():
		if node.get("team") == side and node.get("def") is BuildingDef and node.get("def").id == &"town_center": return node
	return null

## The AI's own perimeter plan, computed with full knowledge so the ring
## avoids every obstacle; only legal batches are kept.
func _perimeter(tc: Node2D, side := TEAM) -> Array:
	var ctx := Context.new()
	ctx.match_state = state
	ctx.entities = entities
	ctx.team = side as Enums.Team
	ctx.civ = civ
	state.fog_enabled = false
	var plan := Perimeter.get_plan(state, entities, side, tc.sim_pos, tc.get_instance_id(), state.map_bounds, "palisade_wall")
	var pieces: Array = []
	var rejected := 0
	for batch: Dictionary in Perimeter.batches(plan):
		var reason := Walls.validate_plan(batch.pieces, ctx, false)
		if reason.is_empty(): pieces.append_array(batch.pieces)
		else:
			rejected += 1
			results["rejected_reason"] = reason
	state.fog_enabled = true
	results["rejected_batches"] = rejected
	return pieces

func _place_walls(pieces: Array, foundations: bool, side := TEAM) -> void:
	var placed: Array[Node2D] = []
	for item: Dictionary in pieces:
		var building := BUILDING_VIEW.instantiate() as Node2D
		building.set("def", Catalog.get_building(StringName(item.building_def_id)))
		building.set("team", side)
		building.set("civ", civ)
		building.set("match_state", state)
		building.set("sim_pos", item.pos)
		Walls.configure_building(building, int(item.orientation))
		if foundations: building.call("start_construction")
		entities.add_child(building)
		placed.append(building)
		if item.building_def_id == "gate": gates.append(building)
	if foundations:
		# Ten builders share the ring, each taking a contiguous stretch.
		var builders := villagers.slice(0, 10)
		var stretch := ceili(placed.size() / float(builders.size()))
		for index in builders.size():
			var part := placed.slice(index * stretch, mini((index + 1) * stretch, placed.size()))
			if not part.is_empty(): builders[index].call("command_build_queue", part, false)

func _spawn_villagers(tc: Node2D) -> void:
	for index in villager_count:
		var unit := UNIT_VIEW.instantiate() as Node2D
		unit.set("def", Catalog.get_unit(&"villager"))
		unit.set("team", TEAM)
		unit.set("civ", civ)
		unit.set("match_state", state)
		unit.set("sim_pos", tc.sim_pos + Vector2.from_angle(TAU * index / float(villager_count)) * (7.0 + (index % 8) * 2.0))
		entities.add_child(unit)
		villagers.append(unit)

func _spawn_military(tc: Node2D) -> void:
	for index in military_count:
		var unit := UNIT_VIEW.instantiate() as Node2D
		unit.set("def", Catalog.get_unit([&"militia", &"archer", &"scout_cavalry"][index % 3]))
		unit.set("team", TEAM)
		unit.set("civ", civ)
		unit.set("match_state", state)
		unit.set("sim_pos", tc.sim_pos + Vector2.from_angle(TAU * index / float(military_count)) * (24.0 + (index % 5) * 2.0))
		entities.add_child(unit)
		unit.call("command_move", tc.sim_pos + Vector2(55, index % 15 - 7))

## Same jobs in every scenario: wood, food, gold and stone nearest the base.
## Builders (scenario "build") keep their wall orders.
func _assign_work(tc: Node2D) -> void:
	var by_type := {}
	for node in get_nodes_in_group("resource_nodes"):
		if float(node.get("amount")) <= 0: continue
		var type: int = node.get("resource_type")
		if not by_type.has(type): by_type[type] = []
		by_type[type].append(node)
	for type in by_type:
		by_type[type].sort_custom(func(a, b): return a.sim_pos.distance_squared_to(tc.sim_pos) < b.sim_pos.distance_squared_to(tc.sim_pos))
	var jobs := [Enums.ResourceType.WOOD, Enums.ResourceType.WOOD, Enums.ResourceType.FOOD, Enums.ResourceType.GOLD, Enums.ResourceType.STONE]
	for index in villagers.size():
		if scenario == "build" and index < 10: continue
		var type: int = jobs[index % jobs.size()]
		var options: Array = by_type.get(type, [])
		if options.is_empty(): continue
		villagers[index].call("command_gather", options[(index / jobs.size()) % mini(options.size(), 6)])

func _complete_walls() -> int:
	var count := 0
	for node in entities.get_children():
		if node.get("team") == TEAM and node.get("def") is BuildingDef and Walls.is_fortification(node.get("def").id) and node.get("is_complete"): count += 1
	return count

func _stats(values: Array) -> Dictionary:
	var sorted := values.duplicate()
	sorted.sort()
	var total := 0.0
	for value in sorted: total += value
	return {"mean": snappedf(total / sorted.size(), 0.01), "p50": snappedf(sorted[int(sorted.size() * 0.5)], 0.01),
		"p95": snappedf(sorted[int(sorted.size() * 0.95)], 0.01), "p99": snappedf(sorted[int(sorted.size() * 0.99)], 0.01),
		"max": snappedf(sorted.back(), 0.01)}
