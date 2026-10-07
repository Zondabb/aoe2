extends SceneTree

const Fog := preload("res://scripts/systems/fog_of_war_service.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var state := MatchState.new()
	state.setup_defaults()
	state.progression_enabled = true
	var fog := Fog.new()
	fog.setup(-20, 20)
	state.fog = fog
	var vision := VisionService.new()
	vision.setup()
	# Base LOS must match every imported record, including rams, farms and walls.
	for id in GameCatalog.data().units:
		check(GameCatalog.get_unit(id).resolved_vision_radius() == float(GameCatalog.unit_record(id).sight), "%s original base LOS" % id)
	for id in GameCatalog.data().buildings:
		check(GameCatalog.get_building(id).resolved_vision_radius() == float(GameCatalog.building_record(id).sight), "%s original base LOS" % id)
	var scout := UnitAgent.new()
	scout.def = GameCatalog.get_unit(&"scout_cavalry")
	scout.match_state = state
	scout.hp = 100
	scout.sim_pos = Vector2(0.5, 0.5)
	var villager := UnitAgent.new()
	villager.def = GameCatalog.get_unit(&"villager")
	villager.match_state = state
	var enemy := UnitAgent.new()
	enemy.def = scout.def
	enemy.match_state = state
	enemy.team = Enums.Team.AI
	enemy.hp = 100
	enemy.sim_pos = Vector2(5.5, 0.5)
	var outpost := BuildingAgent.new()
	outpost.def = GameCatalog.get_building(&"outpost")
	outpost.match_state = state
	vision.register(scout)
	vision.register(enemy)
	fog.rebuild([scout])
	check(not fog.can_see(0, enemy), "dark-age scout cannot reveal distant enemy")
	check(vision.nearest_hostile(scout, Enums.Team.AI) == null, "dark-age scout cannot acquire distant enemy")
	for age in 4:
		fog.dirty = false
		state.set_age(0, age)
		if age > 0:
			check(fog.dirty, "age advancement invalidates fog immediately")
		var radius := float(4 + age * 2)
		check(scout.resolved_vision_radius() == radius, "existing scout follows team age")
		check(villager.resolved_vision_radius() == 4, "villager retains original 4-tile LOS")
		check(enemy.resolved_vision_radius() == 4, "other team's age is independent")
		check(outpost.resolved_vision_radius() == 6 + age * 2, "outpost age LOS")
		check(fog.radius_of(scout) == radius and vision.vision_radius_of(scout) == radius, "fog and target acquisition share age LOS")
		check(fog.radius_of(outpost) == 6 + age * 2 and vision.vision_radius_of(outpost) == 6 + age * 2, "building fog and vision agree")
		outpost.is_complete = false
		check(outpost.resolved_vision_radius() == 2, "unfinished outpost keeps construction LOS")
		outpost.is_complete = true
		var cavalry := UnitAgent.new()
		cavalry.match_state = state
		cavalry.def = GameCatalog.get_unit(&"light_cavalry")
		cavalry.set_meta("network_replica", true)
		check(cavalry.resolved_vision_radius() == radius, "new/upgraded/replica light cavalry inherits cumulative age LOS")
		cavalry.free()
		fog.rebuild([scout])
		if age > 0:
			check(fog.can_see(0, enemy), "age bonus reveals enemy in expanded LOS")
			check(vision.nearest_hostile(scout, Enums.Team.AI) == enemy, "age bonus permits target acquisition")
	# Repeated snapshots cannot accumulate another bonus.
	state.set_age(0, 3)
	check(scout.resolved_vision_radius() == 10, "repeated age snapshot is idempotent")
	scout.set_vision_radius(3)
	check(scout.resolved_vision_radius() == 3, "explicit scenario override wins")
	scout.vision_radius_override = -1
	state.progression_enabled = false
	check(scout.resolved_vision_radius() == 4 and outpost.resolved_vision_radius() == 6, "legacy scenarios keep authored base LOS")
	vision.clear()
	for entity in [scout, villager, enemy, outpost]:
		entity.free()
	for script in [preload("res://tests/test_vision_service.gd"), preload("res://tests/test_observation_vision.gd")]:
		var errors: Array[String] = script.new().run()
		check(errors.is_empty(), "vision regression: %s" % str(errors))
	print("AGE VISION TESTS: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
