extends RefCounted

const AiProtocolScript := preload("res://scripts/ai_gateway/ai_protocol.gd")
const CommandValidatorScript := preload("res://scripts/ai_gateway/command_validator.gd")
const CommandExecutionContextScript := preload(
	"res://scripts/ai_gateway/command_execution_context.gd"
)
const EntityRegistryScript := preload("res://scripts/ai_gateway/entity_registry.gd")
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const RESOURCE_NODE_SCRIPT := preload("res://scripts/entities/resource_node.gd")
const VILLAGER: UnitDef = preload("res://data/units/villager.tres")
const TEUTONS: CivDef = preload("res://data/civs/teutons.tres")


func run() -> Array[String]:
	var failures: Array[String] = []
	EntityRegistryScript.clear()
	_test_missing_unit_rejected(failures)
	EntityRegistryScript.clear()
	_test_wrong_team_rejected(failures)
	EntityRegistryScript.clear()
	_test_place_building_unaffordable(failures)
	return failures


func _test_missing_unit_rejected(failures: Array[String]) -> void:
	var ctx := _make_context()
	var result := CommandValidatorScript.validate(
		{"op": "gather", "unit_id": 99999, "target_id": 1},
		ctx
	)
	if result.ok:
		failures.append("validator should reject missing unit_id")
	if result.reason != "missing_unit":
		failures.append("missing unit should report missing_unit, got %s" % result.reason)


func _test_wrong_team_rejected(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)
	var entities := Node2D.new()
	root.add_child(entities)

	var villager := UNIT_VIEW.instantiate() as Node2D
	villager.set("team", Enums.Team.PLAYER)
	villager.set("def", VILLAGER)
	villager.set("civ", TEUTONS)
	villager.set("match_state", _make_context().match_state)
	villager.set("sim_pos", Vector2.ZERO)
	entities.add_child(villager)
	_ensure_registered(villager)

	var unit_id := EntityRegistryScript.id_of(villager)
	var ctx := _make_context(entities)
	var result := CommandValidatorScript.validate(
		{"op": "stop", "unit_id": unit_id},
		ctx
	)
	if result.ok:
		failures.append("validator should reject unit on wrong team")
	if result.reason != "unit_wrong_team":
		failures.append("wrong team should report unit_wrong_team, got %s" % result.reason)

	root.free()


func _test_place_building_unaffordable(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)
	var entities := Node2D.new()
	root.add_child(entities)

	var ctx := _make_context(entities)
	ctx.match_state.resources[Enums.Team.AI][Enums.ResourceType.WOOD] = 0

	var result := CommandValidatorScript.validate(
		{
			"op": "place_building",
			"building_def_id": "house",
			"pos": [20.0, 20.0],
		},
		ctx
	)
	if result.ok:
		failures.append("validator should reject place_building when unaffordable")
	if result.reason != "cannot_afford":
		failures.append("unaffordable build should report cannot_afford, got %s" % result.reason)

	root.free()


func _make_context(entities: Node2D = null) -> CommandExecutionContext:
	var ctx := CommandExecutionContextScript.new()
	ctx.match_state = MatchState.new()
	ctx.match_state.setup_defaults()
	ctx.entities = entities
	ctx.team = Enums.Team.AI
	ctx.civ = TEUTONS
	return ctx


func _ensure_registered(entity: Node2D) -> void:
	if entity == null:
		return
	var unit_def := entity.get("def") as UnitDef
	if unit_def != null and float(entity.get("hp")) <= 0.0:
		entity.set("hp", float(unit_def.max_hp))
	if EntityRegistryScript.id_of(entity) < 0:
		EntityRegistryScript.register(entity)
