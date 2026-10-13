extends SceneTree

const OBSERVATION := preload("res://scripts/ai_gateway/observation_builder.gd")
const BLOCKER := preload("res://scripts/entities/path_blocker.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)

func water(entities: Node2D, position: Vector2, size: Vector2) -> PathBlocker:
	var region := BLOCKER.new() as PathBlocker
	region.kind = &"water"
	region.auto_block_size = false
	region.sim_pos = position
	region.block_size = size
	entities.add_child(region)
	return region

func same_hints(first: Dictionary, second: Dictionary, label: String) -> void:
	check(first.entities == second.entities, label + ": model sees the same entity snapshots")
	check(first.decision_context.scouting == second.decision_context.scouting, label + ": hidden extent cannot change scouting hints")
	check(first.decision_context.army == second.decision_context.army, label + ": hidden extent cannot change rally or threat metrics")
	check(first.decision_context.construction_options == second.decision_context.construction_options, label + ": hidden extent cannot change visible construction choices")

func _run() -> void:
	UnitDebugFocus.set_spectator_mode(true)
	var session := root.get_node("GameSession")
	session.match_map_data = {}
	session.match_ai_mode = "sandbox"
	var world := load("res://scenes/match_2d.tscn").instantiate() as Node2D
	root.add_child(world)
	await process_frame
	await process_frame
	world.process_mode = Node.PROCESS_MODE_DISABLED
	var state: MatchState = world.get_node("Bootstrap").match_state
	var entities: Node2D = world.get_node("Entities")
	var retained: Array[Node2D] = []
	for node in entities.get_children():
		if node.get("team") != 1: continue
		if node.get("def") is BuildingDef and node.def.id == &"town_center":
			node.sim_pos = Vector2(-60, 0)
			retained.append(node)
		elif node.get("def") is UnitDef and node.def.id == &"scout_cavalry":
			node.sim_pos = Vector2(-60, 0)
			retained.append(node)
		elif node.get("def") is UnitDef and node.def.id == &"villager" and not retained.any(func(actor): return actor.get("def") is UnitDef and actor.def.id == &"villager"):
			node.sim_pos = Vector2(-64, 3)
			retained.append(node)
	for node in entities.get_children():
		if node not in retained: node.free()
	state.fog.rebuild(entities.get_children())
	var cliff := BLOCKER.new() as PathBlocker
	cliff.kind = &"cliff"
	cliff.auto_block_size = false
	cliff.sim_pos = Vector2(-12.5, 0)
	cliff.block_size = Vector2(65, 10)
	entities.add_child(cliff)
	check(state.fog.can_see(1, cliff), "left edge of the long cliff is actually visible")
	check(state.fog.state_at(1, Vector2(60, 0)) == 0, "opposite geometric probe is unexplored")
	var short := OBSERVATION.build_json_safe(state, entities, 1, 0, 0)
	cliff.sim_pos = Vector2(17.5, 0)
	cliff.block_size = Vector2(125, 10)
	cliff.block_half = cliff.block_size * 0.5
	cliff._setup_visual()
	var long := OBSERVATION.build_json_safe(state, entities, 1, 0, 0)
	same_hints(short, long, "partly visible cliff")
	cliff.free()
	var shore := water(entities, Vector2(-12.5, 0), Vector2(65, 10))
	check(state.fog.can_see(1, shore), "near edge of the water region is visible")
	short = OBSERVATION.build_json_safe(state, entities, 1, 0, 0)
	var extension := water(entities, Vector2(52.5, 0), Vector2(65, 10))
	check(not state.fog.can_see(1, extension), "adjoining water extension remains hidden")
	long = OBSERVATION.build_json_safe(state, entities, 1, 0, 0)
	same_hints(short, long, "shared water coast")
	state.frozen = true
	world.free()
	print("EXTERNAL AI VISIBILITY: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
