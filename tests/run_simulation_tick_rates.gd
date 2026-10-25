extends SceneTree
## Exercise real production, work orders and combat at the simulation deltas
## used by 60/30 real-time physics ticks at normal and 2x game speed.
const UNIT := preload("res://scenes/entities/unit_view.tscn")
const BUILDING := preload("res://scenes/entities/building_view.tscn")
const PROJECTILE := preload("res://scenes/entities/projectile_view.tscn")
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Collision := preload("res://scripts/systems/collision_resolver.gd")
const SWORDSMAN := preload("res://data/units/swordsman.tres")
const ARCHER := preload("res://data/units/archer.tres")
const VILLAGER := preload("res://data/units/villager.tres")
var checks := 0
var failures: Array[String] = []
var metrics: Array[Dictionary] = []
var world: Node2D
var state: MatchState

func _initialize() -> void: call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func _fixture() -> void:
	if is_instance_valid(world): world.free()
	Registry.clear()
	Collision.clear_map_bounds()
	world = Node2D.new()
	root.add_child(world)
	state = MatchState.new()
	state.setup_defaults()
	state.fog_enabled = false
	state.population_cap[0] = 100
	state.population_cap[1] = 100
	for team in 2:
		for resource in 4: state.resources[team][resource] = 10000

func _unit(definition: UnitDef, at: Vector2, team := 0) -> UnitAgent:
	var unit := UNIT.instantiate() as UnitAgent
	unit.def = definition
	unit.team = team
	unit.match_state = state
	unit.sim_pos = at
	world.add_child(unit)
	unit.set_physics_process(false)
	return unit

func _building(definition: BuildingDef, at: Vector2) -> BuildingAgent:
	var building := BUILDING.instantiate() as BuildingAgent
	building.def = definition
	building.match_state = state
	building.sim_pos = at
	world.add_child(building)
	building.set_process(false)
	building.set_physics_process(false)
	return building

func _target(at: Vector2) -> UnitAgent:
	var definition := SWORDSMAN.duplicate() as UnitDef
	definition.max_hp = 10000
	definition.melee_armor = 0
	definition.pierce_armor = 0
	var target := _unit(definition, at, 1)
	# Keep this dummy occupied so it cannot issue a retaliation order. Only the
	# actual attacking unit is advanced, as in the existing combat fixtures.
	target.order = Enums.OrderType.MOVE
	return target

