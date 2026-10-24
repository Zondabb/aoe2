extends SceneTree
## Auto gates opening for allies update only their own collision record.
## After every toggle the incremental index must equal a full rebuild, and the
## route grid must be unchanged.
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Walls := preload("res://scripts/systems/wall_system.gd")
const Perimeter := preload("res://scripts/ai_gateway/defense_perimeter.gd")
const Context := preload("res://scripts/ai_gateway/command_execution_context.gd")
const NavGrid := preload("res://scripts/systems/nav_grid_service.gd")
const Collision := preload("res://scripts/systems/collision_resolver.gd")
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const TEAM := 1
var checks := 0
var failures := 0
var entities: Node2D
var state: MatchState
var holder: Node
var civ: CivDef
var gates: Array[Node2D] = []

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)

func _run() -> void:
	var session := root.get_node("GameSession")
	session.match_map_data = {}
	session.match_ai_mode = "sandbox"
	session.online_active = false
	session.player_civ_id = &"chinese"
	session.ai_civ_id = &"teutons"
	var world: Node = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(world)
	current_scene = world
	await process_frame
	await process_frame
	entities = world.get_node("Entities")
	state = world.get_node("Bootstrap").match_state
	holder = get_first_node_in_group("nav_service")
	civ = load("res://data/civs/teutons.tres")
	state.set_age(TEAM, 1)
	for type in 4: state.resources[TEAM][type] = 20000
	var tc: Node2D
	for node in entities.get_children():
		if node.get("team") == TEAM and node.get("def") is BuildingDef and node.get("def").id == &"town_center": tc = node
	_place_perimeter(tc)
	check(gates.size() == 4, "perimeter has a gate on every side (%d)" % gates.size())
	_spawn_workers(tc)
	for _frame in 10: await process_frame
	check(_index() == _expected_index(), "index after placement equals a full rebuild")

	var toggles := 0
	var compared := 0
	var mismatches := 0
	# A full rebuild clears every bucket; an in-place update leaves this one.
	const SENTINEL := Vector2i(999999, 999999)
	holder._static_buckets[SENTINEL] = []
	var previous := gates.map(func(gate): return gate.gate_open)
	# Up to 80 simulated seconds: enough for workers to cross gates both ways.
	var physics_start := Engine.get_physics_frames()
	while Engine.get_physics_frames() - physics_start < 80 * Engine.physics_ticks_per_second and toggles < 24:
		_drive_workers(tc)
		await process_frame
		var toggled := false
		for index in gates.size():
			if gates[index].gate_open != previous[index]:
				toggled = true
				toggles += 1
				previous[index] = gates[index].gate_open
		if not toggled: continue
		compared += 1
		if _index() != _expected_index(): mismatches += 1
	check(toggles >= 6, "workers open and close gates while passing (%d toggles)" % toggles)
	check(mismatches == 0, "incremental index equals a full rebuild after %d toggle frames (%d mismatches)" % [compared, mismatches])
	check(holder._static_buckets.has(SENTINEL), "auto gate toggles ran no full static rebuild")
	holder._static_buckets.erase(SENTINEL)
	check(not holder.nav.rebuild_from_blockers(_blockers()), "route grid is unchanged by auto gate toggles")

	# Explicit states: open/auto keep the route; locking changes it.
	var gate: Node2D = gates[0]
	gate.set_gate_state("open")
	check(gate.gate_open and not holder._static_dirty, "opening a gate updates its record in place")
	check(_index() == _expected_index() and not holder._static_records.has(gate.get_instance_id()), "an open gate leaves the collision index")
	for unit in workers:
		unit.command_stop()
		unit.sim_pos = tc.sim_pos + (unit.sim_pos - tc.sim_pos).limit_length(6.0)
	gate.set_gate_state("auto")
	check(not gate.gate_open and not holder._static_dirty, "closing an auto gate updates its record in place")
	check(_index() == _expected_index() and gate in holder.query_static_blockers(gate.sim_pos, gate.sim_pos, 0.5), "a closed gate blocks movement again")
	gate.set_gate_state("locked")
	check(holder._static_dirty, "locking changes the route footprint and queues a full rebuild")
	await process_frame
	await process_frame
	check(not holder._static_dirty and _index() == _expected_index(), "full rebuild after locking matches")
	print("GATE STATIC INDEX: %d checks, %d failures, %d toggles, %d compared" % [checks, failures, toggles, compared])
	quit(0 if failures == 0 else 1)

