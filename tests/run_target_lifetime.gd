extends SceneTree

const Access := preload("res://scripts/systems/fog_access.gd")
const Fog := preload("res://scripts/systems/fog_of_war_service.gd")
const UnitScene := preload("res://scenes/entities/unit_view.tscn")
const BuildingScene := preload("res://scenes/entities/building_view.tscn")
const ResourceScript := preload("res://scripts/entities/resource_node.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)

func _run() -> void:
	for fog_enabled in [false, true]:
		for building_target in [false, true]:
			for deferred_removal in [false, true]:
				await _test_removed_attack_target(fog_enabled, building_target, deferred_removal)
		_test_queued_attack_target(fog_enabled)
		for gathering in [false, true]:
			_test_removed_resource(fog_enabled, gathering)
		_test_return_to_removed_resource(fog_enabled)
	_test_hidden_target()
	_test_visibility_guards()
	check(checks == 69, "all lifetime scenarios must finish")
	print("TARGET LIFETIME: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _state(enabled: bool) -> MatchState:
	var state := MatchState.new()
	state.setup_defaults()
	state.fog_enabled = enabled
	state.fog = Fog.new()
	state.fog.setup(-30, 30)
	return state

func _world() -> Node2D:
	var world := Node2D.new()
	root.add_child(world)
	return world

func _unit(world: Node, state: MatchState, team: int, pos: Vector2) -> UnitAgent:
	var unit := UnitScene.instantiate() as UnitAgent
	unit.def = load("res://data/units/villager.tres")
	unit.team = team
	unit.match_state = state
	unit.sim_pos = pos
	world.add_child(unit)
	unit.set_physics_process(false)
	return unit

func _building(world: Node, state: MatchState, team: int) -> Node2D:
	var building := BuildingScene.instantiate() as Node2D
	building.def = load("res://data/buildings/town_center.tres")
	building.team = team
	building.match_state = state
	building.accepts_all_resources = true
	building.sim_pos = Vector2(4, 0.5)
	world.add_child(building)
	building.set_physics_process(false)
	return building

func _test_removed_attack_target(enabled: bool, building_target: bool, deferred_removal: bool) -> void:
	var world := _world()
	var state := _state(enabled)
	var attacker := _unit(world, state, 0, Vector2(0.5, 0.5))
	var target: Node2D = _building(world, state, 1) if building_target else _unit(world, state, 1, Vector2(4, 0.5))
	state.fog.rebuild(world.get_children())
	attacker.command_attack(target)
	check(attacker.order == Enums.OrderType.ATTACK, "visible target accepts attack before removal")
	attacker._begin_attack()
	if deferred_removal:
		target.queue_free()
		await process_frame
	else:
		target.free()
	check(not is_instance_valid(target), "test must release target before attack tick")
	attacker._physics_process(0.1)
	check(attacker.order == Enums.OrderType.NONE, "freed target ends attack with fog=%s" % enabled)
	check(attacker.get("_attack_target") == null, "freed target reference is cleared")
	check(attacker.get("_combat_action") == &"", "freed target cancels attack animation")
	world.free()

func _test_queued_attack_target(enabled: bool) -> void:
	var world := _world()
	var state := _state(enabled)
	var attacker := _unit(world, state, 0, Vector2(0.5, 0.5))
	var target := _unit(world, state, 1, Vector2(4, 0.5))
	state.fog.rebuild(world.get_children())
	attacker.command_attack(target)
	target.queue_free()
	attacker._physics_process(0.1)
	check(attacker.order == Enums.OrderType.NONE, "queued target ends attack before deletion flush")
	check(attacker.get("_attack_target") == null, "queued target reference is cleared")
	world.free()

func _resource(world: Node) -> Node2D:
	var resource := ResourceScript.new()
	resource.sim_pos = Vector2(2, 0.5)
	world.add_child(resource)
	return resource

func _test_removed_resource(enabled: bool, gathering: bool) -> void:
	var world := _world()
	var state := _state(enabled)
	var worker := _unit(world, state, 0, Vector2(0.5, 0.5))
	var resource := _resource(world)
	state.fog.rebuild(world.get_children())
	worker.command_gather(resource)
	check(worker.order == Enums.OrderType.GATHER, "visible resource accepts gather before removal")
	if gathering:
		worker.set("_gather_state", "gathering")
	resource.free()
	worker._physics_process(0.1)
	check(worker.order == Enums.OrderType.NONE, "removed resource ends empty-handed gathering")
	check(worker.get("_gather_target") == null, "removed gather target reference is cleared")
	world.free()

func _test_return_to_removed_resource(enabled: bool) -> void:
	var world := _world()
	var state := _state(enabled)
	var worker := _unit(world, state, 0, Vector2(0.5, 0.5))
	var resource := _resource(world)
	var drop_off := _building(world, state, 0)
	state.fog.rebuild(world.get_children())
	worker.command_gather(resource)
	worker.carry_type = Enums.ResourceType.FOOD
	worker.carry_amount = 5
	worker._begin_drop_off()
	check(worker.get("_drop_off_target") == drop_off, "carrying worker selects drop-off")
	resource.free()
	worker._physics_process(0.1)
	check(worker.carry_amount == 0, "removed source must not prevent depositing carried resources")
	check(worker.order == Enums.OrderType.NONE, "deposit must not resume gathering a freed source")
	world.free()

func _test_hidden_target() -> void:
	var world := _world()
	var state := _state(true)
	var attacker := _unit(world, state, 0, Vector2(0.5, 0.5))
	var target := _unit(world, state, 1, Vector2(4, 0.5))
	state.fog.rebuild(world.get_children())
	attacker.command_attack(target)
	target.sim_pos = Vector2(25, 25)
	state.fog.rebuild(world.get_children())
	attacker._physics_process(0.1)
	check(attacker.order == Enums.OrderType.MOVE, "living hidden enemy still triggers last-seen pursuit")
	check(attacker.get("_attack_target") == null, "last-seen pursuit drops the live enemy reference")
	check(attacker.get("_move_target") == Vector2(4, 0.5), "pursuit cannot learn hidden position")
	world.free()

func _test_visibility_guards() -> void:
	var world := _world()
	var state := _state(true)
	var observer := _unit(world, state, 0, Vector2(0.5, 0.5))
	var target: Variant = Node2D.new()
	target.free()
	check(not Access.can_see(observer, target), "visibility helper rejects freed references at its boundary")
	check(not Access.state_can_see(state, 0, target), "state visibility helper rejects freed references")
	check(not Access.can_see(observer, null), "visibility helper rejects null")
	check(not Access.state_can_see(state, 0, null), "state visibility helper rejects null")
	world.free()