func _run() -> void:
	UnitDebugFocus.set_spectator_mode(true)
	for delta in [1.0 / 60.0, 1.0 / 30.0, 1.0 / 15.0]:
		var result := {"delta": delta}
		result.production = _production(delta)
		result.gathering = _gathering(delta)
		result.build_completion = _construction(delta)
		result.melee = _combat(delta, SWORDSMAN)
		result.ranged = _combat(delta, ARCHER)
		for definition in [ARCHER, Catalog.get_unit(&"mangonel")]:
			_projectile(delta, definition, false)
			_projectile(delta, definition, true)
		metrics.append(result)
		print("TICK RATE METRIC ", JSON.stringify(result))
	for result in metrics.slice(1):
		check(absi(int(result.melee.hits) - int(metrics[0].melee.hits)) <= 1, "dt %.5f: melee damage over the same 12 simulated seconds stays within one hit of 60Hz" % result.delta)
		check(absi(int(result.ranged.shots) - int(metrics[0].ranged.shots)) <= 1, "dt %.5f: ranged fire rate over the same 12 simulated seconds stays within one shot of 60Hz" % result.delta)
		check(absf(float(result.gathering.delivered) - float(metrics[0].gathering.delivered)) <= float(result.gathering.capacity), "dt %.5f: delivered gathering stock stays within one worker load of 60Hz" % result.delta)
	if is_instance_valid(world): world.free()
	print("SIMULATION TICK RATES: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _production(delta: float) -> Dictionary:
	_fixture()
	var definition := Catalog.get_building(&"town_center").duplicate() as BuildingDef
	var worker := VILLAGER.duplicate() as UnitDef
	worker.train_time = 0.35
	definition.trainable.assign([worker])
	var building := _building(definition, Vector2.ZERO)
	var food := state.get_resource(0, Enums.ResourceType.FOOD)
	for item in 3: check(building.enqueue_train(worker), "dt %.5f: queue admits item %d" % [delta, item])
	var elapsed := 0.0
	# Three 0.35-second items must finish before 1.2 seconds. Dropping the
	# remainder after every completion would take 1.2 seconds at delta=1/15.
	for frame in roundi(1.1 / delta):
		building._physics_process(delta)
		elapsed += delta
	var units := world.get_children().filter(func(node): return node is UnitAgent)
	check(units.size() == 3 and building.train_queue.is_empty(), "dt %.5f: three queued units finish without lost tick remainder or duplicate births" % delta)
	check(state.population[0] == 3 and state.population_reserved[0] == 0, "dt %.5f: queued population transfers exactly once" % delta)
	check(state.get_resource(0, Enums.ResourceType.FOOD) == food - worker.cost_food * 3, "dt %.5f: production charges each item exactly once" % delta)
	check(not building.is_physics_processing(), "dt %.5f: an empty queue stops production processing" % delta)
	return {"births": units.size(), "population": state.population[0], "elapsed": elapsed}

func _gathering(delta: float) -> Dictionary:
	_fixture()
	_building(Catalog.get_building(&"town_center"), Vector2(-8, 0))
	var resource := ResourceNode.new()
	resource.resource_type = Enums.ResourceType.FOOD
	resource.amount = 100.0
	resource.sim_pos = Vector2(1, 0)
	world.add_child(resource)
	var worker := _unit(VILLAGER, Vector2.ZERO)
	var nav := NavServiceHolder.new()
	nav.setup(-32, 32)
	world.add_child(nav)
	nav.set_process(false)
	nav.rebuild_from_scene()
	var food := state.get_resource(0, Enums.ResourceType.FOOD)
	worker.command_gather(resource)
	var capacity_respected := true
	for frame in roundi(24.0 / delta):
		nav._process(delta)
		worker._physics_process(delta)
		capacity_respected = capacity_respected and worker.carry_amount >= -0.0001 and worker.carry_amount <= worker.carry_capacity + 0.0001 and resource.amount >= -0.0001
	var delivered := state.get_resource(0, Enums.ResourceType.FOOD) - food
	var extracted := 100.0 - resource.amount
	check(delivered >= 20, "dt %.5f: real gather/deliver orders complete multiple delivery cycles" % delta)
	check(capacity_respected, "dt %.5f: gathering never exceeds carry capacity or resource stock" % delta)
	check(absf(extracted - delivered - worker.carry_amount) < 0.001, "dt %.5f: all extracted resource is either carried or delivered" % delta)
	return {"delivered": delivered, "carried": worker.carry_amount, "remaining": resource.amount, "capacity": worker.carry_capacity}

func _construction(delta: float) -> float:
	_fixture()
	var definition := Catalog.get_building(&"house").duplicate() as BuildingDef
	definition.build_time = 1.1
	var building := _building(definition, Vector2(5, 0))
	building.start_construction()
	var completed := [0]
	building.construction_completed.connect(func(_building): completed[0] += 1)
	var worker := _unit(VILLAGER, Vector2(2, 0))
	worker.command_build(building)
	var elapsed := 0.0
	for frame in ceili(2.0 / delta):
		worker._physics_process(delta)
		elapsed += delta
		if building.is_complete: break
	check(building.is_complete and completed[0] == 1, "dt %.5f: actual builder completes a foundation exactly once" % delta)
	check(elapsed >= definition.build_time - 0.00001 and elapsed <= definition.build_time + delta + 0.00001, "dt %.5f: construction completion stays within one tick of its defined duration" % delta)
	for frame in 5: worker._physics_process(delta)
	check(completed[0] == 1 and worker.order == Enums.OrderType.NONE, "dt %.5f: builder releases the finished order without duplicate completion" % delta)
	return elapsed

func _combat(delta: float, weapon: UnitDef) -> Dictionary:
	_fixture()
	var ranged := weapon.is_ranged
	var attacker := _unit(weapon, Vector2.ZERO)
	var target := _target(Vector2(12, 0) if ranged else Vector2(2.7, 0))
	var initial_hp := target.hp
	attacker.command_attack(target)
	var hits := 0
	var shots := {}
	var previous_hp := target.hp
	var valid_hits := true
	for frame in roundi(12.0 / delta):
		attacker._physics_process(delta)
		for node in world.get_children():
			if node is ProjectileAgent and not node.is_queued_for_deletion():
				shots[node.get_instance_id()] = true
				node._physics_process(delta)
		if target.hp != previous_hp:
			hits += 1
			valid_hits = valid_hits and is_equal_approx(previous_hp - target.hp, float(weapon.attack))
			previous_hp = target.hp
	check(hits >= 3 and valid_hits, "dt %.5f %s: repeated real attacks deal one armored hit at a time" % [delta, weapon.id])
	check(ranged == not shots.is_empty(), "dt %.5f %s: ranged damage uses projectiles and melee does not" % [delta, weapon.id])
	check(is_equal_approx(initial_hp - target.hp, hits * float(weapon.attack)), "dt %.5f %s: total damage matches observed single hits" % [delta, weapon.id])
	var count_before_death := shots.size()
	target.take_damage(target.hp)
	for frame in 8: attacker._physics_process(delta)
	check(attacker.order == Enums.OrderType.NONE and world.get_children().filter(func(node): return node is ProjectileAgent).size() == count_before_death, "dt %.5f %s: a dead target ends the order without an extra projectile" % [delta, weapon.id])
	return {"hits": hits, "shots": shots.size(), "damage": initial_hp - previous_hp}

func _projectile(delta: float, weapon: UnitDef, dodge: bool) -> void:
	_fixture()
	var target := _target(Vector2(12, 0))
	var initial_hp := target.hp
	var shot := PROJECTILE.instantiate() as ProjectileAgent
	world.add_child(shot)
	shot.setup(Vector2.ZERO, target.sim_pos, weapon, 0)
	shot.set_physics_process(false)
	if dodge: target.sim_pos += Vector2(0, 12)
	var elapsed := 0.0
	for frame in ceili(3.0 / delta):
		shot._physics_process(delta)
		elapsed += delta
		if shot._consumed: break
	var flight_time := 12.0 / weapon.projectile_speed
	check(shot._consumed and shot.sim_pos.is_equal_approx(Vector2(12, 0)), "dt %.5f %s: projectile reaches its original aim without tunnelling or homing" % [delta, weapon.id])
	check(elapsed >= flight_time - 0.00001 and elapsed <= flight_time + delta + 0.00001, "dt %.5f %s: flight duration stays within one tick of distance/speed" % [delta, weapon.id])
	check(is_equal_approx(target.hp, initial_hp if dodge else initial_hp - weapon.attack), "dt %.5f %s: moving off the aim point avoids damage; a stationary direct hit damages once" % [delta, weapon.id])
	var hp_after_impact := target.hp
	for frame in 4: shot._physics_process(delta)
	check(target.hp == hp_after_impact, "dt %.5f %s: impact cannot damage the victim twice" % [delta, weapon.id])
