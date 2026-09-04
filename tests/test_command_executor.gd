extends RefCounted

const AiProtocolScript := preload("res://scripts/ai_gateway/ai_protocol.gd")
const CommandExecutorScript := preload("res://scripts/ai_gateway/command_executor.gd")
const CommandExecutionContextScript := preload(
	"res://scripts/ai_gateway/command_execution_context.gd"
)
const EntityRegistryScript := preload("res://scripts/ai_gateway/entity_registry.gd")
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const RESOURCE_NODE_SCRIPT := preload("res://scripts/entities/resource_node.gd")
const VILLAGER: UnitDef = preload("res://data/units/villager.tres")
const SWORDSMAN: UnitDef = preload("res://data/units/swordsman.tres")
const TEUTONS: CivDef = preload("res://data/civs/teutons.tres")


func run() -> Array[String]:
	var failures: Array[String] = []
	EntityRegistryScript.clear()
	_test_gather_sets_order(failures)
	EntityRegistryScript.clear()
	_test_attack_sets_order(failures)
	EntityRegistryScript.clear()
	_test_duplicate_command_id_skipped(failures)
	return failures


func _test_gather_sets_order(failures: Array[String]) -> void:
	var setup := _make_ai_villager_and_food()
	var villager: Node2D = setup.villager
	var resource: Node2D = setup.resource
	var ctx: CommandExecutionContext = setup.ctx

	var result := CommandExecutorScript.execute(
		{
			"op": "gather",
			"unit_id": EntityRegistryScript.id_of(villager),
			"target_id": EntityRegistryScript.id_of(resource),
			"command_id": "gather-1",
		},
		ctx
	)
	if not bool(result.get("ok")):
		failures.append("gather command should execute, reason=%s" % result.get("reason"))
	if villager.get("order") != Enums.OrderType.GATHER:
		failures.append("gather command should set order to GATHER")

	setup.root.free()


func _test_attack_sets_order(failures: Array[String]) -> void:
	var setup := _make_ai_villager_and_enemy()
	var villager: Node2D = setup.villager
	var enemy: Node2D = setup.enemy
	var ctx: CommandExecutionContext = setup.ctx

	var result := CommandExecutorScript.execute(
		{
			"op": "attack",
			"unit_id": EntityRegistryScript.id_of(villager),
			"target_id": EntityRegistryScript.id_of(enemy),
			"command_id": "attack-1",
		},
		ctx
	)
	if not bool(result.get("ok")):
		failures.append("attack command should execute, reason=%s" % result.get("reason"))
	if villager.get("order") != Enums.OrderType.ATTACK:
		failures.append("attack command should set order to ATTACK")

	setup.root.free()


func _test_duplicate_command_id_skipped(failures: Array[String]) -> void:
	var setup := _make_ai_villager_and_food()
	var villager: Node2D = setup.villager
	var resource: Node2D = setup.resource
	var ctx: CommandExecutionContext = setup.ctx

	var cmd := {
		"op": "gather",
		"unit_id": EntityRegistryScript.id_of(villager),
		"target_id": EntityRegistryScript.id_of(resource),
		"command_id": "dup-gather",
	}
	var first := CommandExecutorScript.execute(cmd, ctx)
	if not bool(first.get("ok")):
		failures.append("first gather should succeed")

	villager.call("command_stop")
	if villager.get("order") != Enums.OrderType.NONE:
		failures.append("setup should reset villager order before duplicate test")

	var second := CommandExecutorScript.execute(cmd, ctx)
	if not bool(second.get("ok")):
		failures.append("duplicate command_id should return ok (skipped)")
	if String(second.get("reason")) != "duplicate_skipped":
		failures.append(
			"duplicate command_id should report duplicate_skipped, got %s" % second.get("reason")
		)
	if villager.get("order") != Enums.OrderType.NONE:
		failures.append("duplicate command_id should not re-execute gather")

	setup.root.free()


func _make_ai_villager_and_food() -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)
	var entities := Node2D.new()
	root.add_child(entities)
	var state := MatchState.new()
	state.setup_defaults()

	var villager := UNIT_VIEW.instantiate() as Node2D
	villager.set("team", Enums.Team.AI)
	villager.set("def", VILLAGER)
	villager.set("civ", TEUTONS)
	villager.set("match_state", state)
	villager.set("sim_pos", Vector2(10.0, 10.0))
	entities.add_child(villager)
	_ensure_registered(villager)

	var resource := RESOURCE_NODE_SCRIPT.new()
	resource.resource_type = Enums.ResourceType.FOOD
	resource.amount = 100.0
	resource.sim_pos = Vector2(12.0, 10.0)
	entities.add_child(resource)
	_ensure_registered(resource)

	var ctx := CommandExecutionContextScript.new()
	ctx.match_state = state
	ctx.entities = entities
	ctx.team = Enums.Team.AI
	ctx.civ = TEUTONS
	return {"root": root, "villager": villager, "resource": resource, "ctx": ctx}


func _make_ai_villager_and_enemy() -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)
	var entities := Node2D.new()
	root.add_child(entities)
	var state := MatchState.new()
	state.setup_defaults()

	var villager := UNIT_VIEW.instantiate() as Node2D
	villager.set("team", Enums.Team.AI)
	villager.set("def", VILLAGER)
	villager.set("civ", TEUTONS)
	villager.set("match_state", state)
	villager.set("sim_pos", Vector2(10.0, 10.0))
	entities.add_child(villager)
	_ensure_registered(villager)

	var enemy := UNIT_VIEW.instantiate() as Node2D
	enemy.set("team", Enums.Team.PLAYER)
	enemy.set("def", SWORDSMAN)
	enemy.set("civ", TEUTONS)
	enemy.set("match_state", state)
	enemy.set("sim_pos", Vector2(20.0, 10.0))
	entities.add_child(enemy)
	_ensure_registered(enemy)

	var ctx := CommandExecutionContextScript.new()
	ctx.match_state = state
	ctx.entities = entities
	ctx.team = Enums.Team.AI
	ctx.civ = TEUTONS
	return {"root": root, "villager": villager, "enemy": enemy, "ctx": ctx}


func _ensure_registered(entity: Node2D) -> void:
	if entity == null:
		return
	var unit_def := entity.get("def") as UnitDef
	if unit_def != null and float(entity.get("hp")) <= 0.0:
		entity.set("hp", float(unit_def.max_hp))
	if EntityRegistryScript.id_of(entity) < 0:
		EntityRegistryScript.register(entity)
