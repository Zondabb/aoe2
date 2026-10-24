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

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--scenario")
	if at >= 0 and at + 1 < args.size(): scenario = args[at + 1]
	seed(12345)
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
	await process_frame
	_assign_work(tc)
	results["scenario"] = scenario
	results["time_scale"] = Engine.time_scale
	results["wall_pieces"] = pieces.size() if scenario != "none" else 0
	results["gates"] = gates.size()
	results["entity_children"] = entities.get_child_count()
	for _frame in WARMUP_FRAMES: await process_frame
	var intervals: Array[float] = []
	var gate_toggles := 0
	var fog_revisions := 0
	var previous_open := gates.map(func(gate): return gate.gate_open)
	var fog_revision: int = state.fog.revision
	var built_before := _complete_walls()
	var previous := Time.get_ticks_usec()
	for _frame in SAMPLE_FRAMES:
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
	results["frames_over_33ms"] = intervals.filter(func(v): return v > 33.3).size()
	results["gate_toggles"] = gate_toggles
	results["fog_revisions"] = fog_revisions
	results["walls_completed_during_sample"] = _complete_walls() - built_before
	results["resources_gathered"] = state.get_resource(TEAM, Enums.ResourceType.WOOD) + state.get_resource(TEAM, Enums.ResourceType.FOOD) + state.get_resource(TEAM, Enums.ResourceType.GOLD) + state.get_resource(TEAM, Enums.ResourceType.STONE)
	print("WALL BENCHMARK ", JSON.stringify(results))
	quit()

func _town_center() -> Node2D:
	for node in entities.get_children():
		if node.get("team") == TEAM and node.get("def") is BuildingDef and node.get("def").id == &"town_center": return node
	return null

## The AI's own perimeter plan, computed with full knowledge so the ring
## avoids every obstacle; only legal batches are kept.
func _perimeter(tc: Node2D) -> Array:
	var ctx := Context.new()
	ctx.match_state = state
	ctx.entities = entities
	ctx.team = TEAM as Enums.Team
	ctx.civ = civ
	state.fog_enabled = false
	var plan := Perimeter.get_plan(state, entities, TEAM, tc.sim_pos, tc.get_instance_id(), state.map_bounds, "palisade_wall")
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

func _place_walls(pieces: Array, foundations: bool) -> void:
	var placed: Array[Node2D] = []
	for item: Dictionary in pieces:
		var building := BUILDING_VIEW.instantiate() as Node2D
		building.set("def", Catalog.get_building(StringName(item.building_def_id)))
		building.set("team", TEAM)
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
	for index in 30:
		var unit := UNIT_VIEW.instantiate() as Node2D
		unit.set("def", Catalog.get_unit(&"villager"))
		unit.set("team", TEAM)
		unit.set("civ", civ)
		unit.set("match_state", state)
		unit.set("sim_pos", tc.sim_pos + Vector2.from_angle(TAU * index / 30.0) * (7.0 + (index % 3) * 2.0))
		entities.add_child(unit)
		villagers.append(unit)

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

func _stats(values: Array[float]) -> Dictionary:
	var sorted := values.duplicate()
	sorted.sort()
	var total := 0.0
	for value in sorted: total += value
	return {"mean": snappedf(total / sorted.size(), 0.01), "p50": snappedf(sorted[int(sorted.size() * 0.5)], 0.01),
		"p95": snappedf(sorted[int(sorted.size() * 0.95)], 0.01), "p99": snappedf(sorted[int(sorted.size() * 0.99)], 0.01),
		"max": snappedf(sorted.back(), 0.01)}
