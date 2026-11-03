extends SceneTree

const Runtime := preload("res://scripts/network/network_match.gd")
const Simulation := preload("res://scripts/network/lockstep_simulation.gd")
const State := preload("res://scripts/network/lockstep_state.gd")
var checks := 0
var failures := 0
var runtime: Node

class FrameProbe extends Node:
	var frames: Array = []
	func send_frame(tick: int, commands: Array, checksum: String) -> bool:
		frames.append({"tick": tick, "commands": commands, "checksum": checksum})
		return true
	func leave() -> void:
		pass
	func finish_match(_winner: int) -> void:
		pass

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("LOCKSTEP STATE: " + label)

func _run() -> void:
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
	runtime = Runtime.new()
	runtime.name = "NetworkMatch"
	scene.add_child(runtime)
	runtime.match_state = bootstrap.match_state
	runtime.entities = scene.get_node("Entities")
	runtime.map_bounds = bootstrap.map_bounds
	runtime._civs = {0: bootstrap.player_civ, 1: bootstrap.ai_civ}
	runtime.is_host = true
	runtime._playing = true
	runtime.set_process(false)
	var sim := Simulation.new()
	sim.setup(runtime)
	runtime.simulation = sim
	var units: Array = []
	var centers: Array = []
	for entity in runtime.entities.get_children():
		if entity is UnitAgent: units.append(entity)
		if entity is BuildingAgent and entity.def.id == &"town_center": centers.append(entity)
	check(units.size() >= 2 and centers.size() == 2, "default world has both armies")
	var probe := FrameProbe.new()
	scene.add_child(probe)
	runtime.session = probe
	runtime.synchronized = true
	var own_unit: Node
	for unit in units:
		if unit.team == 0: own_unit = unit; break
	var initial_order: int = own_unit.order
	check(runtime.submit_command({"op":"move", "unit_id":runtime.entity_id(own_unit), "pos":[-110,-110]}), "manual command enters host queue")
	check(own_unit.order == initial_order, "queued operation does not execute before frame")
	check(not runtime.submit_command({"op":"move", "unit_id":runtime.entity_id(own_unit), "pos":[-110,-110], "extra":"payload"}), "unrecognized fields cannot inflate authoritative frames")
	check(not runtime.submit_command({"op":"ai_control_state", "states":{}}), "players cannot forge host control status")
	var context := preload("res://scripts/ai_gateway/command_execution_context.gd").new()
	context.match_state = runtime.match_state
	context.entities = runtime.entities
	context.team = 0
	context.civ = runtime._civs[0]
	var result: Dictionary = preload("res://scripts/ai_gateway/command_executor.gd").execute({"op":"move", "unit_id":preload("res://scripts/ai_gateway/entity_registry.gd").id_of(own_unit), "pos":[-112,-112]}, context)
	check(result.get("reason") == "queued_for_frame" and own_unit.order == initial_order, "LLM callback queues without changing simulation")
	var another: Node
	for unit in units:
		if unit.team == 0 and unit != own_unit: another = unit; break
	var repeated := {"op":"move", "unit_id":preload("res://scripts/ai_gateway/entity_registry.gd").id_of(another), "pos":[-105,-105], "command_id":"duplicate-callback"}
	var executor := preload("res://scripts/ai_gateway/command_executor.gd")
	check(executor.execute(repeated, context).get("ok") and executor.execute(repeated, context).get("ok"), "duplicate AI callbacks can arrive before frame execution")
	var invalid_ai := {"op":"move", "unit_id":preload("res://scripts/ai_gateway/entity_registry.gd").id_of(another), "pos":[99999,99999]}
	check(executor.execute(invalid_ai, context).get("ok"), "AI response waits for frame authority validation")
	runtime._advance_host_frame()
	var repeated_count := 0
	for item in probe.frames[0].commands:
		if item.command.get("unit_id") == runtime.entity_id(another): repeated_count += 1
	check(repeated_count == 1, "duplicate and out-of-bounds AI operations are not broadcast")
	check(probe.frames.size() == 1 and probe.frames[0].commands.size() >= 2, "one ordered frame includes manual and AI operations")
	check(own_unit._move_target == Vector2(-112,-112), "host applies queued operations in order")

	for unit in units:
		unit.command_move(unit.sim_pos + Vector2(4, 3))
	check(centers[0].enqueue_train(load("res://data/units/villager.tres")), "production queued")
	centers[0].train_progress = 24.0
	# An idle unit contains an infinity sentinel; finite scalars must also
	# survive the Python relay's JSON conversion without losing one ULP.
	var wire_scalar: Variant = JSON.parse_string(JSON.stringify(State.encode(994.1333333333337), "", true, true))
	check(State.decode(wire_scalar, {}) == 994.1333333333337, "exact binary64 survives JSON")
	check(State.valid_encoded(JSON.parse_string(JSON.stringify(State.encode(INF))), {}), "idle infinity sentinel validates after JSON")
	var catalog := preload("res://scripts/data/game_catalog.gd")
	var technologies: Node = runtime.match_state.technology_progression
	var research_buildings: Array = []
	for i in 3:
		var building: Node = load("res://scenes/entities/building_view.tscn").instantiate()
		building.def = catalog.get_building(["archery_range", "university", "monastery"][i])
		building.team = 1
		building.civ = runtime._civs[1]
		building.match_state = runtime.match_state
		building.sim_pos = Vector2(160, 120 + i * 20)
		runtime.entities.add_child(building)
		research_buildings.append(building)
	runtime.match_state.set_age(1, 2)
	for resource in 4: runtime.match_state.resources[1][resource] = 10000
	check(technologies.start_research(research_buildings[0], "crossbowman"), "technology job started")
	var technology_job: Dictionary = technologies.jobs[research_buildings[0].get_instance_id()]
	technology_job.elapsed = float(technology_job.duration) - 0.8
	var age: Node = runtime.match_state.age_progression
	check(age.start_advance(centers[1]), "age job started")
	age._jobs[1].elapsed = float(age._jobs[1].duration) - 0.8
	var projectile: Node = load("res://scenes/entities/projectile_view.tscn").instantiate()
	runtime.entities.add_child(projectile)
	projectile.setup(units[0].sim_pos, units[0].sim_pos + Vector2(20, 0), load("res://data/units/archer.tres"), units[0].team, units[0])
	for _step in 8: sim.step()
	# A blocked native steering solve uses this sentinel (larger than the
	# integer precision of JSON numbers). Also check the adjacent value so
	# a double conversion cannot pass just because the sentinel is a power of 2.
	own_unit._avoidance_cache["risk"] = LocalAvoidance.RISK_INF
	for large in [LocalAvoidance.RISK_INF, LocalAvoidance.RISK_INF + 1, -LocalAvoidance.RISK_INF - 1]:
		var wire: Variant = JSON.parse_string(JSON.stringify(State.encode(large)))
		check(State.valid_encoded(wire, {}) and State.decode(wire, {}) == large, "int64 steering state survives JSON exactly")
	check(not State.valid_encoded(["i", "5"], {}), "small integers use one canonical wire representation")
	var compact := State.digest(runtime)
	var exhaustive := State.full_digest(runtime)
	var facing: int = own_unit._facing_dir
	own_unit._facing_dir = (facing + 1) % 5
	check(State.digest(runtime) == compact and State.full_digest(runtime) == exhaustive, "local sprite direction does not cause a repair")
	own_unit._facing_dir = facing
	var original: Dictionary = sim.capture()
	var payload: Dictionary = JSON.parse_string(JSON.stringify(original, "", true, true))
	check(State.validate(payload.simulation, payload.world), "wire keyframe validates")
	var coast_index: int = payload.simulation.entities.find_custom(func(record: Dictionary): return record.kind == "terrain" and not record.fields.water_contours[1].is_empty())
	check(coast_index >= 0, "default map keyframe carries the host's coast geometry")
	if coast_index >= 0:
		var bad_coast: Dictionary = payload.simulation.duplicate(true)
		bad_coast.entities[coast_index].fields.water_contours = ["a", [["i", 1]]]
		check(not State.validate(bad_coast, payload.world), "wrong shoreline element type rejected before world mutation")
	var malformed: Dictionary = payload.simulation.duplicate(true)
	malformed.entities[0].fields.hp_q = "bad"
	check(not State.validate(malformed, payload.world), "wrong property type rejected before mutation")
	malformed = payload.simulation.duplicate(true)
	malformed.entities[0].fields.hp_q = ["f", "AAAAAAAA"]
	check(not State.validate(malformed, payload.world), "truncated floating bits rejected")
	var start_hash := sim.checksum()
	var expected: Array = []
	for _step in 50:
		sim.step()
		expected.append(sim.checksum())
	runtime.is_host = false
	runtime._last_snapshot_sequence = -1
	check(sim.restore(payload), "in-motion keyframe restores")
	check(start_hash == sim.checksum(), "keyframe restores exact hidden state")
	if start_hash != sim.checksum():
		_write_diff(original.simulation, State.capture(runtime))
	for step in 50:
		sim.step()
		check(sim.checksum() == expected[step], "resumed tick %d has identical checksum" % step)
		if failures > 0: break
	# A late viewer reconstructs every object, with different process-local IDs.
	for entity in runtime.entities.get_children(): entity.free()
	runtime._net_entities.clear()
	runtime._static_replica_records.clear()
	runtime._last_snapshot_sequence = -1
	check(sim.restore(payload), "fresh viewer reconstructs full keyframe")
	check(start_hash == sim.checksum(), "new process IDs do not affect checksum")
	if start_hash != sim.checksum(): _write_diff(original.simulation, State.capture(runtime))
	for step in 50:
		sim.step()
		check(sim.checksum() == expected[step], "fresh viewer tick %d has identical checksum" % step)
		if failures > 0: break
	print("LOCKSTEP STATE TESTS %s: %d checks" % ["PASSED" if failures == 0 else "FAILED", checks])
	scene.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)

func _write_diff(before: Dictionary, after: Dictionary) -> void:
	for pair in [["before", before], ["after", after]]:
		var file := FileAccess.open("res://.godot/lockstep-state-%s.json" % pair[0], FileAccess.WRITE)
		file.store_string(JSON.stringify(pair[1], "\t", true, true))
