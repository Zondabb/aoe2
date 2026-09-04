extends RefCounted

const AI_CONTROLLER := preload("res://scripts/systems/ai_controller.gd")
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const ResourceNodeScript := preload("res://scripts/entities/resource_node.gd")
const TOWN_CENTER: BuildingDef = preload("res://data/buildings/town_center.tres")
const BARRACKS: BuildingDef = preload("res://data/buildings/barracks.tres")
const VILLAGER: UnitDef = preload("res://data/units/villager.tres")
const SWORDSMAN: UnitDef = preload("res://data/units/swordsman.tres")
const TEUTONS: CivDef = preload("res://data/civs/teutons.tres")
const CHINESE: CivDef = preload("res://data/civs/chinese.tres")

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_bootstrap_wires_ai(failures)
	_test_eco_assigns_gather_and_trains(failures)
	_test_ai_reassigns_after_food_depleted(failures)
	_test_military_builds_and_attack_phase(failures)
	_test_accelerated_match_progression(failures)
	_test_ai_stops_on_winner(failures)
	_test_hostile_scan_skips_placement_ghost(failures)
	return failures

func _test_bootstrap_wires_ai(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var game_session := tree.root.get_node_or_null("GameSession")
	if game_session != null:
		game_session.set("player_civ_id", &"chinese")
		game_session.set("ai_civ_id", &"teutons")
	var packed := load("res://scenes/match_2d.tscn") as PackedScene
	var scene_root := packed.instantiate()
	tree.root.add_child(scene_root)
	scene_root.get_node("Bootstrap").call("_ready")
	scene_root.get_node("Bootstrap").call("_setup_ai_gateway")
	var gateway := scene_root.get_node_or_null("AiGateway")
	if gateway == null:
		failures.append("match scene should contain AiGateway")
	elif gateway.get("match_state") == null or gateway.get("entities") == null:
		failures.append("bootstrap should configure the AI gateway")
	tree.root.remove_child(scene_root)
	scene_root.free()

func _test_eco_assigns_gather_and_trains(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)
	var entities := Node2D.new()
	entities.name = "Entities"
	root.add_child(entities)
	var state := MatchState.new()
	state.setup_defaults()
	state.register_pop(Enums.Team.AI, 0, 20)

	var town_center := BUILDING_VIEW.instantiate() as Node2D
	town_center.set("team", Enums.Team.AI)
	town_center.set("def", TOWN_CENTER)
	town_center.set("civ", TEUTONS)
	town_center.set("match_state", state)
	town_center.set("accepts_all_resources", true)
	town_center.set("sim_pos", Vector2(40.0, 40.0))
	entities.add_child(town_center)

	var villagers: Array[Node2D] = []
	for index in 3:
		var villager := UNIT_VIEW.instantiate() as Node2D
		villager.set("team", Enums.Team.AI)
		villager.set("def", VILLAGER)
		villager.set("civ", TEUTONS)
		villager.set("match_state", state)
		villager.set("sim_pos", Vector2(42.0 + index, 40.0))
		entities.add_child(villager)
		villagers.append(villager)

	_add_resource(entities, Enums.ResourceType.FOOD, Vector2(49.0, 42.0))
	_add_resource(entities, Enums.ResourceType.WOOD, Vector2(47.0, 34.0))
	_add_resource(entities, Enums.ResourceType.GOLD, Vector2(45.0, 49.0))

	var ai := AI_CONTROLLER.new()
	root.add_child(ai)
	ai.setup(state, entities, TEUTONS)
	ai.evaluate()

	var gathering := 0
	for villager in villagers:
		if villager.get("order") == Enums.OrderType.GATHER:
			gathering += 1
	if gathering != 3:
		failures.append("ECO AI should assign idle villagers to gather")
	if (town_center.get("train_queue") as Array).is_empty():
		failures.append("ECO AI should enqueue a villager at the town center")
	if ai.phase != AI_CONTROLLER.LegacyPhase.ECO:
		failures.append("AI should remain in ECO before villager target is met")

	state.add_resource(Enums.Team.AI, Enums.ResourceType.FOOD, 300)
	ai.evaluate()
	if ai.phase != AI_CONTROLLER.LegacyPhase.MILITARY:
		failures.append("high food stockpile should advance AI into MILITARY")

	root.free()


func _test_ai_reassigns_after_food_depleted(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)
	var entities := Node2D.new()
	entities.name = "Entities"
	root.add_child(entities)
	var state := MatchState.new()
	state.setup_defaults()
	state.register_pop(Enums.Team.AI, 0, 20)

	var town_center := BUILDING_VIEW.instantiate() as Node2D
	town_center.set("team", Enums.Team.AI)
	town_center.set("def", TOWN_CENTER)
	town_center.set("civ", TEUTONS)
	town_center.set("match_state", state)
	town_center.set("accepts_all_resources", true)
	town_center.set("sim_pos", Vector2(40.0, 40.0))
	entities.add_child(town_center)

	var villagers: Array[Node2D] = []
	for index in 3:
		var villager := UNIT_VIEW.instantiate() as Node2D
		villager.set("team", Enums.Team.AI)
		villager.set("def", VILLAGER)
		villager.set("civ", TEUTONS)
		villager.set("match_state", state)
		villager.set("sim_pos", Vector2(42.0 + index, 40.0))
		entities.add_child(villager)
		villager.call("_ready")
		villagers.append(villager)

	var food := _add_resource(entities, Enums.ResourceType.FOOD, Vector2(49.0, 42.0))
	_add_resource(entities, Enums.ResourceType.WOOD, Vector2(47.0, 34.0))
	_add_resource(entities, Enums.ResourceType.GOLD, Vector2(45.0, 49.0))

	var ai := AI_CONTROLLER.new()
	root.add_child(ai)
	ai.setup(state, entities, TEUTONS)
	ai.evaluate()
	food.amount = 0.0
	for villager in villagers:
		villager.set("order", Enums.OrderType.NONE)
		villager.set("_gather_state", "")
		villager.set("_last_resource", food)
	ai.evaluate()

	var wood_or_gold := 0
	for villager in villagers:
		if villager.get("order") != Enums.OrderType.GATHER:
			continue
		var resource: Node2D = villager.get("_last_resource")
		if resource == null:
			continue
		var resource_type: int = int(resource.get("resource_type"))
		if (
			resource_type == Enums.ResourceType.WOOD
			or resource_type == Enums.ResourceType.GOLD
		):
			wood_or_gold += 1
	if wood_or_gold != 3:
		failures.append(
			"after food depletes, AI should reassign idle villagers to wood or gold (got %d)"
			% wood_or_gold
		)
	root.free()


func _test_military_builds_and_attack_phase(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)
	var entities := Node2D.new()
	root.add_child(entities)
	var state := MatchState.new()
	state.setup_defaults()
	state.register_pop(Enums.Team.AI, 0, 30)
	state.add_resource(Enums.Team.AI, Enums.ResourceType.WOOD, 500)
	state.add_resource(Enums.Team.AI, Enums.ResourceType.GOLD, 200)

	var ai_tc := BUILDING_VIEW.instantiate() as Node2D
	ai_tc.set("team", Enums.Team.AI)
	ai_tc.set("def", TOWN_CENTER)
	ai_tc.set("civ", TEUTONS)
	ai_tc.set("match_state", state)
	ai_tc.set("sim_pos", Vector2(40.0, 40.0))
	entities.add_child(ai_tc)

	var player_tc := BUILDING_VIEW.instantiate() as Node2D
	player_tc.set("team", Enums.Team.PLAYER)
	player_tc.set("def", TOWN_CENTER)
	player_tc.set("civ", CHINESE)
	player_tc.set("match_state", state)
	player_tc.set("sim_pos", Vector2(-40.0, -40.0))
	entities.add_child(player_tc)

	for index in 8:
		var villager := UNIT_VIEW.instantiate() as Node2D
		villager.set("team", Enums.Team.AI)
		villager.set("def", VILLAGER)
		villager.set("civ", TEUTONS)
		villager.set("match_state", state)
		villager.set("sim_pos", Vector2(42.0 + (index % 4), 41.0 + int(index / 4)))
		entities.add_child(villager)

	_add_resource(entities, Enums.ResourceType.FOOD, Vector2(49.0, 42.0))
	_add_resource(entities, Enums.ResourceType.WOOD, Vector2(47.0, 34.0))
	_add_resource(entities, Enums.ResourceType.GOLD, Vector2(45.0, 49.0))

	var ai := AI_CONTROLLER.new()
	root.add_child(ai)
	ai.setup(state, entities, TEUTONS)
	ai.evaluate()
	if ai.phase != AI_CONTROLLER.LegacyPhase.MILITARY:
		failures.append("eight villagers should put AI into MILITARY")

	var foundations := 0
	for node in entities.get_children():
		var building_def := node.get("def") as BuildingDef
		if (
			building_def != null
			and node.get("team") == Enums.Team.AI
			and not bool(node.get("is_complete"))
		):
			foundations += 1
	if foundations < 1:
		failures.append("MILITARY AI should place at least one military foundation")

	for index in 6:
		var soldier := UNIT_VIEW.instantiate() as Node2D
		soldier.set("team", Enums.Team.AI)
		soldier.set("def", SWORDSMAN)
		soldier.set("civ", TEUTONS)
		soldier.set("match_state", state)
		soldier.set("sim_pos", Vector2(30.0 + index, 30.0))
		entities.add_child(soldier)

	ai.evaluate()
	if ai.phase != AI_CONTROLLER.LegacyPhase.ATTACK:
		failures.append("six military units should put AI into ATTACK")

	var attacking := 0
	for node in entities.get_children():
		var unit_def := node.get("def") as UnitDef
		if (
			unit_def != null
			and unit_def.id == &"swordsman"
			and node.get("order") == Enums.OrderType.ATTACK
		):
			attacking += 1
	if attacking < 6:
		failures.append("ATTACK AI should send military units at the player TC")

	ai.match_time = 0.0
	ai.phase = AI_CONTROLLER.LegacyPhase.MILITARY
	for node in entities.get_children().duplicate():
		var unit_def := node.get("def") as UnitDef
		if unit_def != null and unit_def.id == &"swordsman":
			node.free()
	ai.match_time = 180.0
	ai.evaluate()
	if ai.phase != AI_CONTROLLER.LegacyPhase.ATTACK:
		failures.append("match time >= 180s should force ATTACK phase")

	root.free()

func _test_accelerated_match_progression(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var game_session := tree.root.get_node_or_null("GameSession")
	if game_session != null:
		game_session.set("player_civ_id", &"chinese")
		game_session.set("ai_civ_id", &"teutons")
	var packed := load("res://scenes/match_2d.tscn") as PackedScene
	var scene_root := packed.instantiate()
	tree.root.add_child(scene_root)
	scene_root.get_node("Bootstrap").call("_ready")
	var bootstrap := scene_root.get_node("Bootstrap")
	var state := bootstrap.get("match_state") as MatchState
	var entities := scene_root.get_node("Entities") as Node2D
	var ai := AI_CONTROLLER.new()
	scene_root.add_child(ai)
	ai.setup(state, entities, TEUTONS, Enums.Team.AI, Enums.Team.PLAYER)
	state.add_resource(Enums.Team.AI, Enums.ResourceType.FOOD, 800)
	state.add_resource(Enums.Team.AI, Enums.ResourceType.WOOD, 800)
	state.add_resource(Enums.Team.AI, Enums.ResourceType.GOLD, 400)

	for _tick in 360:
		ai.set("match_time", float(ai.get("match_time")) + 0.5)
		ai.call("evaluate")
		for node in entities.get_children():
			if node.has_method("_physics_process"):
				node.call("_physics_process", 0.5)
			if (
				node.get("team") == Enums.Team.AI
				and node.get("def") is BuildingDef
				and not bool(node.get("is_complete"))
			):
				var building_def := node.get("def") as BuildingDef
				node.call("add_build_progress", building_def.build_time)

	var military := 0
	var complete_military_buildings := 0
	for node in entities.get_children():
		var unit_def := node.get("def") as UnitDef
		if unit_def != null and node.get("team") == Enums.Team.AI and unit_def.id != &"villager":
			military += 1
		var building_def := node.get("def") as BuildingDef
		if (
			building_def != null
			and node.get("team") == Enums.Team.AI
			and bool(node.get("is_complete"))
			and building_def.id in [&"barracks", &"archery_range", &"stable"]
		):
			complete_military_buildings += 1
	if ai.get("phase") != AI_CONTROLLER.LegacyPhase.ATTACK:
		failures.append("accelerated match should reach ATTACK phase")
	if complete_military_buildings < 2:
		failures.append("accelerated AI should complete barracks and archery")
	if military < 1 and float(ai.get("match_time")) < 180.0:
		failures.append("accelerated AI should train at least one military unit before time push")
	tree.root.remove_child(scene_root)
	scene_root.free()

func _test_ai_stops_on_winner(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var packed := load("res://scenes/match_2d.tscn") as PackedScene
	var scene_root := packed.instantiate()
	tree.root.add_child(scene_root)
	scene_root.get_node("Bootstrap").call("_ready")
	var ai := scene_root.get_node_or_null("AiGateway")
	var state := scene_root.get_node("Bootstrap").get("match_state") as MatchState
	var hud := scene_root.get_node_or_null("UILayer/HUD")
	state.set_winner(Enums.Team.PLAYER)
	if ai != null:
		ai.call("_process", 0.5)
	if ai != null and bool(ai.get("enabled")):
		failures.append("winner should stop the AI gateway")
	if ai != null and ai.is_processing():
		failures.append("winner should disable AI gateway processing")
	if hud == null or not bool(hud.get_node("ResultPanel").visible):
		failures.append("winner UI should still appear when AI is present")
	if not bool(state.get("frozen")):
		failures.append("winner should freeze MatchState simulation")
	var entities := scene_root.get_node("Entities")
	var player_unit := entities.get_node_or_null("PlayerVillager1") as Node2D
	if player_unit == null:
		failures.append("expected a player villager to verify freeze")
	else:
		var start_sim: Vector2 = player_unit.get("sim_pos")
		player_unit.call("command_move", start_sim + Vector2(8.0, 0.0))
		player_unit.call("_physics_process", 0.5)
		if player_unit.get("sim_pos").distance_to(start_sim) > 0.01:
			failures.append("winner freeze should stop player unit simulation")
	tree.root.remove_child(scene_root)
	scene_root.free()

func _test_hostile_scan_skips_placement_ghost(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)
	var entities := Node2D.new()
	root.add_child(entities)
	var state := MatchState.new()
	state.setup_defaults()
	var ai := AI_CONTROLLER.new()
	ai.entities = entities
	ai.player_team = Enums.Team.PLAYER
	ai.ai_team = Enums.Team.AI
	ai.match_state = state
	root.add_child(ai)
	var ghost := BUILDING_VIEW.instantiate() as Node2D
	ghost.set("team", Enums.Team.PLAYER)
	ghost.set("def", BARRACKS)
	ghost.set("is_placement_ghost", true)
	ghost.set("sim_pos", Vector2(2.0, 0.0))
	ghost.call("start_construction")
	entities.add_child(ghost)
	var scout := UNIT_VIEW.instantiate() as Node2D
	scout.set("team", Enums.Team.AI)
	scout.set("def", SWORDSMAN)
	scout.set("sim_pos", Vector2.ZERO)
	entities.add_child(scout)
	var nearest: Node2D = ai.call("_nearest_hostile_in_radius", scout, 20.0)
	if nearest != null:
		failures.append("AI hostile scan should skip placement ghosts")
	root.free()

func _add_resource(
	parent: Node2D,
	resource_type: Enums.ResourceType,
	spawn_position: Vector2
) -> Node2D:
	var resource := ResourceNodeScript.new()
	resource.resource_type = resource_type
	resource.amount = 200.0
	resource.gather_rate = 4.0
	resource.sim_pos = spawn_position
	parent.add_child(resource)
	return resource
