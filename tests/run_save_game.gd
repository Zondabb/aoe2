extends SceneTree

var Saves: GDScript
const Data := preload("res://scripts/world/map_data.gd")
const MapCatalog := preload("res://scripts/world/map_catalog.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")
var MATCH: PackedScene
const TEST_PATH := "user://saves/__save_game_roundtrip_test.json"
var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition: failures.append(message)

func _run() -> void:
	Saves = load("res://scripts/core/save_game_service.gd")
	MATCH = load("res://scenes/match_2d.tscn")
	var session := root.get_node("GameSession")
	session.online_active = false
	session.match_ai_mode = "sandbox"
	session.ai_service_token = "secret_token_must_never_be_serialized"
	session.match_map_data = Data.create(80, 80, "存档测试")
	var fixtures := [
		["building", "town_center", Vector2(-20, -15), "player", "tc"],
		["building", "town_center", Vector2(22, 20), "ai", "enemy_tc"],
		["building", "barracks", Vector2(-12, -15), "player", "barracks"],
		["building", "mill", Vector2(-20, -5), "player", "mill"],
		["building", "blacksmith", Vector2(-10, -5), "player", "blacksmith"],
		["building", "house", Vector2(-5, -15), "player", "house"],
		["building", "farm", Vector2(-18, 2), "player", "farm"],
		["building", "gate", Vector2(-10, 10), "player", "gate"],
		["building", "stone_wall", Vector2(-8, 12), "player", "wall"],
		["unit", "villager", Vector2(-18, -15), "player", "gatherer"],
		["unit", "villager", Vector2(-17, -15), "player", "builder"],
		["unit", "villager", Vector2(-16, -15), "player", "mover"],
		["unit", "militia", Vector2(-8, -12), "player", "fighter"],
		["unit", "militia", Vector2(-6, -12), "ai", "enemy"],
		["resource", "wood", Vector2(-22, -10), "player", "tree"],
	]
	for fixture in fixtures:
		var record := MapCatalog.make_record(fixture[0], fixture[1], fixture[2], fixture[3])
		record.id = fixture[4]
		session.match_map_data.entities.append(record)
	var match_root: Node = MATCH.instantiate()
	root.add_child(match_root)
	await process_frame
	await process_frame
	paused = true
	var boot: Node = match_root.get_node("Bootstrap")
	check(boot.setup_ready, "bootstrap exposes completed setup")
	var state: MatchState = boot.match_state
	var entities: Node = match_root.get_node("Entities")
	var by_name := {}
	for entity in entities.get_children(): by_name[String(entity.get_meta("map_id", ""))] = entity
	for team in 2:
		for type in 4: state.resources[team][type] = 12000 + type
	state.population_cap[0] = 100
	state.set_team_color_id(0, 8)
	var tc: BuildingAgent = by_name.tc
	var house: BuildingAgent = by_name.house
	var blacksmith: BuildingAgent = by_name.blacksmith
	check(tc.enqueue_train(Catalog.get_unit(&"villager")), "fixture enqueues first villager")
	check(tc.enqueue_train(Catalog.get_unit(&"villager")), "fixture enqueues second villager")
	tc.train_progress = 4.75
	tc.hp -= 117.0
	house.is_complete = false
	house._construction_started = true
	house._population_cap_registered = false
	house.build_progress = 3.5
	house.hp = 12.25
	by_name.farm.amount = 73.75
	by_name.tree.amount = 22.5
	by_name.gatherer.command_gather(by_name.tree)
	by_name.gatherer._gather_state = "to_drop_off"
	by_name.gatherer._drop_off_target = tc
	by_name.gatherer.carry_type = Enums.ResourceType.WOOD
	by_name.gatherer.carry_amount = 8.5
	by_name.builder.command_build(house)
	by_name.wall.start_construction()
	by_name.builder.command_build_queue([by_name.wall], true)
	by_name.gate.wall_orientation = 3
	by_name.gate.set_gate_state("locked")
	by_name.mover.command_move(Vector2(0, 8))
	by_name.fighter.command_attack(by_name.enemy)
	by_name.fighter._attack_cooldown_remaining = 0.75
	by_name.enemy.hp = 11.5
	# Real paid research records are restored as authority jobs, not replicas.
	var age: Node = state.age_progression
	state.spend(1, 500, 0, 0)
	age._jobs[1] = {"building": weakref(by_name.enemy_tc), "target_age": 1, "elapsed": 47.25, "duration": 130.0, "food": 500, "gold": 0}
	state.set_age(0, 1)
	var research_building: BuildingAgent = by_name.barracks
	check(research_building.start_technology("man_at_arms"), "fixture starts technology research")
	state.technology_progression.jobs[research_building.get_instance_id()].elapsed = 11.5
	state.technology_progression.jobs[research_building.get_instance_id()].progress = 11.5 / float(state.technology_progression.jobs[research_building.get_instance_id()].duration)
	state.researched_technologies[1]["chemistry"] = true
	state.fog.explored[0][0] = 255
	var camera: Camera2D = match_root.get_node("Camera2D")
	camera.position = Vector2(123, -234)
	camera.zoom = Vector2(1.25, 1.25)
	var data: Dictionary = Saves.capture(boot)
	check(Saves.validate(data).is_empty(), "captured match validates: " + Saves.validate(data))
	var before_stock: Dictionary = state.resources.duplicate(true)
	var before_population: Dictionary = state.population.duplicate(true)
	var before_reserved: Dictionary = state.population_reserved.duplicate(true)
	var save_error: String = Saves.save(boot, TEST_PATH)
	check(save_error.is_empty(), "paused match saves: " + save_error)
	check(Saves.save(boot, TEST_PATH).is_empty(), "existing save can be atomically replaced")
	var raw := FileAccess.get_file_as_string(TEST_PATH)
	check(not raw.contains(session.ai_service_token) and not raw.contains("ai_service_token"), "save excludes bearer credentials")
	var loaded: Dictionary = Saves.read(TEST_PATH)
	check(loaded.error.is_empty(), "file roundtrip validates: " + loaded.error)
	var damaged: Dictionary = data.duplicate(true)
	damaged.schema_version = 99
	check(not Saves.validate(damaged).is_empty(), "future versions rejected")
	damaged = data.duplicate(true)
	for record in damaged.entities:
		if record.type == "unit":
			record.refs._attack_target = 11999
			break
	check(not Saves.validate(damaged).is_empty(), "dangling target references rejected")
	damaged = data.duplicate(true)
	damaged.entities[0].fields = null
	check(not Saves.validate(damaged).is_empty(), "damaged entity attributes rejected")
	check(Saves.prepare_load(TEST_PATH).is_empty(), "prepare load accepts valid file")
	match_root.free()
	match_root = MATCH.instantiate()
	root.add_child(match_root)
	await process_frame
	await process_frame
	boot = match_root.get_node("Bootstrap")
	state = boot.match_state
	entities = match_root.get_node("Entities")
	by_name.clear()
	for entity in entities.get_children():
		if entity.has_meta("map_id"): by_name[String(entity.get_meta("map_id"))] = entity
	check(boot.setup_ready and session.pending_save_data.is_empty(), "bootstrap consumes saved data once")
	check(by_name.size() == fixtures.size(), "restored match has every entity once")
	check(state.resources == before_stock and state.population == before_population and state.population_reserved == before_reserved, "restored economy and population do not duplicate ready registration")
	tc = by_name.tc
	house = by_name.house
	blacksmith = by_name.blacksmith
	check(tc.train_queue.size() == 2 and is_equal_approx(tc.train_progress, 4.75), "production queue and elapsed time restored")
	check(is_equal_approx(tc.hp, data.entities[0].fields.hp), "damaged completed building keeps HP")
	check(not house.is_complete and is_equal_approx(house.build_progress, 3.5) and is_equal_approx(house.hp, 12.25), "damaged unfinished building keeps progress and HP")
	check(is_equal_approx(by_name.farm.amount, 73.75) and is_equal_approx(by_name.tree.amount, 22.5), "farm and natural resource depletion restored")
	check(by_name.gatherer._last_resource == by_name.tree and by_name.gatherer._drop_off_target == tc and is_equal_approx(by_name.gatherer.carry_amount, 8.5), "gather and dropoff references map to restored actors")
	check(by_name.builder._build_target == house and by_name.builder.order == Enums.OrderType.BUILD, "builder resumes foundation")
	check(by_name.builder.get_build_queue_ids().size() == 1 and by_name.builder._build_queue[0].get_ref() == by_name.wall, "wall construction queue survives save/load")
	check(by_name.gate.wall_orientation == 3 and by_name.gate.gate_state == "locked" and by_name.gate.get_movement_half() == Vector2(2, 2), "rotated gate state and collision survive save/load")
	check(by_name.mover.order == Enums.OrderType.MOVE and by_name.mover._requested_move_target == Vector2(0, 8), "movement goal restored")
	check(by_name.fighter._attack_target == by_name.enemy and is_equal_approx(by_name.fighter._attack_cooldown_remaining, 0.75) and is_equal_approx(by_name.enemy.hp, 11.5), "attack target and damage restored")
	check(not by_name.fighter.has_meta("network_replica") and not state.age_progression.network_replica and not state.technology_progression.replica, "restored actors and research continue authority simulation")
	check(state.age_of(0) == 1 and state.has_technology(1, &"chemistry") and state.get_team_color_id(0) == 8, "age technology and palette restored")
	check(is_equal_approx(state.age_progression.progress_for(1).elapsed, 47.25), "age research continues from saved time")
	check(is_equal_approx(state.technology_progression.progress_for(by_name.barracks).elapsed, 11.5), "technology research continues from saved time")
	check(state.fog.explored[0][0] == 255, "exploration remains explored")
	camera = match_root.get_node("Camera2D")
	check(camera.position == Vector2(123, -234) and camera.zoom == Vector2(1.25, 1.25), "camera position and zoom restored")
	var food := state.get_resource(0, Enums.ResourceType.FOOD)
	check(tc.cancel_train(tc.train_queue_ids[1]) and state.get_resource(0, Enums.ResourceType.FOOD) == food + Catalog.get_unit(&"villager").cost_food, "restored production cancels and refunds original cost")
	state.age_progression._process(83.0)
	check(state.age_of(1) == 1 and not state.age_progression.is_researching(1), "restored age research completes normally")
	state.technology_progression._process(100.0)
	check(state.has_technology(0, &"man_at_arms"), "restored technology research completes normally")
	tc._physics_process(100.0)
	check(tc.train_queue.is_empty(), "restored queue trains units normally")
	session.online_active = true
	check(not Saves.save(boot, TEST_PATH).is_empty() and not Saves.prepare_load(TEST_PATH).is_empty(), "online save and load rejected")
	session.online_active = false
	match_root.free()
	# Exercise a real local director through the same fresh-scene handoff.
	session.match_ai_mode = "local"
	session.match_map_data = data.map.duplicate(true)
	match_root = MATCH.instantiate()
	root.add_child(match_root)
	await process_frame
	await process_frame
	boot = match_root.get_node("Bootstrap")
	var ai: Node = match_root.get_node("AiController")
	ai.match_time = 456.25
	ai._tick_accum = 0.35
	ai._next_build_slot = 9
	ai.director_phase = 2
	ai._previous_phase = 1
	check(Saves.save(boot, TEST_PATH).is_empty() and Saves.prepare_load(TEST_PATH).is_empty(), "running local AI saves and prepares")
	match_root.free()
	match_root = MATCH.instantiate()
	root.add_child(match_root)
	await process_frame
	await process_frame
	boot = match_root.get_node("Bootstrap")
	ai = match_root.get_node("AiController")
	check(is_equal_approx(ai.match_time, 456.25) and is_equal_approx(ai._tick_accum, 0.35) and ai._next_build_slot == 9 and ai.director_phase == 2 and ai._previous_phase == 1, "local AI runtime and strategic phase survive reload")
	check(ai.enabled and ai.is_processing(), "restored local AI remains active")
	ai._process(0.8)
	check(ai.match_time > 456.25, "restored local AI advances runtime and decisions")
	state = boot.match_state
	state.set_winner(0)
	check(Saves.save(boot, TEST_PATH).is_empty() and Saves.prepare_load(TEST_PATH).is_empty(), "finished match saves and prepares")
	match_root.free()
	match_root = MATCH.instantiate()
	root.add_child(match_root)
	await process_frame
	await process_frame
	boot = match_root.get_node("Bootstrap")
	var hud: Node = match_root.get_node("UILayer/HUD")
	check(boot.match_state.winner == 0 and boot.match_state.frozen and hud._result_panel.visible and hud._result_label.text == "胜利", "finished match restores frozen winner and HUD result")
	check(not match_root.get_node("UILayer/SelectionController").is_processing_unhandled_input(), "finished match restores disabled commands")
	match_root.free()
	# The generated settlement uses many forest objects and fog memories.
	session.match_ai_mode = "sandbox"
	session.match_map_data = {}
	match_root = MATCH.instantiate()
	root.add_child(match_root)
	await process_frame
	await process_frame
	boot = match_root.get_node("Bootstrap")
	check(Saves.save(boot, TEST_PATH).is_empty() and Saves.read(TEST_PATH).error.is_empty(), "generated default settlement creates a readable save")
	match_root.free()
	DirAccess.remove_absolute(TEST_PATH)
	for failure in failures: push_error(failure)
	print("SAVE GAME TESTS: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
