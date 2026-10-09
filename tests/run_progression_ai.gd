extends SceneTree
## Strategy regression: real match wiring, real production and research durations.
## Foundations finish immediately; unit combat/movement is paused to isolate AI choices.

const Catalog := preload("res://scripts/data/game_catalog.gd")
const Director := preload("res://scripts/systems/ai/ai_director.gd")
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
	for civilization in [&"chinese", &"teutons"]:
		await _run_civilization(civilization)
	check(checks > 20, "both civilization scenarios completed")
	print("PROGRESSION AI: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _run_civilization(civilization: StringName) -> void:
	var session := root.get_node("GameSession")
	session.match_ai_mode = "sandbox"
	session.match_map_data = {}
	session.online_active = false
	session.player_civ_id = &"teutons" if civilization == &"chinese" else &"chinese"
	session.ai_civ_id = civilization
	var world := load("res://scenes/match_2d.tscn").instantiate() as Node
	root.add_child(world)
	current_scene = world
	await process_frame
	await process_frame
	var state: MatchState = world.get_node("Bootstrap").match_state
	var entities: Node2D = world.get_node("Entities")
	world.get_node("LandSupport").set_process(false)
	world.get_node("Camera2D").set_process(false)
	state.age_progression.set_process(false)
	state.technology_progression.set_process(false)
	state.fog_enabled = false
	for resource in Enums.ResourceType.values():
		state.resources[Enums.Team.AI][resource] = 100000
	for entity in entities.get_children():
		entity.set_physics_process(false)
	var ai := Director.new()
	world.add_child(ai)
	ai.setup(state, entities, load("res://data/civs/%s.tres" % civilization), Enums.Team.AI, Enums.Team.PLAYER, "AgeTest", null, false)
	ai.decision_log.enabled = false
	preload("res://scripts/debug/unit_debug_focus.gd").set_spectator_mode(true)
	var age_events: Array[int] = []
	var age_start_requirements: Array[bool] = []
	state.age_changed.connect(func(team: int, age: int):
		if team == Enums.Team.AI: age_events.append(age)
	)
	state.age_progression.research_started.connect(func(team: int, age: int):
		if team == Enums.Team.AI:
			age_start_requirements.append(state.age_progression.has_prerequisites(team, age))
	)
	var completed: Dictionary = {}
	var military: Dictionary = {}
	var queued: Dictionary = {}
	var initial_units: Dictionary = {}
	for entity in entities.get_children():
		if entity is UnitAgent: initial_units[entity.get_instance_id()] = true
	var parked: Dictionary = {}
	var imperial_at := -1.0
	check(state.progression_enabled and state.age_of(Enums.Team.AI) == 0, "%s AI begins in Dark Age" % civilization)
	check(world.get_node_or_null("AiGateway") == null, "%s fixture does not contact external AI" % civilization)
	for step in 240:
		var now := float(step * 5)
		ai.match_time = now
		ai.evaluate()
		# Complete only foundations the AI actually ordered and paid for.
		for entity in entities.get_children():
			entity.set_physics_process(false)
			if entity is BuildingAgent and entity.team == Enums.Team.AI:
				if not entity.is_complete:
					entity.add_build_progress(entity.def.build_time)
				completed[String(entity.def.id)] = true
				for unit: UnitDef in entity.train_queue:
					queued[String(unit.id)] = true
					check(Catalog.civilization_allows(Catalog.unit_record(unit.id), civilization), "%s queued legal unit %s" % [civilization, unit.id])
				entity._physics_process(5.0)
				entity.set_physics_process(false)
		# Keep spawn space free without running combat or gathering in this strategy test.
		for entity in entities.get_children():
			entity.set_physics_process(false)
			if entity is not UnitAgent: continue
			if entity.order == Enums.OrderType.BUILD and is_instance_valid(entity._build_target) and entity._build_target.is_complete:
				entity.command_stop()
			if entity.team != Enums.Team.AI or initial_units.has(entity.get_instance_id()): continue
			if not parked.has(entity.get_instance_id()):
				var index := parked.size()
				entity.sim_pos = Vector2(-45 + (index % 20) * 2, 25 + floori(index / 20.0) * 2)
				parked[entity.get_instance_id()] = true
			if entity.def.id != &"villager": military[String(entity.def.id)] = true
		state.age_progression._process(5.0)
		state.technology_progression._process(5.0)
		if imperial_at < 0 and state.age_of(Enums.Team.AI) == 3:
			imperial_at = now + 5.0
		var unique_unit := "chu_ko_nu" if civilization == &"chinese" else "teutonic_knight"
		if imperial_at > 0 and queued.has(unique_unit) and not state.researched_technologies[Enums.Team.AI].is_empty(): break
		if step % 40 == 0:
			await process_frame
	check(age_events == [1, 2, 3], "%s AI autonomously advances all three ages: %s" % [civilization, age_events])
	check(age_start_requirements.size() == 3 and not age_start_requirements.has(false), "%s each age begins with legitimate building prerequisites" % civilization)
	check(imperial_at >= 480.0 and imperial_at <= 1200.0, "%s AI respects research durations and reaches Imperial in simulation" % civilization)
	check(completed.has("mill") and (completed.has("lumber_camp") or completed.has("barracks")), "%s AI constructs two distinct initial age prerequisites" % civilization)
	check(completed.has("barracks") and completed.has("archery_range") and completed.has("castle"), "%s military construction continues after attack phase" % civilization)
	check(state.age_of(Enums.Team.PLAYER) == 0, "%s AI does not modify opponent age" % civilization)
	check(military.size() >= 3 and queued.size() >= 4, "%s AI trains varied land troops" % civilization)
	check(not state.researched_technologies[Enums.Team.AI].is_empty(), "%s AI researches army upgrades" % civilization)
	var unique := "chu_ko_nu" if civilization == &"chinese" else "teutonic_knight"
	check(queued.has(unique) or queued.has("elite_" + unique), "%s AI trains civilization unique unit" % civilization)
	for entity in entities.get_children():
		if entity is UnitAgent and entity.team == Enums.Team.AI:
			check(Catalog.civilization_allows(Catalog.unit_record(entity.def.id), civilization), "%s army contains legal unit %s" % [civilization, entity.def.id])
	print("AI CIV %s: Imperial at %.0fs; buildings=%s; trained=%s; upgrades=%s" % [civilization, imperial_at, completed.keys(), military.keys(), state.researched_technologies[Enums.Team.AI].keys()])
	world.free()
	current_scene = null
	await process_frame
