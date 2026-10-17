extends SceneTree
## Farm lifecycle survives local saves and host snapshots, including version 1 data.

var Saves: GDScript
const Runtime := preload("res://scripts/network/network_match.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")
const MapData := preload("res://scripts/world/map_data.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const BUILDING := preload("res://scenes/entities/building_view.tscn")
const FARM := preload("res://scripts/entities/farm_agent.gd")
const CHINESE := preload("res://data/civs/chinese.tres")
const TEUTONS := preload("res://data/civs/teutons.tres")

class SaveFixture extends Node:
	var match_state: MatchState
	var player_civ: CivDef = CHINESE
	var ai_civ: CivDef = TEUTONS
	var map_data: Dictionary
	var setup_ready := true

var checks := 0
var failures: Array[String] = []
var fixture: Node2D


func _initialize() -> void:
	call_deferred("_run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _state() -> MatchState:
	var state := MatchState.new()
	state.setup_defaults()
	return state


func _farm(parent: Node, state: MatchState, label: String, crops: bool, food: float, complete := true) -> BuildingAgent:
	var farm := BUILDING.instantiate() as BuildingAgent
	farm.set_script(FARM)
	farm.def = Catalog.get_building(&"farm")
	farm.civ = CHINESE
	farm.match_state = state
	farm.name = label
	farm.set_meta("map_id", label)
	farm.sim_pos = Vector2(parent.get_child_count() * 5 + 1, 10)
	farm.amount = food
	farm.farm_has_crops = crops
	if not complete:
		farm.is_complete = false
		farm._construction_started = true
		farm.build_progress = farm.def.build_time * 0.5
	parent.add_child(farm)
	return farm


func _farms(entities: Node) -> Dictionary:
	var result := {}
	for entity in entities.get_children():
		result[String(entity.get_meta("map_id", entity.name))] = entity
	return result


func _check_restored_farms(entities: Node, legacy: bool, label: String) -> void:
	var farms := _farms(entities)
	check(farms.size() == 5, label + " restores all farms")
	check(not farms.fresh.farm_has_crops and farms.fresh._uses_foundation_visual(), label + " untouched completed farm stays bare")
	check(farms.harvested.farm_has_crops and not farms.harvested._uses_foundation_visual(), label + " working farm keeps crops")
	check(not farms.unfinished.farm_has_crops and not farms.unfinished.is_complete and farms.unfinished._uses_foundation_visual(), label + " unfinished farm stays bare even with depleted food")
	check(farms.explicit_bare.farm_has_crops == legacy, label + " explicit false overrides food-based inference")
	check(farms.explicit_crops.farm_has_crops != legacy, label + " explicit true overrides full food amount")


func _save_roundtrip() -> void:
	var world := Node2D.new()
	fixture.add_child(world)
	var entities := Node2D.new()
	entities.name = "Entities"
	world.add_child(entities)
	var boot := SaveFixture.new()
	boot.match_state = _state()
	boot.map_data = MapData.create(80, 80, "Farm lifecycle persistence")
	world.add_child(boot)
	_farm(entities, boot.match_state, "fresh", false, 175.0)
	_farm(entities, boot.match_state, "harvested", true, 100.0)
	_farm(entities, boot.match_state, "unfinished", false, 100.0, false)
	_farm(entities, boot.match_state, "explicit_bare", false, 100.0)
	_farm(entities, boot.match_state, "explicit_crops", true, 175.0)
	var data: Dictionary = JSON.parse_string(JSON.stringify(Saves.capture(boot)))
	check(Saves.validate(data).is_empty(), "serialized farm save validates")
	for record in data.entities:
		check(record.fields.get("farm_has_crops") is bool, "save stores an explicit farm lifecycle flag")
	check(Saves.restore(boot, data).is_empty(), "new farm save restores")
	_check_restored_farms(entities, false, "new save")
	var legacy := data.duplicate(true)
	for record in legacy.entities:
		record.fields.erase("farm_has_crops")
	check(Saves.validate(legacy).is_empty(), "older version 1 farm saves remain valid")
	check(Saves.restore(boot, legacy).is_empty(), "older version 1 farm save restores")
	_check_restored_farms(entities, true, "legacy save")
	var damaged := data.duplicate(true)
	damaged.entities[0].fields.farm_has_crops = 1
	check(not Saves.validate(damaged).is_empty(), "save rejects numeric crop flag")
	damaged.entities[0].fields.farm_has_crops = "true"
	check(not Saves.restore(boot, damaged).is_empty(), "restore rejects string crop flag before replacing entities")
	_check_restored_farms(entities, true, "rejected save")
	world.free()


func _runtime(authority: bool) -> Node:
	var runtime := Runtime.new()
	runtime.entities = Node2D.new()
	fixture.add_child(runtime.entities)
	runtime.match_state = _state()
	runtime._civs = {0: CHINESE, 1: TEUTONS}
	runtime.is_host = authority
	fixture.add_child(runtime)
	runtime.set_process(false)
	return runtime


func _network_roundtrip() -> void:
	var host := _runtime(true)
	var guest := _runtime(false)
	var farms := [
		_farm(host.entities, host.match_state, "fresh", false, 175.0),
		_farm(host.entities, host.match_state, "harvested", true, 100.0),
		_farm(host.entities, host.match_state, "unfinished", false, 100.0, false),
		_farm(host.entities, host.match_state, "explicit_bare", false, 100.0),
		_farm(host.entities, host.match_state, "explicit_crops", true, 175.0),
	]
	var packet: Dictionary = JSON.parse_string(JSON.stringify(host.capture_snapshot()))
	check(guest.apply_snapshot(packet, 1), "new farm snapshot spawns replicas")
	for farm in farms:
		var replica: BuildingAgent = guest._resolve(host.entity_id(farm))
		check(replica != null and replica.farm_has_crops == farm.farm_has_crops, "snapshot preserves farm lifecycle on initial spawn")
		if replica != null: replica.set_meta("map_id", String(farm.name))
	_check_restored_farms(guest.entities, false, "new snapshot")
	farms[0].extract(0.25)
	check(guest.apply_snapshot(JSON.parse_string(JSON.stringify(host.capture_snapshot())), 2), "updated farm snapshot applies")
	check(guest._resolve(host.entity_id(farms[0])).farm_has_crops, "first harvest synchronizes crops on an existing replica")
	var legacy := packet.duplicate(true)
	for record in legacy.entities:
		record.erase("farm_has_crops")
	check(guest.apply_snapshot(legacy, 3), "older host snapshot remains valid")
	_check_restored_farms(guest.entities, true, "legacy snapshot")
	var damaged := packet.duplicate(true)
	damaged.entities[0].farm_has_crops = 1
	check(not guest.apply_snapshot(damaged, 4), "snapshot rejects numeric crop flag atomically")
	_check_restored_farms(guest.entities, true, "rejected snapshot")
	damaged.entities[0].farm_has_crops = "false"
	check(not guest.apply_snapshot(damaged, 4), "snapshot rejects string crop flag")


func _run() -> void:
	# Save service references autoloads; load after SceneTree starts them.
	Saves = load("res://scripts/core/save_game_service.gd")
	if Saves == null or not Saves.can_instantiate():
		push_error("Farm save service did not compile")
		quit(1)
		return
	Registry.clear()
	root.get_node("GameSession").online_active = false
	root.get_node("GameSession").match_ai_mode = "sandbox"
	fixture = Node2D.new()
	root.add_child(fixture)
	_save_roundtrip()
	_network_roundtrip()
	fixture.free()
	Registry.clear()
	print("FARM PERSISTENCE TESTS: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
