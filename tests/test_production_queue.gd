extends RefCounted

const BUILDING := preload("res://scenes/entities/building_view.tscn")
const TC := preload("res://data/buildings/town_center.tres")
const BARRACKS := preload("res://data/buildings/barracks.tres")
const VILLAGER := preload("res://data/units/villager.tres")
const CHINESE := preload("res://data/civs/chinese.tres")
var failures: Array[String] = []

func run() -> Array[String]:
	_test_order_and_refunds()
	_test_limits_and_cleanup()
	_test_population_pause()
	return failures

func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)

func _world() -> Node2D:
	var world := Node2D.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(world)
	return world

func _state() -> MatchState:
	var state := MatchState.new()
	state.setup_defaults()
	state.population_cap[0] = 100
	for type in 4:
		state.resources[0][type] = 10000
	return state

func _building(world: Node, state: MatchState, definition: BuildingDef = TC) -> BuildingAgent:
	var building := BUILDING.instantiate() as BuildingAgent
	building.def = definition
	building.civ = CHINESE
	building.match_state = state
	world.add_child(building)
	if building.hp <= 0.0:
		building._ready()
	return building

func _test_order_and_refunds() -> void:
	var world := _world()
	var state := _state()
	var definition := BARRACKS.duplicate() as BuildingDef
	var soldier := BARRACKS.trainable[0].duplicate() as UnitDef
	soldier.population = 2
	soldier.cost_stone = 7
	soldier.train_time = 4.0
	definition.trainable.assign([VILLAGER, soldier])
	var building := _building(world, state, definition)
	var initial: Dictionary = state.resources[0].duplicate()
	check(building.enqueue_train(VILLAGER), "villager can start training")
	building._physics_process(2.0)
	check(building.enqueue_train(soldier) and building.enqueue_train(VILLAGER), "mixed units can be queued behind the active unit")
	check(is_equal_approx(building.train_progress, 2.0), "appending never resets current progress")
	check(state.population_reserved[0] == 4, "all queued population is accounted for")
	var removed_id := building.train_queue_ids[1]
	var upgraded := soldier.duplicate() as UnitDef
	upgraded.cost_food += 30
	upgraded.cost_stone += 10
	building.train_queue[1] = upgraded
	check(building.cancel_train(removed_id), "a waiting item can be cancelled")
	check(is_equal_approx(building.train_progress, 2.0), "cancelling a waiting item preserves progress")
	check(not building.cancel_train(removed_id), "repeated cancellation never refunds twice")
	check(state.resources[0][3] == initial[3] and state.population_reserved[0] == 2, "upgraded queued units refund original cost and release only their reservation")
	check(building.cancel_train(building.train_queue_ids[0]), "active item can be cancelled")
	check(building.train_progress == 0.0 and building.train_queue.size() == 1, "new head starts at zero")
	check(state.resources[0][0] == initial[0] - VILLAGER.cost_food, "cancelled units refund food in full")
	var first_id := building.train_queue_ids[0]
	check(building.enqueue_train(soldier), "soldier can follow villager")
	var duration := VILLAGER.train_time * CHINESE.villager_train_time_mul
	building._physics_process(duration + 1.0)
	check(building.train_queue.size() == 1 and building.train_queue[0] == soldier and is_equal_approx(building.train_progress, 1.0), "FIFO preserves unused tick time for the next unit")
	check(state.population[0] == 1 and state.population_reserved[0] == 2, "completion releases only the completed population reservation")
	check(not building.cancel_train(first_id), "late cancellation of a completed unit cannot cancel the next item")
	building._physics_process(3.0)
	check(building.train_queue.is_empty() and building.train_queue_ids.is_empty(), "queue and identities empty after completion")
	check(state.population[0] == 3 and state.population_reserved[0] == 0, "mixed population costs transfer correctly")
	check(world.get_child_count() == 3 and world.get_child(1).def.id == VILLAGER.id and world.get_child(2).def.id == soldier.id, "units spawn in queue order")
	check(not building.is_physics_processing(), "empty queue stops production processing")
	world.free()

func _test_limits_and_cleanup() -> void:
	var world := _world()
	var state := _state()
	var building := _building(world, state, BARRACKS)
	var soldier := building.get_trainable_units()[0]
	for i in BuildingAgent.MAX_TRAIN_QUEUE:
		check(building.enqueue_train(soldier), "queue accepts slot %d" % i)
	var food := state.get_resource(0, Enums.ResourceType.FOOD)
	check(not building.enqueue_train(soldier) and state.get_resource(0, Enums.ResourceType.FOOD) == food, "full queue rejects without charging")
	state.frozen = true
	building._physics_process(100.0)
	check(building.train_progress == 0.0 and not building.cancel_train(building.train_queue_ids[0]), "frozen matches cannot advance or cancel production")
	state.frozen = false
	var released_id: int = building.train_queue_ids.back()
	check(building.cancel_train(released_id) and building.enqueue_train(soldier), "cancelling frees a queue slot")
	check(building.train_queue_ids.back() > released_id, "queue IDs never reuse a removed item")
	food = state.get_resource(0, Enums.ResourceType.FOOD)
	building.take_damage(building.hp)
	building._physics_process(1000.0)
	check(state.population[0] == 0, "destroyed buildings cannot finish queued units before deletion")
	# The legacy aggregate runner executes before SceneTree enters its root.
	if not building.is_inside_tree():
		building._exit_tree()
	building.free()
	check(state.population_reserved[0] == 0, "building removal releases all outstanding reservations")
	check(state.get_resource(0, Enums.ResourceType.FOOD) == food, "building destruction does not refund production")
	building = _building(world, state)
	building.set_meta("network_replica", true)
	check(not building.enqueue_train(VILLAGER), "replicas cannot debit resources locally")
	building.remove_meta("network_replica")
	state.resources[0][0] = 0
	check(not building.enqueue_train(VILLAGER), "insufficient resources reject enqueue")
	state.resources[0][0] = 1000
	building.is_complete = false
	check(not building.enqueue_train(VILLAGER), "unfinished buildings cannot train")
	world.free()

func _test_population_pause() -> void:
	var world := _world()
	var state := _state()
	var building := _building(world, state)
	state.population_cap[0] = 0
	check(building.enqueue_train(VILLAGER) and building.enqueue_train(VILLAGER), "population-full players can prepare a production queue")
	building._physics_process(100.0)
	check(building.is_training_population_blocked() and building.train_progress == 0.0, "no training progress accumulates while population is full")
	state.population_cap[0] = 1
	building._physics_process(2.0)
	state.population_cap[0] = 0
	building._physics_process(100.0)
	check(building.train_progress == 2.0, "losing population capacity pauses without resetting progress")
	state.population_cap[0] = 1
	building._physics_process(1000.0)
	check(state.population[0] == 1 and building.train_queue.size() == 1 and building.train_progress == 0.0, "large ticks cannot overflow population or bank blocked time")
	state.population_cap[0] = 2
	building._physics_process(VILLAGER.train_time)
	check(building.train_queue.is_empty() and state.population[0] == 2, "production resumes automatically when capacity increases")
	world.free()
