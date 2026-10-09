extends SceneTree
## Run with a real renderer and -- --label before/after. No timing assertions:
## hardware and window scheduling vary; the same fixture provides comparison.
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Iso := preload("res://scripts/presentation/iso_math.gd")
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const SAMPLE_FRAMES := 240
var results: Dictionary = {}
var world: Node
var entities: Node2D
var state: MatchState
var fog_holder: Node
var camera: Camera2D
var manual_army: Array[UnitAgent] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	Engine.max_fps = 0
	UnitDebugFocus.set_spectator_mode(true)
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var session := root.get_node("GameSession")
	session.match_map_data = {}
	session.match_ai_mode = "sandbox"
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
	fog_holder = world.get_node("FogOfWar")
	camera = world.get_node("Camera2D")
	camera.set_process(false)
	results["renderer"] = DisplayServer.get_name()
	results["resource_count"] = get_nodes_in_group("resource_nodes").size()
	results["window"] = root.size
	await _measure("opening")
	# Discover the same 14 forests before returning to the original viewpoint.
	var scout: UnitAgent = entities.get_node("PlayerScout")
	var start := scout.sim_pos
	for center in [Vector2(-120,-188), Vector2(-188,-120), Vector2(-195,-195), Vector2(-160,-24), Vector2(-40,-185), Vector2(-52,-40), Vector2(-195,60)]:
		for side in [-1, 1]:
			scout.sim_pos = center * side
			Iso.sync_node(scout, scout.sim_pos)
			fog_holder.rebuild_now()
	scout.sim_pos = start
	Iso.sync_node(scout, start)
	fog_holder.rebuild_now()
	results["known_resources"] = state.fog.memories[0].size()
	await _measure("explored_forests")
	# A bounded army marching through a clear corridor on the unchanged large map.
	for index in 48:
		var unit := UNIT_VIEW.instantiate() as UnitAgent
		unit.def = Catalog.get_unit("militia")
		unit.civ = load("res://data/civs/chinese.tres")
		unit.team = Enums.Team.PLAYER
		unit.match_state = state
		unit.sim_pos = Vector2(-20, -90) + Vector2(index % 8, index / 8) * 2.0
		entities.add_child(unit)
		unit.set_physics_process(false)
		manual_army.append(unit)
		unit.command_move(unit.sim_pos + Vector2(70, 0))
	camera.call("focus_on", Vector2(5, -85))
	await _measure("48_marching_units")
	var label := "current"
	var args := OS.get_cmdline_user_args()
	var at := args.find("--label")
	if at >= 0 and at + 1 < args.size(): label = args[at + 1].validate_filename()
	var path := "res://.godot/default-map-performance-%s.json" % label
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(results, "\t"))
	print("DEFAULT MAP PERFORMANCE ", JSON.stringify(results))
	quit()

func _measure(label: String) -> void:
	for _frame in 30:
		_step_army()
		await process_frame
	var intervals: Array[float] = []
	var process_cost: Array[float] = []
	var physics_cost: Array[float] = []
	var draw_calls: Array[float] = []
	var previous := Time.get_ticks_usec()
	for _frame in SAMPLE_FRAMES:
		_step_army()
		await process_frame
		var now := Time.get_ticks_usec()
		intervals.append((now - previous) / 1000.0)
		previous = now
		process_cost.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		physics_cost.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		draw_calls.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	results[label] = {"frame_ms": _stats(intervals), "process_ms": _stats(process_cost),
		"physics_ms": _stats(physics_cost), "draw_calls": _stats(draw_calls),
		"entity_children": entities.get_child_count(), "units": get_nodes_in_group("units").size()}
	print("PERFORMANCE ", label, " ", JSON.stringify(results[label]))

func _step_army() -> void:
	# Fixed simulation work per rendered sample keeps slow/fast runs comparable;
	# none of the 48 walkers finishes early because of physics catch-up steps.
	for unit in manual_army: unit._physics_process(1.0 / 60.0)

func _stats(values: Array[float]) -> Dictionary:
	values.sort()
	var total := 0.0
	for value in values: total += value
	return {"mean": snappedf(total / values.size(), 0.001),
		"p50": values[int(values.size() * 0.5)], "p95": values[int(values.size() * 0.95)],
		"max": values.back()}