func _place_perimeter(tc: Node2D) -> void:
	var ctx := Context.new()
	ctx.match_state = state
	ctx.entities = entities
	ctx.team = TEAM as Enums.Team
	ctx.civ = civ
	state.fog_enabled = false
	var plan := Perimeter.get_plan(state, entities, TEAM, tc.sim_pos, tc.get_instance_id(), state.map_bounds, "palisade_wall")
	for batch: Dictionary in Perimeter.batches(plan):
		if not Walls.validate_plan(batch.pieces, ctx, false).is_empty(): continue
		for item: Dictionary in batch.pieces:
			var building := BUILDING_VIEW.instantiate() as Node2D
			building.set("def", Catalog.get_building(StringName(item.building_def_id)))
			building.set("team", TEAM)
			building.set("civ", civ)
			building.set("match_state", state)
			building.set("sim_pos", item.pos)
			Walls.configure_building(building, int(item.orientation))
			entities.add_child(building)
			if item.building_def_id == "gate": gates.append(building)
	state.fog_enabled = true

## One worker per gate walks out and back in, so each door opens and closes.
var workers: Array[Node2D] = []
var trips := {}

func _spawn_workers(tc: Node2D) -> void:
	for index in 4:
		var unit := UNIT_VIEW.instantiate() as Node2D
		unit.set("def", Catalog.get_unit(&"villager"))
		unit.set("team", TEAM)
		unit.set("civ", civ)
		unit.set("match_state", state)
		unit.set("sim_pos", tc.sim_pos + Vector2.from_angle(TAU * index / 4.0) * 8.0)
		entities.add_child(unit)
		workers.append(unit)
		trips[unit] = 0

func _drive_workers(tc: Node2D) -> void:
	for index in workers.size():
		var unit := workers[index]
		if unit.order != Enums.OrderType.NONE: continue
		var gate: Node2D = gates[index % gates.size()]
		var outward: Vector2 = (gate.sim_pos - tc.sim_pos).normalized()
		var outside: bool = trips[unit] % 2 == 0
		unit.command_move(gate.sim_pos + outward * (16.0 if outside else -16.0))
		trips[unit] += 1

## The blockers rebuild_from_scene would index.
func _blockers() -> Array:
	var result: Array = []
	for node in NavGrid.collect_blockers_from_tree(self):
		if is_instance_valid(node) and node.is_inside_tree() and not node.is_queued_for_deletion() and holder.get_parent().is_ancestor_of(node):
			result.append(node)
	return result

## What _update_static_index would build from scratch (non-empty buckets).
func _expected_index() -> Dictionary:
	var records := {}
	var buckets := {}
	for node in _blockers():
		var half := Collision._blocker_half(node, 0.0)
		if half.x <= 0.0 or half.y <= 0.0: continue
		var center: Vector2 = node.get("sim_pos")
		records[node.get_instance_id()] = [center, half]
		var minimum := Vector2i(((center - half) / holder.STATIC_BUCKET_SIZE).floor())
		var maximum := Vector2i(((center + half) / holder.STATIC_BUCKET_SIZE).floor())
		for y in range(minimum.y, maximum.y + 1):
			for x in range(minimum.x, maximum.x + 1):
				var cell := Vector2i(x, y)
				if not buckets.has(cell): buckets[cell] = []
				buckets[cell].append(node.get_instance_id())
	for cell in buckets: buckets[cell].sort()
	return {"records": records, "buckets": buckets}

func _index() -> Dictionary:
	var records := {}
	for id in holder._static_records:
		var record: Dictionary = holder._static_records[id]
		records[id] = [record.center, record.half]
	var buckets := {}
	for cell in holder._static_buckets:
		var ids: Array = holder._static_buckets[cell].duplicate()
		if ids.is_empty(): continue
		ids.sort()
		buckets[cell] = ids
	return {"records": records, "buckets": buckets}
