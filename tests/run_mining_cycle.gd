extends SceneTree

const Fog := preload("res://scripts/systems/fog_of_war_service.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func _fixture(type: Enums.ResourceType, building_id: StringName, fog_enabled: bool) -> Dictionary:
	var world := Node2D.new()
	root.add_child(world)
	var state := MatchState.new()
	state.setup_defaults()
	state.progression_enabled = true
	state.fog_enabled = fog_enabled
	state.fog = Fog.new()
	# Keep the mine beyond the newly enlarged worker and drop-off LOS so this
	# still exercises remembered gather orders while returning through fog.
	var mine_distance := GameCatalog.get_building(building_id).resolved_vision_radius() + GameCatalog.get_unit(&"villager").resolved_vision_radius() + 8.0
	var extent := ceili(mine_distance + 8.0)
	state.fog.setup(-extent, extent)
	var mine := ResourceNode.new()
	mine.resource_type = type
	mine.amount = 500
	mine.gather_rate = 10
	mine.sim_pos = Vector2(mine_distance, 0)
	world.add_child(mine)
	var deposit := BuildingAgent.new()
	deposit.def = GameCatalog.get_building(building_id)
	deposit.match_state = state
	deposit.accepts_all_resources = building_id == &"town_center"
	world.add_child(deposit)
	deposit.set_physics_process(false)
	var worker := UnitAgent.new()
	worker.def = GameCatalog.get_unit(&"villager")
	worker.match_state = state
	worker.sim_pos = mine.sim_pos - Vector2(2, 0)
	world.add_child(worker)
	worker.set_physics_process(false)
	var navigation := NavServiceHolder.new()
	world.add_child(navigation)
	navigation.setup(-extent, extent)
	navigation.rebuild_from_scene()
	navigation.set_process(false)
	state.fog.rebuild([worker, deposit])
	worker.command_gather(mine)
	return {"world":world, "state":state, "mine":mine, "deposit":deposit, "worker":worker, "navigation":navigation}

func _step(f: Dictionary) -> void:
	f.state.fog.rebuild([f.worker, f.deposit])
	f.navigation._process(0.1)
	f.worker._physics_process(0.1)

func _run() -> void:
	for type in [Enums.ResourceType.GOLD, Enums.ResourceType.STONE]:
		for building_id in [&"town_center", &"mining_camp"]:
			for fog_enabled in [true, false]:
				_test_cycles(type, building_id, fog_enabled)
		_test_hidden_depletion(type)
		_test_cancel_return(type)
	var economy_errors: Array[String] = preload("res://tests/test_economy.gd").new().run()
	check(economy_errors.is_empty(), "existing economy regressions: %s" % str(economy_errors))
	print("MINING CYCLE: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _test_cycles(type: Enums.ResourceType, building_id: StringName, fog_enabled: bool) -> void:
	var f := _fixture(type, building_id, fog_enabled)
	var initial: int = f.state.get_resource(0, type)
	var label := "type=%d drop-off=%s fog=%s" % [type, building_id, fog_enabled]
	var hidden_return := false
	var order_lost := false
	for step in 1500:
		_step(f)
		if f.state.get_resource(0, type) > initial and not f.state.fog.can_see(0, f.mine):
			hidden_return = true
		if f.worker.order != Enums.OrderType.GATHER:
			order_lost = true
			break
		if f.state.get_resource(0, type) >= initial + 40:
			break
	check(not order_lost, "gather order survives complete mining trips: " + label)
	check(f.state.get_resource(0, type) >= initial + 40, "at least four loads are deposited: " + label)
	check(hidden_return, "fixture returns through fog beyond building vision: " + label)
	check(is_equal_approx(f.mine.amount + f.worker.carry_amount + f.state.get_resource(0, type) - initial, 500), "mined resources are conserved: " + label)
	f.world.free()

func _test_hidden_depletion(type: Enums.ResourceType) -> void:
	var f := _fixture(type, &"town_center", true)
	var initial: int = f.state.get_resource(0, type)
	for step in 500:
		_step(f)
		if f.worker.get("_gather_state") == "to_drop_off" and not f.state.fog.can_see(0, f.mine):
			break
	check(not f.state.fog.can_see(0, f.mine), "depletion fixture has lost sight")
	f.mine.amount = 0
	f.navigation.rebuild_from_scene()
	for step in 500:
		_step(f)
		if f.state.get_resource(0, type) > initial:
			break
	check(f.worker.order == Enums.OrderType.GATHER, "hidden depletion does not cancel remembered gather task at deposit")
	for step in 500:
		_step(f)
		if f.worker.order == Enums.OrderType.NONE:
			break
	check(f.worker.order == Enums.OrderType.NONE and f.state.fog.can_see(0, f.mine), "worker stops when depleted mine is observed again")
	check(f.state.get_resource(0, type) == initial + 10, "carried minerals still deposited after depletion")
	f.world.free()

func _test_cancel_return(type: Enums.ResourceType) -> void:
	var f := _fixture(type, &"town_center", true)
	var initial: int = f.state.get_resource(0, type)
	for step in 500:
		_step(f)
		if f.state.get_resource(0, type) > initial:
			break
	f.worker.command_stop()
	var before: Vector2 = f.worker.sim_pos
	for step in 20:
		_step(f)
	check(f.worker.order == Enums.OrderType.NONE and f.worker.sim_pos == before, "stop cancels the pending return to mine")
	f.world.free()
