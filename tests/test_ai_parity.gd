extends RefCounted

const AiServiceAdapterScript := preload("res://scripts/ai_gateway/ai_service_adapter.gd")
const ObservationBuilderScript := preload("res://scripts/ai_gateway/observation_builder.gd")
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const ResourceNodeScript := preload("res://scripts/entities/resource_node.gd")
const TOWN_CENTER: BuildingDef = preload("res://data/buildings/town_center.tres")
const VILLAGER: UnitDef = preload("res://data/units/villager.tres")
const TEUTONS: CivDef = preload("res://data/civs/teutons.tres")


func run() -> Array[String]:
	var failures: Array[String] = []
	_test_adapter_opening_matches_python_ops(failures)
	return failures


func _test_adapter_opening_matches_python_ops(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)
	var entities := Node2D.new()
	root.add_child(entities)
	var state := MatchState.new()
	state.setup_defaults()
	state.register_pop(Enums.Team.AI, 0, 20)

	var town_center := BUILDING_VIEW.instantiate() as Node2D
	town_center.set("team", Enums.Team.AI)
	town_center.set("def", TOWN_CENTER)
	town_center.set("civ", TEUTONS)
	town_center.set("match_state", state)
	town_center.set("accepts_all_resources", true)
	town_center.set("sim_pos", Vector2(40.0, 40.0))
	entities.add_child(town_center)
	_ensure_registered(town_center)

	var villager := UNIT_VIEW.instantiate() as Node2D
	villager.set("team", Enums.Team.AI)
	villager.set("def", VILLAGER)
	villager.set("civ", TEUTONS)
	villager.set("match_state", state)
	villager.set("sim_pos", Vector2(42.0, 40.0))
	entities.add_child(villager)
	_ensure_registered(villager)

	var food := ResourceNodeScript.new()
	food.resource_type = Enums.ResourceType.FOOD
	food.amount = 200.0
	food.sim_pos = Vector2(55.0, 50.0)
	entities.add_child(food)
	_ensure_registered(food)

	var adapter := AiServiceAdapterScript.new()
	adapter.configure(state, entities)
	var observation := ObservationBuilderScript.build(
		state, entities, Enums.Team.AI, Enums.Team.PLAYER, 0.0
	)
	var response := adapter.handle_tick(
		{
			"match_id": "parity_opening",
			"team": Enums.Team.AI,
			"team_label": "Teutons",
			"tick": 0,
			"time_sec": 0.0,
			"profile_id": "teutons",
			"enemy_team": Enums.Team.PLAYER,
			"observation": observation,
		}
	)
	var ops := {}
	for cmd in response.get("commands", []):
		if cmd is Dictionary:
			ops[String(cmd.get("op", ""))] = true
	if not ops.has("gather"):
		failures.append("adapter parity: expected gather in opening tick")
	if not ops.has("train"):
		failures.append("adapter parity: expected train in opening tick")
	tree.root.remove_child(root)
	root.free()


func _ensure_registered(entity: Node2D) -> void:
	if entity.has_method("_ensure_registered"):
		entity.call("_ensure_registered")
	elif entity.has_method("_ready"):
		entity.call("_ready")
