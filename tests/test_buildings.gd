extends RefCounted

const BUILD_SYSTEM := preload("res://scripts/systems/build_system.gd")
const BUILDING_AGENT := preload("res://scripts/entities/building_agent.gd")
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const HOUSE: BuildingDef = preload("res://data/buildings/house.tres")
const BARRACKS: BuildingDef = preload("res://data/buildings/barracks.tres")
const TOWN_CENTER: BuildingDef = preload("res://data/buildings/town_center.tres")
const ARCHERY_RANGE: BuildingDef = preload("res://data/buildings/archery_range.tres")
const VILLAGER: UnitDef = preload("res://data/units/villager.tres")
const CHINESE: CivDef = preload("res://data/civs/chinese.tres")
const TEUTONS: CivDef = preload("res://data/civs/teutons.tres")

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_placement_rejects_overlap(failures)
	_test_villager_constructs_building(failures)
	_test_train_queue_spends_and_spawns(failures)
	_test_parallel_queues_reserve_population(failures)
	_test_trainables_are_filtered_by_civ(failures)
	_test_placement_ghost_not_attackable(failures)
	_test_cancel_placement_after_ghost_freed(failures)
	return failures

func _test_placement_rejects_overlap(failures: Array[String]) -> void:
	var existing := BUILDING_AGENT.new()
	existing.def = HOUSE
	existing.sim_pos = Vector2.ZERO
	if BUILD_SYSTEM.can_place(HOUSE.footprint, Vector2.ZERO, [existing]):
		failures.append("building placement should reject footprint overlap")
	if not BUILD_SYSTEM.can_place(HOUSE.footprint, Vector2(3.0, 0.0), [existing]):
		failures.append("building placement should allow separated footprints")
	existing.free()

func _test_villager_constructs_building(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)
	var state := MatchState.new()
	state.setup_defaults()

	var house := BUILDING_VIEW.instantiate() as Node2D
	house.set("def", HOUSE)
	house.set("match_state", state)
	house.set("sim_pos", Vector2.ZERO)
	house.call("start_construction")
	root.add_child(house)

	var villager := UNIT_VIEW.instantiate() as UnitAgent
	villager.def = VILLAGER
	villager.match_state = state
	villager.sim_pos = Vector2.ZERO
	root.add_child(villager)
	villager.command_build(house)
	villager._physics_process(HOUSE.build_time)

	if not bool(house.get("is_complete")):
		failures.append("villager BUILD order should complete construction")
	if state.population_cap[Enums.Team.PLAYER] != HOUSE.population_provided:
		failures.append("completed building should register population capacity once")
	if villager.order != Enums.OrderType.NONE:
		failures.append("villager should become idle after construction completes")
	root.free()

func _test_train_queue_spends_and_spawns(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)
	var state := MatchState.new()
	state.setup_defaults()
	var initial_food := state.get_resource(Enums.Team.PLAYER, Enums.ResourceType.FOOD)

	var town_center := BUILDING_VIEW.instantiate() as Node2D
	town_center.set("def", TOWN_CENTER)
	town_center.set("civ", CHINESE)
	town_center.set("match_state", state)
	town_center.set("sim_pos", Vector2.ZERO)
	root.add_child(town_center)
	town_center.call("_ready")

	if not bool(town_center.call("enqueue_train", VILLAGER)):
		failures.append("completed town center should enqueue an affordable villager")
	if bool(town_center.call("enqueue_train", VILLAGER)):
		failures.append("building train queue should have a maximum size of one")
	if state.get_resource(Enums.Team.PLAYER, Enums.ResourceType.FOOD) != initial_food - VILLAGER.cost_food:
		failures.append("enqueueing a unit should spend its resource cost")

	town_center.call(
		"_physics_process",
		VILLAGER.train_time * CHINESE.villager_train_time_mul
	)
	if not (town_center.get("train_queue") as Array).is_empty():
		failures.append("training should finish using the Chinese villager time multiplier")
	if state.population[Enums.Team.PLAYER] != VILLAGER.population:
		failures.append("trained unit should register used population")
	if root.get_child_count() != 2:
		failures.append("completed training should spawn a unit beside the building")
	root.free()

func _test_parallel_queues_reserve_population(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)
	var state := MatchState.new()
	state.setup_defaults()
	var town_centers: Array[Node2D] = []
	for index in 2:
		var town_center := BUILDING_VIEW.instantiate() as Node2D
		town_center.name = "TownCenter%d" % index
		town_center.set("def", TOWN_CENTER)
		town_center.set("match_state", state)
		town_center.set("sim_pos", Vector2(float(index) * 10.0, 0.0))
		root.add_child(town_center)
		town_center.call("_ready")
		town_centers.append(town_center)
	state.population[Enums.Team.PLAYER] = (
		state.population_cap[Enums.Team.PLAYER] - 1
	)
	if not bool(town_centers[0].call("enqueue_train", VILLAGER)):
		failures.append("first queue should reserve the final population slot")
	if bool(town_centers[1].call("enqueue_train", VILLAGER)):
		failures.append("parallel queue should not overbook reserved population")
	root.free()

func _test_trainables_are_filtered_by_civ(failures: Array[String]) -> void:
	var range_building := BUILDING_AGENT.new()
	range_building.def = ARCHERY_RANGE
	range_building.civ = CHINESE
	var chinese_units := range_building.get_trainable_units()
	if chinese_units.size() != 2 or CHINESE.unique_unit not in chinese_units:
		failures.append("Chinese archery range should expose archer and Chu Ko Nu")
	range_building.civ = TEUTONS
	var teuton_units := range_building.get_trainable_units()
	if teuton_units.size() != 1 or CHINESE.unique_unit in teuton_units:
		failures.append("Teuton archery range should not expose the Chinese unique unit")
	range_building.free()

func _test_placement_ghost_not_attackable(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)
	var ghost := BUILDING_VIEW.instantiate() as Node2D
	ghost.set("team", Enums.Team.PLAYER)
	ghost.set("def", HOUSE)
	ghost.set("is_placement_ghost", true)
	ghost.set("sim_pos", Vector2.ZERO)
	ghost.call("start_construction")
	root.add_child(ghost)
	var hp_before: float = float(ghost.get("hp"))
	ghost.call("take_damage", 50.0)
	if float(ghost.get("hp")) != hp_before:
		failures.append("placement ghost take_damage should be a no-op")
	if ghost.is_queued_for_deletion():
		failures.append("placement ghost should not be destroyed by damage")
	var attacker := UNIT_VIEW.instantiate() as UnitAgent
	attacker.def = VILLAGER
	attacker.team = Enums.Team.AI
	attacker.sim_pos = Vector2.ZERO
	root.add_child(attacker)
	attacker.command_attack(ghost)
	if attacker.order == Enums.OrderType.ATTACK:
		failures.append("command_attack should refuse placement ghosts")
	root.free()

func _test_cancel_placement_after_ghost_freed(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)
	var build_system := BUILD_SYSTEM.new()
	root.add_child(build_system)
	var ghost := BUILDING_VIEW.instantiate() as Node2D
	ghost.set("is_placement_ghost", true)
	root.add_child(ghost)
	build_system.set("_ghost", ghost)
	ghost.free()
	build_system.call("cancel_placement")
	if build_system.get("_ghost") != null:
		failures.append("cancel_placement should clear a freed ghost reference safely")
	if bool(build_system.call("is_placing")):
		failures.append("cancel_placement after external free should end placement")
	root.free()
