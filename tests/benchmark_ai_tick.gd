extends SceneTree
## Main-thread cost of one AI Gateway tick, split by stage.
## godot --headless --path . --script res://tests/benchmark_ai_tick.gd
## No timing assertions: compare runs on the same machine.
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Observation := preload("res://scripts/ai_gateway/observation_builder.gd")
const DC := preload("res://scripts/ai_gateway/decision_context_builder.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Protocol := preload("res://scripts/ai_gateway/ai_protocol.gd")
const Events := preload("res://scripts/ai_gateway/event_buffer.gd")
const FogAccess := preload("res://scripts/systems/fog_access.gd")
const Profile := preload("res://scripts/data/civ_ai_profile.gd")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const ITERATIONS := 8
const TEAM := 1
const ENEMY := 0

var world: Node
var entities: Node2D
var state: MatchState
var results: Dictionary = {}
var subscriber := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	UnitDebugFocus.set_spectator_mode(true)
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
	for node in entities.get_children(): node.set_physics_process(false)
	subscriber = Events.subscribe()
	state.fog.rebuild(entities.get_children())
	results["entity_children"] = entities.get_child_count()
	results["map_bounds"] = [state.map_bounds.size.x, state.map_bounds.size.y]
	_measure("opening")
	_grow_mid_game()
	for node in entities.get_children(): node.set_physics_process(false)
	state.fog.rebuild(entities.get_children())
	_explore_half_map()
	results["mid_entity_children"] = entities.get_child_count()
	_measure("mid_game")
	print("AI TICK BENCHMARK ", JSON.stringify(results, "\t"))
	quit()

func _measure(label: String) -> void:
	var stages := {}
	var civ: CivDef = load("res://data/civs/teutons.tres")
	var profile := Profile.for_civ(civ)
	var defend: float = profile.defend_radius if profile != null else 20.0
	var payload_kb := 0.0
	var entity_count := 0
	var visible_resources := 0
	for iteration in ITERATIONS + 1:
		var time := 60.0 + iteration * 0.5
		var t := Time.get_ticks_usec()
		Registry.sample_owned_state(entities, TEAM, time)
		var sample_ms := _ms(t)
		var events: Array = Events.peek(subscriber).get("events", [])
		t = Time.get_ticks_usec()
		var observation := Observation.build(state, entities, TEAM, ENEMY, time, defend)
		var build_ms := _ms(t)
		# Same work as the gateway's request body, then the client's encode.
		var payload := {"team": TEAM, "tick": iteration, "time_sec": time, "observation": observation,
			"events": Events.for_team(events, TEAM, true)}
		t = Time.get_ticks_usec()
		var body := JSON.stringify(Protocol.json_safe(payload))
		var json_ms := _ms(t)
		Events.acknowledge(subscriber, int(Events.peek(subscriber).get("to_seq", 0)))
		if iteration == 1:
			# Planning hints for before/after equivalence checks.
			var dump := FileAccess.open("res://.godot/ai-tick-hints-%s.json" % label, FileAccess.WRITE)
			dump.store_string(JSON.stringify(Protocol.json_safe(observation.decision_context), "\t", true))
		var parts := _decision_context_parts(observation, defend)
		if iteration == 0:
			continue # warm-up: first registration emits spawn events for every entity
		_add(stages, "1_sample_owned_state", sample_ms)
		_add(stages, "2_observation_build_total", build_ms)
		for key in parts: _add(stages, "3_dc_" + key, parts[key])
		_add(stages, "4_json_encode", json_ms)
		_add(stages, "5_tick_total", sample_ms + build_ms + json_ms)
		payload_kb = body.length() / 1024.0
		entity_count = observation.entities.size()
		visible_resources = observation.entities.filter(func(e): return e.kind == "resource").size()
	var summary := {}
	for key in stages:
		var values: Array = stages[key]
		values.sort()
		var total := 0.0
		for v in values: total += v
		summary[key] = {"mean": snappedf(total / values.size(), 0.01), "max": snappedf(values.back(), 0.01)}
	summary["payload_kb"] = snappedf(payload_kb, 0.1)
	summary["observed_entities"] = entity_count
	summary["observed_resources"] = visible_resources
	results[label] = summary
	print("STAGE ", label, " ", JSON.stringify(summary))

## Replays DecisionContextBuilder.build() step by step with timers.
func _decision_context_parts(observation: Dictionary, defend_radius: float) -> Dictionary:
	var parts := {}
	var snapshots: Array = observation.entities
	var derived: Dictionary = observation.derived
	var t := Time.get_ticks_usec()
	var own: Array[Node2D] = []
	var builders: Array[Node2D] = []
	var known_static: Array = []
	var placement_blockers: Array = []
	var civ: CivDef
	var observed_ids := {}
	for snapshot: Dictionary in snapshots: observed_ids[snapshot.id] = true
	for node in entities.get_children():
		if not node is Node2D or node.is_queued_for_deletion() or node.get("is_placement_ghost") == true: continue
		var definition: Variant = node.get("def")
		if definition is UnitDef or definition is BuildingDef:
			if float(node.get("hp")) <= 0: continue
			if int(node.get("team")) == TEAM:
				own.append(node)
				if civ == null: civ = node.get("civ") as CivDef
				if definition is UnitDef and definition.id == &"villager": builders.append(node)
		if not FogAccess.state_can_see(state, TEAM, node): continue
		if (definition is BuildingDef or definition is UnitDef or node.has_method("extract")) and not observed_ids.has(Registry.id_of(node)): continue
		if definition is BuildingDef or node.is_in_group("terrain_regions"):
			placement_blockers.append(node)
			known_static.append(node)
		elif node.has_method("extract"):
			known_static.append(node)
	parts["a_collect"] = _ms(t)
	t = Time.get_ticks_usec()
	var catalog := DC._catalog(state, entities, TEAM, civ)
	parts["b_catalog"] = _ms(t)
	var bounds := state.map_bounds
	t = Time.get_ticks_usec()
	var nav := DC.ObservationNav.new()
	nav.team = TEAM
	nav.fog = state.fog if state.fog_enabled else null
	const CELL := 2.0
	nav.setup_rect(Vector2i((bounds.position / CELL).floor()), Vector2i((bounds.end / CELL).ceil()), CELL)
	parts["c_nav_setup_astar"] = _ms(t)
	t = Time.get_ticks_usec()
	nav.rebuild_from_blockers(known_static)
	parts["d_nav_rebuild_blockers"] = _ms(t)
	t = Time.get_ticks_usec()
	var army := DC._army(own, snapshots, derived, TEAM, defend_radius, bounds, nav)
	parts["e_army"] = _ms(t)
	t = Time.get_ticks_usec()
	DC._defense_planning(state, entities, TEAM, civ, builders, derived, bounds, nav)
	parts["f_defense_walls"] = _ms(t)
	t = Time.get_ticks_usec()
	DC._construction_options(state, TEAM, builders, catalog.buildings, placement_blockers, bounds, nav, derived, snapshots)
	parts["g_construction_sites"] = _ms(t)
	t = Time.get_ticks_usec()
	DC._scouting(state, TEAM, own, bounds, nav, army.scout_ids, derived)
	parts["h_scouting_frontiers"] = _ms(t)
	parts["z_known_static"] = known_static.size()
	parts["z_blockers"] = placement_blockers.size()
	var perimeter := _perimeter_size(civ, derived, bounds)
	for key in perimeter: parts["w_" + key] = perimeter[key]
	return parts

const Perimeter := preload("res://scripts/ai_gateway/defense_perimeter.gd")

## Wall pieces checked by _defense_planning on every tick.
func _perimeter_size(civ: CivDef, derived: Dictionary, bounds: Rect2) -> Dictionary:
	if int(derived.get("own_tc_id", -1)) < 0: return {"pieces": 0, "batches": 0}
	var plan := Perimeter.get_plan(state, entities, TEAM, Protocol.array_to_vec2(derived.own_tc_pos), int(derived.own_tc_id), bounds, "palisade_wall")
	var batches := Perimeter.batches(plan)
	var pieces := 0
	for batch: Dictionary in batches: pieces += batch.pieces.size()
	return {"pieces": pieces, "batches": batches.size()}

## Roughly a 15-20 minute Feudal/Castle base for the AI side.
func _grow_mid_game() -> void:
	var tc: Node2D
	for node in entities.get_children():
		if node.get("team") == TEAM and node.get("def") is BuildingDef and node.get("def").id == &"town_center": tc = node
	var base: Vector2 = tc.sim_pos
	var civ: CivDef = load("res://data/civs/teutons.tres")
	var toward_center := (state.map_bounds.get_center() - base).normalized()
	var plan := ["house", "house", "house", "house", "house", "house", "house", "house", "house", "house",
		"house", "house", "house", "house", "barracks", "archery_range", "stable", "blacksmith", "market",
		"mill", "lumber_camp", "lumber_camp", "mining_camp", "monastery"]
	var placed := 0
	var ring := 0
	while placed < plan.size() and ring < 12:
		var radius := 24.0 + ring * 8.0
		for step in 16:
			if placed >= plan.size(): break
			var pos := (base + Vector2.from_angle(TAU * step / 16.0) * radius).round()
			var definition: BuildingDef = Catalog.get_building(plan[placed])
			if not state.map_bounds.grow(-8).has_point(pos) or not _free(pos, definition.footprint + Vector2.ONE * 2): continue
			_spawn_building(plan[placed], pos, civ)
			placed += 1
		ring += 1
	for i in 10:
		var pos := (base + Vector2.from_angle(TAU * i / 10.0) * 14.0).round()
		if _free(pos, Vector2(7, 7)): _spawn_building("farm", pos, civ)
	for i in 55:
		var pos := base + Vector2.from_angle(TAU * i / 55.0) * (10.0 + (i % 5) * 6.0)
		_spawn_unit("villager", pos, civ)
	var rally := base + toward_center * 45.0
	for i in 30:
		var kind: String = ["man_at_arms", "archer", "knight"][i % 3]
		if Catalog.get_unit(StringName(kind)) == null: kind = "militia"
		_spawn_unit(kind, rally + Vector2(i % 6, i / 6) * 2.0, civ)
	for i in 3:
		_spawn_unit("scout_cavalry", base + toward_center.rotated(-0.8 + i * 0.8) * 120.0, civ)

func _explore_half_map() -> void:
	var fog: RefCounted = state.fog
	var mask: PackedByteArray = fog.explored[TEAM]
	var grid: Vector2i = fog.grid_size
	var tc_cell: Vector2i
	for node in entities.get_children():
		if node.get("team") == TEAM and node.get("def") is BuildingDef and node.get("def").id == &"town_center": tc_cell = fog.cell_at(node.sim_pos)
	for y in grid.y:
		for x in grid.x:
			if Vector2(x, y).distance_to(Vector2(tc_cell)) < grid.x * 0.45: mask[y * grid.x + x] = 255
	fog.explored[TEAM] = mask

func _free(pos: Vector2, size: Vector2) -> bool:
	var area := Rect2(pos - size * 0.5, size)
	for node in entities.get_children():
		var definition: Variant = node.get("def")
		var other_size := Vector2.ZERO
		if definition is BuildingDef: other_size = definition.footprint
		elif node.has_method("extract"): other_size = Vector2(2, 2)
		elif node.is_in_group("terrain_regions"): other_size = node.get("block_size")
		else: continue
		if area.intersects(Rect2(node.sim_pos - other_size * 0.5, other_size)): return false
	return true

func _spawn_building(id: String, pos: Vector2, civ: CivDef) -> void:
	var entity := BUILDING_VIEW.instantiate()
	if id == "farm": entity.set_script(load("res://scripts/entities/farm_agent.gd"))
	entity.set("def", Catalog.get_building(StringName(id)))
	entity.set("team", TEAM)
	entity.set("civ", civ)
	entity.set("match_state", state)
	entity.set("sim_pos", pos)
	entities.add_child(entity)

func _spawn_unit(id: String, pos: Vector2, civ: CivDef) -> void:
	var entity := UNIT_VIEW.instantiate()
	entity.set("def", Catalog.get_unit(StringName(id)))
	entity.set("team", TEAM)
	entity.set("civ", civ)
	entity.set("match_state", state)
	entity.set("sim_pos", pos)
	entities.add_child(entity)

func _add(stages: Dictionary, key: String, value: float) -> void:
	if not stages.has(key): stages[key] = []
	stages[key].append(value)

func _ms(started: int) -> float:
	return (Time.get_ticks_usec() - started) / 1000.0
