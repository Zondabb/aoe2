extends SceneTree

const EVENTS := preload("res://scripts/ai_gateway/event_buffer.gd")
const REGISTRY := preload("res://scripts/ai_gateway/entity_registry.gd")
const CONTEXT := preload("res://scripts/ai_gateway/command_execution_context.gd")
const UNIT := preload("res://scenes/entities/unit_view.tscn")
const VILLAGER := preload("res://data/units/villager.tres")
const CIV := preload("res://data/civs/teutons.tres")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)

func _run() -> void:
	EVENTS.clear()
	var world := Node2D.new()
	root.add_child(world)
	var entities := Node2D.new()
	world.add_child(entities)
	var state := MatchState.new()
	state.setup_defaults()
	state.map_bounds = Rect2(-32, -32, 64, 64)
	var unit := UNIT.instantiate() as UnitAgent
	unit.def = VILLAGER
	unit.civ = CIV
	unit.team = Enums.Team.AI
	unit.match_state = state
	unit.sim_pos = Vector2(2, 2)
	entities.add_child(unit)
	unit.set_physics_process(false)
	var id := REGISTRY.register(unit)
	var ctx := CONTEXT.new()
	ctx.match_state = state
	ctx.entities = entities
	ctx.team = Enums.Team.AI
	ctx.civ = CIV
	# Load after autoload initialization; AiConfig refers to GameSession.
	var gateway = load("res://scripts/ai_gateway/ai_gateway.gd").new()
	gateway._exec_contexts[Enums.Team.AI] = ctx
	var commands: Array = [
		{"command_id":"move_ok", "op":"move", "unit_id":id, "pos":[8,4]},
		{"command_id":"move_bad", "op":"move", "unit_id":9999999, "pos":[8,4]},
		{"command_id":"idle", "op":"noop"},
	]
	EVENTS.clear()
	gateway._apply_response({"team":Enums.Team.AI, "commands":commands})
	check(unit.order == Enums.OrderType.MOVE, "accepted external command changes the real unit order")
	var first := EVENTS.drain()
	check(first.size() == 2, "accepted/rejected operations produce feedback while noop does not")
	var own := EVENTS.for_team(first, Enums.Team.AI, true)
	check(own.size() == 2, "issuing team receives both execution results")
	check(own[0].type == "command_result" and own[0].ok and own[0].command_id == "move_ok", "successful feedback reports command acceptance")
	check(not own[1].ok and not String(own[1].reason).is_empty(), "game validator rejection includes its actual reason")
	check(own[1].command == commands[1], "feedback retains failed command arguments for correction")
	check(not own[0].has("_visible_to"), "private routing metadata is removed from the model payload")
	check(EVENTS.for_team(first, Enums.Team.PLAYER, true).is_empty(), "opponent cannot receive execution feedback with fog")
	check(EVENTS.for_team(first, Enums.Team.PLAYER, false).is_empty(), "opponent cannot receive execution feedback without fog")
	check(EVENTS.for_team(first, Enums.Team.AI, false).size() == 2, "owner retains feedback when fog is disabled")
	gateway._apply_response({"team":Enums.Team.AI, "commands":[commands[0]]})
	check(EVENTS.drain().is_empty(), "retrying an accepted command does not repeat feedback or actions")
	EVENTS.push({"type":"public_test"})
	var public_events := EVENTS.drain()
	check(EVENTS.for_team(public_events, Enums.Team.PLAYER, false).size() == 1, "non-fog public lifecycle events remain compatible")
	check(EVENTS.for_team(public_events, Enums.Team.PLAYER, true).is_empty(), "untagged events stay hidden in fog matches")
	gateway.free()
	world.free()
	EVENTS.clear()
	print("EXTERNAL AI FEEDBACK: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
