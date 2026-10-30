extends SceneTree

const Fixed := preload("res://scripts/core/sim_fixed.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Support := preload("res://scripts/systems/land_support.gd")
const BUILDING := preload("res://scenes/entities/building_view.tscn")
const UNIT := preload("res://scenes/entities/unit_view.tscn")
var checks := 0
var failures := 0

func _initialize() -> void: call_deferred("_run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(label)

func _run() -> void:
	var world := Node2D.new()
	root.add_child(world)
	var state := MatchState.new()
	state.setup_defaults()
	state.population_cap[0] = 100
	var building: BuildingAgent = BUILDING.instantiate()
	building.def = Catalog.get_building(&"house").duplicate()
	building.def.build_time = 1.0
	building.match_state = state
	world.add_child(building)
	building.set_physics_process(false)
	building.set_process(false)
	building.start_construction()
	for i in 29: building.add_build_time(Fixed.STEP_TIME)
	check(not building.is_complete and building.build_time_elapsed == 29 * Fixed.STEP_TIME, "construction remains unfinished on tick 29")
	building.add_build_time(Fixed.STEP_TIME)
	check(building.is_complete and building.build_time_elapsed == Fixed.TIME_SCALE, "construction completes on tick 30 exactly")
	var start_hp := building.hp_q
	for i in 100: building.take_damage_fixed(1)
	check(building.hp_q == start_hp - 100, "small damage accumulates without discarded HP fractions")
	var chinese: CivDef = load("res://data/civs/chinese.tres")
	building.civ = chinese
	var villager: UnitDef = load("res://data/units/villager.tres")
	check(building._train_duration(villager) == Fixed.time_from_seconds(villager.train_time * chinese.villager_train_time_mul), "civilization duration multiplier keeps exact catalog decimal")
	var age := AgeProgression.new()
	world.add_child(age)
	age.setup(state, world)
	age.set_process(false)
	state.lockstep_enabled = true
	state.lockstep_stepping = true
	age._jobs[0] = {"building": weakref(building), "target_age": 1, "food": 0, "gold": 0, "elapsed_time": 0, "duration_time": 130 * Fixed.TIME_SCALE}
	for i in 3899: age._process(1.0 / 30.0)
	check(state.age_of(0) == 0 and age._jobs[0].elapsed_time == 3899 * Fixed.STEP_TIME, "long research has exact time immediately before completion")
	age._process(1.0 / 30.0)
	check(state.age_of(0) == 1 and age._jobs.is_empty(), "long research completes at the exact 3900th tick")
	var support := Support.new()
	world.add_child(support)
	support.setup(state, world)
	support.set_process(false)
	var monk: UnitAgent = UNIT.instantiate()
	monk.def = Catalog.get_unit(&"monk")
	monk.match_state = state
	world.add_child(monk)
	monk.set_physics_process(false)
	var patient: UnitAgent = UNIT.instantiate()
	patient.def = Catalog.get_unit(&"militia")
	patient.match_state = state
	patient.sim_pos = Vector2(1, 0)
	world.add_child(patient)
	patient.set_physics_process(false)
	patient.hp_q = 10 * Fixed.SCALE
	for i in 120: support._process(1.0 / 30.0)
	check(patient.hp_q == 20 * Fixed.SCALE, "four seconds of monk healing gives exactly ten HP")
	check(support.heal_remainders.get(monk.get_instance_id(), -1) == 0, "fractional heal remainder is conserved across intervals")
	var id := building.get_instance_id()
	support.cooldowns[id] = 0.2
	support.sync_compatibility_state()
	check(support.cooldown_times[id] == 6144, "legacy seconds cooldown imports to integer units")
	support.cooldown_times[id] = 12345
	support.refresh_compatibility_state()
	support.sync_compatibility_state()
	check(support.cooldown_times[id] == 12345, "restored integer cooldown is preserved by compatibility mirror")
	world.free()
	print("INTEGER PROGRESS: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
