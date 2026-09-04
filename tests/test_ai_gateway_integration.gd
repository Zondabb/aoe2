extends RefCounted

const LocalAiServerScript := preload("res://scripts/ai_gateway/local_ai_server.gd")
const AiServiceAdapterScript := preload("res://scripts/ai_gateway/ai_service_adapter.gd")
const AiConfigScript := preload("res://scripts/ai_gateway/ai_config.gd")
const ObservationBuilderScript := preload("res://scripts/ai_gateway/observation_builder.gd")
const CommandExecutorScript := preload("res://scripts/ai_gateway/command_executor.gd")
const CommandExecutionContextScript := preload(
	"res://scripts/ai_gateway/command_execution_context.gd"
)
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const ResourceNodeScript := preload("res://scripts/entities/resource_node.gd")
const TOWN_CENTER: BuildingDef = preload("res://data/buildings/town_center.tres")
const VILLAGER: UnitDef = preload("res://data/units/villager.tres")
const TEUTONS: CivDef = preload("res://data/civs/teutons.tres")


func run() -> Array[String]:
	var failures: Array[String] = []
	_test_local_server_health_route(failures)
	_test_adapter_tick_to_executor_gather(failures)
	return failures


func _test_local_server_health_route(failures: Array[String]) -> void:
	var server := LocalAiServerScript.new()
	var adapter := AiServiceAdapterScript.new()
	server.configure(AiConfigScript.new(), adapter)
	var response := server._handle_http_request("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
	if not response.contains("200"):
		failures.append("LocalAiServer /health should return HTTP 200")
	if not response.contains('"status"') or not response.contains("ok"):
		failures.append("LocalAiServer /health body should contain status ok")
	server.free()


func _test_adapter_tick_to_executor_gather(failures: Array[String]) -> void:
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
			"match_id": "test_match",
			"team": Enums.Team.AI,
			"team_label": "Teutons",
			"tick": 1,
			"time_sec": 0.0,
			"profile_id": "teutons",
			"enemy_team": Enums.Team.PLAYER,
			"observation": observation,
		}
	)
	var commands: Array = response.get("commands", [])
	if commands.is_empty():
		failures.append("adapter tick should return gather/train commands")
		root.free()
		return

	var ctx := CommandExecutionContextScript.new()
	ctx.match_state = state
	ctx.entities = entities
	ctx.team = Enums.Team.AI
	ctx.civ = TEUTONS
	for cmd in commands:
		if cmd is Dictionary:
			CommandExecutorScript.execute(cmd, ctx)
	if villager.get("order") != Enums.OrderType.GATHER:
		failures.append("gateway pipeline should assign villager to gather")
	root.free()


func _ensure_registered(entity: Node2D) -> void:
	const EntityRegistryScript := preload("res://scripts/ai_gateway/entity_registry.gd")
	if entity == null:
		return
	var unit_def := entity.get("def") as UnitDef
	if unit_def != null and float(entity.get("hp")) <= 0.0:
		entity.set("hp", float(unit_def.max_hp))
	if EntityRegistryScript.id_of(entity) < 0:
		EntityRegistryScript.register(entity)
