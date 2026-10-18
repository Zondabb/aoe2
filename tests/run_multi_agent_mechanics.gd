extends SceneTree
## Real game mechanisms and observation boundaries required by the v3 planners.

const Catalog := preload("res://scripts/data/game_catalog.gd")
const Observation := preload("res://scripts/ai_gateway/observation_builder.gd")
const Decision := preload("res://scripts/ai_gateway/decision_context_builder.gd")
const Placement := preload("res://scripts/ai_gateway/build_placement.gd")
const Context := preload("res://scripts/ai_gateway/command_execution_context.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Events := preload("res://scripts/ai_gateway/event_buffer.gd")
const Combat := preload("res://scripts/systems/combat_system.gd")
const Collision := preload("res://scripts/systems/collision_resolver.gd")
const ResourceNode := preload("res://scripts/entities/resource_node.gd")
const UNIT := preload("res://scenes/entities/unit_view.tscn")
const BUILDING := preload("res://scenes/entities/building_view.tscn")
const CIV := preload("res://data/civs/chinese.tres")
var checks := 0
var failures: Array[String] = []
var world: Node2D
var state: MatchState

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func _fixture() -> void:
	if is_instance_valid(world): world.free()
	Registry.clear()
	Events.clear()
	Collision.clear_map_bounds()
	world = Node2D.new()
	root.add_child(world)
	state = MatchState.new()
	state.setup_defaults()
	state.map_bounds = Rect2(-80, -80, 160, 160)
	state.population_cap[0] = 100
	state.population_cap[1] = 100
	for team in 2:
		for resource in 4: state.resources[team][resource] = 10000

func _building(id: StringName, at: Vector2, team := 0) -> BuildingAgent:
	var entity := BUILDING.instantiate() as BuildingAgent
	if id == &"farm": entity.set_script(load("res://scripts/entities/farm_agent.gd"))
	entity.def = Catalog.get_building(id)
	entity.team = team
	entity.civ = CIV
	entity.match_state = state
	entity.sim_pos = at
	world.add_child(entity)
	entity.set_physics_process(false)
	return entity

func _unit(id: StringName, at: Vector2, team := 0) -> UnitAgent:
	var entity := UNIT.instantiate() as UnitAgent
	entity.def = Catalog.get_unit(id)
	entity.team = team
	entity.civ = CIV
	entity.match_state = state
	entity.sim_pos = at
	world.add_child(entity)
	entity.set_physics_process(false)
	return entity

func _resource(type: int, at: Vector2) -> Node2D:
	var entity := ResourceNode.new()
	entity.resource_type = type
	entity.sim_pos = at
	entity.amount = 100
	world.add_child(entity)
	return entity

func _ctx() -> CommandExecutionContext:
	var context := Context.new()
	context.match_state = state
	context.entities = world
	context.team = 0
	context.civ = CIV
	return context

func _test_new_town_center_delivery() -> void:
	_fixture()
	var tc := Placement.place_foundation(Catalog.get_building(&"town_center"), Vector2.ZERO, _ctx()) as BuildingAgent
	check(tc != null and not tc.is_complete, "new TC begins as a paid foundation")
	tc.add_build_progress(tc.def.build_time)
	check(not tc.accepts_all_resources, "new TC does not depend on the authored map override")
	for resource in 4:
		check(tc.accepts_resource(resource), "constructed TC accepts resource type %d" % resource)
		var node := _resource(resource, Vector2(10, 0))
		var worker := _unit(&"villager", Vector2(8, 0))
		var initial: int = state.get_resource(0, resource)
		worker.command_gather(node)
		for step in 320: worker._physics_process(0.1)
		check(state.get_resource(0, resource) > initial, "worker actually delivers resource type %d to constructed TC" % resource)
		worker.free()
		node.free()

func _test_farm_replacement() -> void:
	_fixture()
	_building(&"town_center", Vector2.ZERO)
	var worker := _unit(&"villager", Vector2(9, 0))
	var farm := _building(&"farm", Vector2(10, 0))
	farm.amount = 6
	var id := Registry.id_of(farm)
	var food: int = state.get_resource(0, Enums.ResourceType.FOOD)
	worker.command_gather(farm)
	for step in 180: worker._physics_process(0.1)
	check(farm.is_queued_for_deletion() and farm.amount == 0, "depleted farm removes its exhausted footprint")
	check(state.get_resource(0, Enums.ResourceType.FOOD) == food + 6, "last farm yield survives exhaustion and is delivered exactly once")
	check(Events.for_team(Events.drain(), 0, false).any(func(event): return event.get("type") == "resource_depleted" and event.get("entity_id") == id), "farm exhaustion emits an observable resource event")
	check(Placement.can_place_at(farm.def, farm.sim_pos, world), "depleted farm plot is immediately legally reusable")
	var wood: int = state.get_resource(0, Enums.ResourceType.WOOD)
	var replacement := Placement.place_foundation(farm.def, farm.sim_pos, _ctx()) as BuildingAgent
	check(replacement != null and not replacement.is_complete and state.get_resource(0, Enums.ResourceType.WOOD) == wood - farm.def.cost_wood, "replacement is a paid foundation rather than free resource regeneration")
	check(not Placement.can_place_at(farm.def, farm.sim_pos, world), "active replacement prevents duplicate overlapping farms")
	replacement.add_build_progress(replacement.def.build_time)
	worker.command_gather(replacement)
	for step in 220: worker._physics_process(0.1)
	check(replacement.amount < 175 and state.get_resource(0, Enums.ResourceType.FOOD) > food + 6, "replacement farm enters the normal gathering and delivery loop")

func _test_ram_damage() -> void:
	_fixture()
	var tc := _building(&"town_center", Vector2.ZERO, 1)
	var ram := _unit(&"battering_ram", Vector2(5, 0))
	check(ram.def.attack_class_bonuses.get("BUILDINGS_NO_PORT") == 125, "ram bonus is imported from original source_attacks")
	var initial := tc.hp
	var damage := Combat.apply_hit(ram.def, tc, {"attacker": ram})
	check(is_equal_approx(damage, 125.5) and is_equal_approx(initial - tc.hp, 125.5), "ram deals the game's 0.5 minimum base damage plus the exact 125 source building bonus")
	var worker := _unit(&"villager", Vector2(8, 0), 1)
	var worker_damage := Combat.apply_hit(ram.def, worker)
	check(worker_damage <= 2, "building bonus does not apply to ordinary villagers")
	ram.command_attack(tc)
	for step in 1500:
		if state.winner >= 0: break
		ram._physics_process(0.1)
	check(tc.hp == 0 and state.winner == 0, "actual ram attack cycles destroy TC and produce the game's victory event")
	for id in [&"capped_ram", &"siege_ram"]:
		check(Catalog.get_unit(id).attack_class_bonuses == Catalog.unit_record(id).source_attacks, "%s retains its own source damage classes" % id)

func _test_production_progress_and_exit() -> void:
	_fixture()
	var barracks := _building(&"barracks", Vector2.ZERO)
	var soldier := Catalog.get_unit(&"militia")
	# Non-progression matches use definitions authored on the building.
	barracks.def = barracks.def.duplicate()
	barracks.def.trainable.assign([soldier])
	check(barracks.enqueue_train(soldier), "producer admits the paid unit")
	var queue_id := barracks.train_queue_ids[0]
	state.population_cap[0] = 0
	barracks._physics_process(2)
	check(barracks.production_status().state == "population_blocked" and barracks.train_progress == 0, "population stalls are distinct from successful queue admission")
	state.population_cap[0] = 100
	barracks._physics_process(2)
	check(barracks.production_status().state == "training" and barracks.production_status().elapsed == 2, "production exposes real elapsed progress")
	state.map_bounds = Rect2(-1.6, -1.6, 3.2, 3.2)
	barracks._physics_process(100)
	check(barracks.production_status().state == "exit_blocked" and barracks.production_status().active_queue_id == queue_id, "blocked exits retain the completed queue item and expose the cause")
	check(state.population_reserved[0] == soldier.population and state.population[0] == 0, "blocked exits preserve the reservation without phantom units")
	state.map_bounds = Rect2(-80, -80, 160, 160)
	barracks._physics_process(0.3)
	check(barracks.production_status().state == "idle" and barracks.train_queue.is_empty(), "opening an exit completes the same unit without a second payment")
	check(state.population_reserved[0] == 0 and state.population[0] == soldier.population, "spawn transfers population exactly once")
	var born: UnitAgent
	for entity in world.get_children():
		if entity is UnitAgent: born = entity
	check(born != null and born.hp > 0, "production spawned an initialized real unit")
	var produced_events := Events.drain()
	var spawn_events: Array = Events.for_team(produced_events, 0, false).filter(func(event): return event.get("type") == "entity_spawned" and event.get("entity", {}).get("kind") == "unit")
	check(spawn_events.size() == 1 and spawn_events[0].entity.hp > 0, "spawn event no longer publishes uninitialized zero HP")
	var completion_events: Array = Events.for_team(produced_events, 0, false).filter(func(event): return event.get("type") == "train_completed")
	check(completion_events.size() == 1 and completion_events[0].queue_id == queue_id and completion_events[0].created_entity_id == Registry.id_of(born), "training completion connects its stable queue item with the real spawned entity")
	check(Events.for_team(produced_events, 1, false).all(func(event): return event.get("type") != "train_completed"), "enemy cannot read private training completion lineage")

func _test_observation_and_layout() -> void:
	_fixture()
	var tc := _building(&"town_center", Vector2(-30, -30))
	var worker := _unit(&"villager", Vector2(-25, -25))
	var forest := _resource(Enums.ResourceType.WOOD, Vector2(8, -20))
	var enemy := _building(&"barracks", Vector2(30, 30), 1)
	var enemy_unit := _unit(&"militia", Vector2(35, 30), 1)
	enemy_unit.command_move(Vector2(60, 60))
	var observation := Observation.build_json_safe(state, world, 0, 1, 1)
	check(observation.capabilities.farm_depletion_frees_plot and observation.capabilities.gate_control and observation.capabilities.wall_segments, "capabilities expose wall lines and gate controls")
	check(observation.victory_conditions.type == "destroy_any_enemy_town_center", "planner receives the actual current win condition")
	var own: Dictionary = observation.entities.filter(func(entity): return entity.id == Registry.id_of(tc))[0]
	check(own.production.state == "idle" and own.drop_off_resources.size() == 4, "own production and all TC drop-off types are observable")
	var visible_enemy: Dictionary = observation.entities.filter(func(entity): return entity.id == Registry.id_of(enemy))[0]
	check(not visible_enemy.has("production") and not visible_enemy.has("research") and not visible_enemy.has("train_queue"), "enemy queue, production and research remain private")
	var visible_unit: Dictionary = observation.entities.filter(func(entity): return entity.id == Registry.id_of(enemy_unit))[0]
	check(not visible_unit.has("movement") and not visible_unit.has("move_goal"), "enemy movement plans remain private")
	var options: Array = observation.decision_context.construction_options
	var military: Array = options.filter(func(item): return item.building_def_id == "barracks")
	check(not military.is_empty(), "base has reachable military-zone construction alternatives")
	for option in military:
		var at := Vector2(option.pos[0], option.pos[1])
		check(option.zone == "military" and at.distance_to(tc.sim_pos) >= Decision.FARM_RESERVE_RADIUS, "military sites preserve TC farmland")
		check(option.planning_footprint == [12.0, 12.0], "planning artwork footprint is distinct from the legal 3 by 3 footprint")
		check(Placement.can_place_at(Catalog.get_building(&"barracks"), at, world), "planned site passes real footprint validation")
	var farms: Array = options.filter(func(item): return item.building_def_id == "farm")
	check(not farms.is_empty(), "TC-adjacent farm plots remain available")
	var camps: Array = options.filter(func(item): return item.building_def_id == "lumber_camp")
	check(not camps.is_empty() and camps.all(func(item): return item.resource_target_id == Registry.id_of(forest)), "lumber camp sites use visible resource anchors")
	for option in options:
		var at := Vector2(option.pos[0], option.pos[1])
		if at.distance_to(tc.sim_pos) < 42:
			check(absf(at.x - tc.sim_pos.x) > 1.5 and absf(at.y - tc.sim_pos.y) > 1.5, "layout keeps cross-base transport lanes")
	check(worker.hp > 0, "layout planning never mutates workers")

func _test_secondary_farm_district() -> void:
	_fixture()
	# Reproduce the crowded two-farm layout from the finite-resource match,
	# translated by (-100, -100). Secondary plots must use current own sight.
	state.fog_enabled = true
	state.fog = FogOfWarService.new()
	state.fog.setup_rect(state.map_bounds.position, state.map_bounds.end, 1.0)
	var tc := _building(&"town_center", Vector2(20, 20))
	var mill := _building(&"mill", Vector2(0, -12))
	for spec in [["barracks", -5, 3], ["house", 42, 34], ["house", 6, 42],
		["house", 37, 45], ["barracks", -23, 11], ["farm", 32, 2],
		["house", 26, 49], ["farm", -10, 40]]:
		_building(StringName(spec[0]), Vector2(spec[1], spec[2]))
	_unit(&"villager", Vector2(3, -9))
	var enemy_mill := _building(&"mill", Vector2(-65, -65), 1)
	var mill_based := 0
	for iteration in 4:
		state.fog.rebuild(world.get_children())
		var observation := Observation.build_json_safe(state, world, 0, 1, iteration)
		var farms: Array = observation.decision_context.construction_options.filter(func(item): return item.building_def_id == "farm")
		check(not farms.is_empty(), "crowded base still supplies farm plot %d" % iteration)
		if farms.is_empty(): break
		check(farms.size() <= Decision.POSITIONS_PER_BUILDING, "secondary farm districts keep the output candidate limit")
		var option: Dictionary = farms[0]
		if option.drop_off_id == Registry.id_of(mill): mill_based += 1
		check(option.drop_off_id in [Registry.id_of(tc), Registry.id_of(mill)], "farm district uses a completed own food drop-off")
		var pos := Vector2(option.pos[0], option.pos[1])
		check(state.fog.footprint_visible(0, pos, Catalog.get_building(&"farm").footprint, true), "secondary farm footprint remains fully visible")
		var foundation := Placement.place_foundation(Catalog.get_building(&"farm"), pos, _ctx()) as BuildingAgent
		check(foundation != null, "secondary farm passes real placement and spends resources")
		if foundation != null: foundation.add_build_progress(foundation.def.build_time)
	check(mill_based >= 1, "completed mill supplies secondary farm anchors after TC rings become crowded")
	state.fog.rebuild(world.get_children())
	var before: Array = Observation.build_json_safe(state, world, 0, 1, 5).decision_context.construction_options
	enemy_mill.sim_pos = Vector2(-60, -70)
	var after: Array = Observation.build_json_safe(state, world, 0, 1, 5).decision_context.construction_options
	check(JSON.stringify(before) == JSON.stringify(after), "moving an unseen enemy mill changes no farm district or candidate")

func _test_projectiles_are_not_observers() -> void:
	_fixture()
	state.fog_enabled = true
	state.fog = FogOfWarService.new()
	state.fog.setup_rect(state.map_bounds.position, state.map_bounds.end, 1.0)
	var tc := _building(&"town_center", Vector2(-20, -20))
	var shooter := _unit(&"mangonel", Vector2(-15, -20))
	var removed := _unit(&"villager", Vector2(50, 50))
	removed.queue_free()
	state.fog.rebuild(world.get_children())
	var before := Observation.build_json_safe(state, world, 0, 1, 10)
	var shot := load("res://scenes/entities/projectile_view.tscn").instantiate() as ProjectileAgent
	world.add_child(shot)
	shot.setup(shooter.sim_pos, Vector2(10, -20), shooter.def, 0, shooter)
	shot.set_physics_process(false)
	var observers := Observation._team_observers(world, 0)
	check(observers.size() == 2 and tc in observers and shooter in observers, "only living unit/building actors supply observer properties")
	check(shot not in observers and removed not in observers, "same-team real projectile and queued actors are excluded before health reads")
	var after := Observation.build_json_safe(state, world, 0, 1, 10)
	check(JSON.stringify(before) == JSON.stringify(after), "a flying own projectile cannot break or change the authoritative team observation")

func _run() -> void:
	UnitDebugFocus.set_spectator_mode(true)
	_test_new_town_center_delivery()
	_test_farm_replacement()
	_test_ram_damage()
	_test_production_progress_and_exit()
	_test_observation_and_layout()
	_test_secondary_farm_district()
	_test_projectiles_are_not_observers()
	world.free()
	print("MULTI AGENT MECHANICS: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
