extends RefCounted

const LlmResponseParserScript := preload("res://scripts/ai_gateway/llm_response_parser.gd")
const CommandExecutorScript := preload("res://scripts/ai_gateway/command_executor.gd")
const CommandExecutionContextScript := preload(
	"res://scripts/ai_gateway/command_execution_context.gd"
)
const EntityRegistryScript := preload("res://scripts/ai_gateway/entity_registry.gd")
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const ResourceNodeScript := preload("res://scripts/entities/resource_node.gd")
const TOWN_CENTER: BuildingDef = preload("res://data/buildings/town_center.tres")
const VILLAGER: UnitDef = preload("res://data/units/villager.tres")
const TEUTONS: CivDef = preload("res://data/civs/teutons.tres")


func run() -> Array[String]:
	var failures: Array[String] = []
	_test_empty_choices_are_noop(failures)
	_test_mock_completion_executes_gather(failures)
	return failures


func _test_empty_choices_are_noop(failures: Array[String]) -> void:
	var parsed: Array = LlmResponseParserScript.parse({"choices": []}, 3)
	if not parsed.is_empty():
		failures.append("empty choices should parse to no commands")
	var response: Dictionary = LlmResponseParserScript.to_tick_response({}, 1, 3)
	if not (response.get("commands", []) as Array).is_empty():
		failures.append("empty completion should queue no commands")


func _test_mock_completion_executes_gather(failures: Array[String]) -> void:
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

	var completion := {
		"choices": [
			{
				"message": {
					"role": "assistant",
					"tool_calls": [
						{
							"id": "call_1",
							"type": "function",
							"function": {
								"name": "gather",
								"arguments": JSON.stringify(
									{
										"unit_id": EntityRegistryScript.id_of(villager),
										"target_id": EntityRegistryScript.id_of(food),
									}
								),
							},
						}
					],
				}
			}
		]
	}
	var tick_resp: Dictionary = LlmResponseParserScript.to_tick_response(completion, Enums.Team.AI, 2)
	var ctx := CommandExecutionContextScript.new()
	ctx.match_state = state
	ctx.entities = entities
	ctx.team = Enums.Team.AI
	ctx.civ = TEUTONS
	for cmd in tick_resp.get("commands", []):
		if cmd is Dictionary:
			CommandExecutorScript.execute(cmd, ctx)
	if villager.get("order") != Enums.OrderType.GATHER:
		failures.append("v2 mock completion should assign villager to gather")
	root.free()


func _ensure_registered(entity: Node2D) -> void:
	if entity == null:
		return
	var unit_def := entity.get("def") as UnitDef
	if unit_def != null and float(entity.get("hp")) <= 0.0:
		entity.set("hp", float(unit_def.max_hp))
	if EntityRegistryScript.id_of(entity) < 0:
		EntityRegistryScript.register(entity)
