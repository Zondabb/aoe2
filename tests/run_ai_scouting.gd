extends SceneTree

const Scout := preload("res://scripts/systems/ai/ai_scout_manager.gd")
const Director := preload("res://scripts/systems/ai/ai_director.gd")
const Observation := preload("res://scripts/ai_gateway/observation_builder.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func _run() -> void:
	UnitDebugFocus.set_spectator_mode(true)
	var session := root.get_node("GameSession")
	session.match_map_data = {}
	session.match_ai_mode = "sandbox"
	session.player_civ_id = &"chinese"
	session.ai_civ_id = &"teutons"
	var world := load("res://scenes/match_2d.tscn").instantiate() as Node2D
	root.add_child(world)
	await process_frame
	await process_frame
	var state: MatchState = world.get_node("Bootstrap").match_state
	var entities: Node2D = world.get_node("Entities")
	check(state.map_bounds.size == Vector2(480, 480) and state.fog_enabled, "actual default map uses full public bounds and fog")
	var initial := Observation.build(state, entities, 1, 0, 0)
	check(initial.entities.filter(func(e): return e.kind == "resource").is_empty(), "starting AI cannot observe distant resource groups")
	check(initial.derived.enemy_tc_id == -1, "enemy town center remains hidden")
	# Manual simulation advances real pathfinding, production, construction and
	# resource cycles. Starting currency and all original durations are unchanged.
	var ai := Director.new()
	world.add_child(ai)
	ai.setup(state, entities, load("res://data/civs/teutons.tres"), 1, 0, "AI", null, false)
	ai.decision_log.enabled = false
	world.get_node("Camera2D").set_process(false)
	world.get_node("FogOfWar").set_physics_process(false)
	world.get_node("AgeProgression").set_process(false)
	world.get_node("TechnologyProgression").set_process(false)
	world.get_node("LandSupport").set_process(false)
	var nav: Node = world.get_node("NavService")
	for entity in entities.get_children(): entity.set_physics_process(false)
	var seen := {}
	var deposits := {0:0, 1:0, 2:0, 3:0}
	var elapsed := 0.0
	for step in 1600:
		elapsed = step * 0.25
		state.fog.rebuild(entities.get_children())
		if step % 2 == 0:
			ai.match_time = elapsed
			ai.evaluate()
			var observation := Observation.build(state, entities, 1, 0, elapsed)
			for entity in observation.entities:
				if entity.kind == "resource": seen[entity.resource_type] = true
		nav._process(0.25)
		var before: Dictionary = state.resources[1].duplicate()
		for entity in entities.get_children():
			entity.set_physics_process(false)
			if entity is UnitAgent or entity is BuildingAgent: entity._physics_process(0.25)
		for type in deposits:
			deposits[type] += maxi(0, state.get_resource(1, type) - int(before[type]))
		world.get_node("AgeProgression")._process(0.25)
		world.get_node("TechnologyProgression")._process(0.25)
		if deposits.values().all(func(value): return value > 0): break
		if step % 80 == 0:
			var scout: Node = world.get_node_or_null("Entities/AiScout")
			print("SCOUT SIM %.0fs: seen %s deposits %s scout %s" % [elapsed, seen.keys(), deposits, scout.sim_pos if scout != null else "lost"])
			await process_frame
	for name in ["FOOD", "WOOD", "GOLD", "STONE"]:
		check(seen.has(name), "AI scout discovers %s from visible observations" % name)
	for type in deposits:
		check(deposits[type] > 0, "AI workers naturally gather and deposit resource type %d" % type)
	print("SCOUT NATURAL SIM: %.1fs, discovered %s, deposits %s" % [elapsed, seen.keys(), deposits])
	state.frozen = true
	world.free()
	print("AI SCOUTING: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
