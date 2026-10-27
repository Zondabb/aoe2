extends SceneTree

const MatchAudio := preload("res://scripts/audio/match_audio.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Runtime := preload("res://scripts/network/network_match.gd")

class AudioRecorder extends Node:
	var events: Array[StringName] = []
	var sources: Array = []
	func source_audible(source: Node) -> bool:
		return source.is_inside_tree() and source.visible and not source.has_meta("hidden_from_audio")
	func play_event(event: StringName, _category: StringName, source: Node = null, _key := "") -> bool:
		if source != null and _category != &"alert" and not source_audible(source): return false
		events.append(event)
		sources.append(source)
		return true

var failures: Array[String] = []
var checks := 0
var fixture: Node2D
var state: MatchState
var observer: Node
var recorder: AudioRecorder


func _initialize() -> void:
	call_deferred("_run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _fixture() -> void:
	if is_instance_valid(fixture): fixture.free()
	fixture = Node2D.new()
	root.add_child(fixture)
	state = MatchState.new()
	state.setup_defaults()
	recorder = AudioRecorder.new()
	fixture.add_child(recorder)
	observer = MatchAudio.new()
	observer.audio_service = recorder
	fixture.add_child(observer)
	observer.set_process(false)


func _unit(id: StringName, team := 0, replica := false) -> UnitAgent:
	var unit := UnitAgent.new()
	unit.def = Catalog.get_unit(id)
	unit.team = team as Enums.Team
	unit.match_state = state
	unit.sim_pos = Vector2(3, 3)
	if replica: unit.set_meta("network_replica", true)
	fixture.add_child(unit)
	unit.set_physics_process(false)
	return unit


func _building(complete := true, team := 0, replica := false) -> BuildingAgent:
	var building := BuildingAgent.new()
	building.def = Catalog.get_building(&"house")
	building.team = team as Enums.Team
	building.match_state = state
	building.sim_pos = Vector2(10, 10)
	building.is_complete = complete
	if replica:
		building.set_meta("network_replica", true)
		building.hp = float(building.def.max_hp)
	fixture.add_child(building)
	building.set_physics_process(false)
	return building


func _clear() -> void:
	recorder.events.clear()
	recorder.sources.clear()
	observer._last_events.clear()


func _run() -> void:
	_fixture()
	var mine := _unit(&"militia")
	var enemy := _unit(&"militia", 1)
	var house := _building()
	observer.setup(fixture, state)
	observer._sample(Time.get_ticks_msec())
	check(recorder.events.is_empty(), "initial army and completed map buildings remain silent")
	mine.audio_cue.emit(&"melee")
	check(recorder.events == [&"melee"], "melee signal reaches presentation audio")
	check(recorder.sources[0] == mine, "world sound retains its source for camera/fog filtering")
	mine.audio_cue.emit(&"melee")
	enemy.audio_cue.emit(&"melee")
	check(recorder.events.size() == 1, "dense same-frame attacks are globally throttled")
	_clear()
	enemy.take_damage(2)
	check(not recorder.events.has(&"attack_warning"), "enemy damage never triggers an owned attack warning")
	mine.take_damage(2)
	mine.take_damage(2)
	check(recorder.events.count(&"attack_warning") == 1, "owned attack warning is emitted once during its cooldown")
	check(recorder.sources[0] == null, "owned attack warning works outside the camera")
	_clear()
	enemy.set_meta("hidden_from_audio", true)
	enemy.audio_cue.emit(&"arrow")
	check(recorder.events.is_empty(), "world cue goes through service visibility filtering")
	enemy.remove_meta("hidden_from_audio")
	enemy._attack_target = mine
	enemy._begin_attack()
	enemy._process_attack_animation(0.3)
	check(recorder.events.has(&"melee"), "real authoritative hit emits melee cue")
	_clear()
	var archer := _unit(&"archer")
	observer._track(weakref(archer))
	archer._attack_target = enemy
	archer._begin_attack()
	archer._process_attack_animation(1.0)
	check(recorder.events.has(&"arrow"), "real projectile release emits arrow cue")
	_clear()
	enemy.take_damage(9999)
	check(recorder.events.has(&"death"), "real lethal unit damage emits death cue")
	_clear()
	var foundation := _building(false)
	observer._track(weakref(foundation))
	foundation.add_build_progress(foundation.def.build_time)
	check(recorder.events == [&"construction_complete"], "owned foundation completion emits completion alert")
	check(recorder.sources[0] == foundation, "construction alert identifies its building for original completion sample")
	_clear()
	house.take_damage(9999)
	check(recorder.events.has(&"building_destroyed") and not recorder.events.has(&"death"), "destroyed building emits collapse instead of human death cue")
	_clear()
	house.unit_trained.emit(mine)
	check(recorder.events == [&"unit_ready"], "production completion emits owned unit ready alert")
	_clear()
	house.unit_trained.emit(enemy)
	check(recorder.events.is_empty(), "enemy production has no owned alert")
	var town_center := BuildingAgent.new()
	town_center.def = load("res://data/buildings/town_center.tres")
	town_center.match_state = state
	town_center.sim_pos = Vector2(20, 20)
	fixture.add_child(town_center)
	town_center.set_physics_process(false)
	observer._track(weakref(town_center))
	state.population_cap[0] = 100
	check(town_center.enqueue_train(load("res://data/units/villager.tres")), "real producer accepts training fixture")
	town_center._physics_process(100.0)
	check(recorder.events == [&"villager_ready"], "real completed villager training uses original villager ready alert")
	_clear()
	state.set_age(1, Enums.Age.FEUDAL)
	check(recorder.events.is_empty(), "enemy age advancement stays silent")
	state.set_age(0, Enums.Age.FEUDAL)
	check(recorder.events == [&"age_up"], "owned age advancement emits original alert")
	_clear()
	state.set_winner(Enums.Team.PLAYER)
	check(recorder.events == [&"victory"], "victory is heard after simulation freezes")
	mine.audio_cue.emit(&"melee")
	check(recorder.events == [&"victory"], "frozen match stops world audio")
	state.frozen = false
	_clear()
	fixture.remove_child(observer)
	mine.audio_cue.emit(&"melee")
	state.age_changed.emit(0, Enums.Age.CASTLE)
	check(recorder.events.is_empty(), "observer exit disconnects entity and match callbacks")
	observer.free()
	_test_work()
	_test_projectiles()
	await _test_replicas()
	_fixture()
	observer.setup(fixture, state)
	state.set_winner(Enums.Team.AI)
	check(recorder.events == [&"defeat"], "opponent winner emits defeat")
	_clear()
	observer.setup(fixture, state)
	check(recorder.events.is_empty(), "loading an already-ended match does not replay result")
	fixture.free()
	print("WORLD AUDIO: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_work() -> void:
	_fixture()
	var worker := _unit(&"villager")
	observer.setup(fixture, state)
	worker.order = Enums.OrderType.GATHER
	worker._gather_state = "gathering"
	worker.carry_type = Enums.ResourceType.WOOD
	observer._sample(10000)
	check(recorder.events.has(&"chop"), "active wood worker emits chopping")
	_clear()
	observer._sample(10100)
	check(recorder.events.is_empty(), "work cadence does not fire on each sample")
	worker.carry_type = Enums.ResourceType.STONE
	observer._sample(11000)
	check(recorder.events.has(&"mine"), "stone worker emits mining")
	_clear()
	worker.carry_type = Enums.ResourceType.FOOD
	observer._sample(12000)
	check(recorder.events.has(&"farm"), "food worker emits farming")
	_clear()
	worker._gather_state = "to_resource"
	observer._sample(13000)
	check(recorder.events.is_empty(), "walking to resource does not emit work sound")
	var foundation := _building(false)
	worker.order = Enums.OrderType.BUILD
	worker._build_target = foundation
	worker.sim_pos = foundation.sim_pos
	observer._sample(14000)
	check(recorder.events.has(&"hammer"), "worker in construction range emits hammering")


func _test_replicas() -> void:
	_fixture()
	var runtime := Runtime.new()
	runtime.is_host = false
	runtime._last_snapshot_sequence = -1
	fixture.add_child(runtime)
	runtime.add_to_group("network_match")
	var replica := _unit(&"archer", 0, true)
	var building := _building(false, 0, true)
	observer.setup(fixture, state)
	replica.hp -= 2
	replica._combat_action = &"attack"
	_unit(&"villager", 0, true)
	runtime._last_snapshot_sequence = 1
	await process_frame
	check(recorder.events.is_empty(), "first snapshot node-added callbacks stay silent after deferred initialization")
	observer._sample(10000)
	check(recorder.events.is_empty(), "first network snapshot establishes a silent health/action baseline")
	replica._combat_action = &""
	observer._sample(10100)
	replica._combat_action = &"attack"
	replica.hp -= 2
	observer._sample(10200)
	check(recorder.events.has(&"arrow"), "network replica attack transition emits arrow cue")
	check(recorder.events.has(&"attack_warning"), "network replica damage emits owned warning")
	_clear()
	building.is_complete = true
	observer._sample(10300)
	check(recorder.events.has(&"construction_complete"), "network construction difference emits owned completion")
	check(recorder.sources[0] == building, "network completion retains its building for sample selection")
	_clear()
	building.hp = 0.0
	observer._sample(10350)
	check(recorder.events.has(&"building_destroyed") and not recorder.events.has(&"death"), "network building death uses collapse sample")
	_clear()
	building.free()
	await process_frame
	check(recorder.events.is_empty(), "sampled building death is not repeated when its replica is removed")
	var removed := _building(true, 0, true)
	observer._track(weakref(removed))
	removed.hp = 0.0
	removed.free()
	await process_frame
	check(recorder.events == [&"building_destroyed"], "confirmed dead replica removed before scan emits collapse")
	_clear()
	var hidden := _building(true, 1, true)
	observer._track(weakref(hidden))
	hidden.set_meta("hidden_from_audio", true)
	hidden.hp = 0.0
	hidden.free()
	await process_frame
	check(recorder.events.is_empty(), "hidden dead replica removal stays silent")
	var alive := _building(true, 1, true)
	observer._track(weakref(alive))
	alive.free()
	await process_frame
	check(recorder.events.is_empty(), "removing live building replica does not invent collapse")
	_clear()
	replica.hp = 0.0
	observer._sample(10400)
	check(recorder.events.has(&"death"), "network replica death transition emits cue")
	_clear()
	var arriving := _unit(&"villager", 0, true)
	await process_frame
	check(recorder.events.has(&"villager_ready"), "owned villager replica spawned after first snapshot emits production alert")
	_clear()
	arriving.free()
	check(recorder.events.is_empty(), "replica removal does not invent death or production")
	state.frozen = false
	var outside := _unit(&"militia", 1)
	observer._track(weakref(outside))
	_clear()
	fixture.queue_free()
	outside.audio_cue.emit(&"melee")
	check(recorder.events.is_empty(), "queued scene removal suppresses world audio immediately")
	await process_frame
	_fixture()
	var teardown_building := _building(true, 0, true)
	observer.setup(fixture, state)
	teardown_building.hp = 0.0
	var teardown_recorder := recorder
	fixture.remove_child(teardown_recorder)
	root.add_child(teardown_recorder)
	fixture.free()
	await process_frame
	check(teardown_recorder.events.is_empty(), "direct scene free does not emit confirmed-dead replica collapse")
	teardown_recorder.free()


func _test_projectiles() -> void:
	_fixture()
	observer.setup(fixture, state)
	var cases := [[&"archer", &"arrow"], [&"mangonel", &"siege_fire_stone"],
		[&"onager", &"siege_fire_onager"], [&"siege_onager", &"siege_fire_onager"],
		[&"trebuchet", &"siege_fire_trebuchet"], [&"bombard_cannon", &"siege_fire_cannon"],
		[&"scorpion", &"siege_fire_bolt"], [&"heavy_scorpion", &"siege_fire_bolt"]]
	for item in cases:
		var unit := _unit(item[0])
		observer._track(weakref(unit))
		_clear()
		unit.audio_cue.emit(&"arrow")
		check(recorder.events == [item[1]], "authoritative %s selects its original firing cue" % item[0])
		var replica := _unit(item[0], 0, true)
		observer._track(weakref(replica))
		_clear()
		replica._combat_action = &"attack"
		observer._sample(10000)
		check(recorder.events == [item[1]], "network %s selects its original firing cue" % item[0])
