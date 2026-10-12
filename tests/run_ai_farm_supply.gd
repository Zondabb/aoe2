extends SceneTree
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Manager := preload("res://scripts/systems/ai/ai_build_manager.gd")
const Queries := preload("res://scripts/systems/ai/ai_entity_queries.gd")
const Executor := preload("res://scripts/ai_gateway/command_executor.gd")
var checks := 0
var failures: Array[String] = []
var ctx: AiRunContext
var state: MatchState
var entities: Node2D

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func refresh() -> void:
	ctx.blackboard.refresh(state, entities, ctx.team, ctx.enemy_team, 0, 20)
	for villager in ctx.blackboard.team_villagers:
		villager.command_stop()
		villager.set_physics_process(false)

func farms() -> Array[BuildingAgent]:
	var result: Array[BuildingAgent] = []
	for entity in entities.get_children():
		if entity is BuildingAgent and entity.team == ctx.team and entity.def.id == &"farm":
			result.append(entity)
	return result

func _run() -> void:
	var session := root.get_node("GameSession")
	session.match_ai_mode = "sandbox"
	session.match_map_data = {}
	session.online_active = false
	session.ai_civ_id = &"teutons"
	var world := load("res://scenes/match_2d.tscn").instantiate() as Node
	root.add_child(world)
	current_scene = world
	await process_frame
	await process_frame
	preload("res://scripts/debug/unit_debug_focus.gd").set_spectator_mode(true)
	state = world.get_node("Bootstrap").match_state
	entities = world.get_node("Entities")
	state.fog_enabled = false
	world.get_node("LandSupport").set_process(false)
	world.get_node("Camera2D").set_process(false)
	for entity in entities.get_children(): entity.set_physics_process(false)
	ctx = AiRunContext.new()
	ctx.match_state = state
	ctx.entities = entities
	ctx.civ = load("res://data/civs/teutons.tres")
	ctx.team = Enums.Team.AI
	ctx.enemy_team = Enums.Team.PLAYER
	ctx.blackboard = AiBlackboard.new()
	state.resources[ctx.team][Enums.ResourceType.WOOD] = 2000
	# Isolate food production with enough housing for the existing workforce.
	state.register_pop(ctx.team, 0, 20)
	refresh()
	var manager := Manager.new()
	check(not manager.ensure_food_supply(ctx), "farms require a completed mill")
	check(manager.ensure_building(ctx, Catalog.get_building("mill")), "AI establishes its mill normally")
	for entity in entities.get_children():
		if entity is BuildingAgent and not entity.is_complete:
			entity.add_build_progress(entity.def.build_time)
	refresh()
	check(not manager.ensure_food_supply(ctx), "sufficient nearby berries avoid unnecessary farm expense")
	for entity in entities.get_children():
		if entity is ResourceNode and entity.resource_type == Enums.ResourceType.FOOD:
			entity.amount = 0
	refresh()
	var wood_before := state.get_resource(ctx.team, Enums.ResourceType.WOOD)
	var workers := ctx.blackboard.team_villagers
	workers[0].order = Enums.OrderType.BUILD
	workers[1].order = Enums.OrderType.GATHER
	workers[1].carry_amount = 10.0
	workers[1]._gather_state = "to_drop_off"
	workers[2].order = Enums.OrderType.ATTACK
	check(not manager.ensure_food_supply(ctx) and farms().is_empty(), "farms cannot interrupt construction, combat or a resource delivery")
	check(state.get_resource(ctx.team, Enums.ResourceType.WOOD) == wood_before, "no available builder leaves resources unchanged")
	workers[1].carry_amount = 0.0
	workers[1]._gather_state = "gathering"
	manager.tick(ctx)
	check(workers[1].order == Enums.OrderType.BUILD and workers[0].order == Enums.OrderType.BUILD and workers[2].order == Enums.OrderType.ATTACK, "an empty-handed gatherer builds while protected orders remain intact")
	check(farms().size() == 1, "food depletion triggers the first farm in the actual ECO decision tick")
	check(farms().size() == 1, "first farm is a real foundation")
	var first := farms()[0]
	check(first.has_method("extract") and first.get_script().resource_path.ends_with("farm_agent.gd"), "offline AI installs the gatherable FarmAgent script")
	check(first.extract(1) == 0, "unfinished farm cannot provide food")
	check(state.get_resource(ctx.team, Enums.ResourceType.WOOD) == wood_before - 60, "first farm pays its original wood cost")
	refresh()
	check(not manager.ensure_food_supply(ctx), "an unfinished farm prevents assigning another foundation")
	first.add_build_progress(first.def.build_time)
	refresh()
	check(first.is_in_group("resource_nodes") and first.extract(1) == 4, "completed AI farm supplies food and registers as a gathering resource")
	check(manager.ensure_food_supply(ctx), "a second farm is allowed despite an existing completed farm")
	for farm in farms():
		if not farm.is_complete: farm.add_build_progress(farm.def.build_time)
	refresh()
	check(farms().size() == 2 and not manager.ensure_food_supply(ctx), "three villagers maintain two active plots instead of unbounded construction")
	first.amount = 0
	wood_before = state.get_resource(ctx.team, Enums.ResourceType.WOOD)
	refresh()
	check(manager.ensure_food_supply(ctx), "offline AI prefers renewing an exhausted completed plot")
	check(first.amount == 175 and farms().size() == 2, "renewal restores original farm capacity without another reserved site")
	check(state.get_resource(ctx.team, Enums.ResourceType.WOOD) == wood_before - 60, "renewal spends exactly one farm's wood cost")
	first.amount = 0
	state.resources[ctx.team][Enums.ResourceType.WOOD] = 0
	refresh()
	check(not manager.ensure_food_supply(ctx) and first.amount == 0, "unaffordable renewal leaves the exhausted plot unchanged")
	state.resources[ctx.team][Enums.ResourceType.WOOD] = 500
	refresh()
	ctx.begin_capture(8)
	ctx.issue_move(workers[0], Vector2.ZERO)
	ctx.issue_build(workers[1], first)
	check(manager.ensure_food_supply(ctx), "captured AI uses the shared farm construction command")
	var captured_farm: Dictionary = ctx.pending_commands.back()
	check(captured_farm.get("builder_id") == EntityRegistry.id_of(workers[2]), "captured farms skip workers with already queued movement or construction")
	check(first.amount == 0 and state.get_resource(ctx.team, Enums.ResourceType.WOOD) == 500, "capturing a farm command performs no hidden reseed or resource mutation")
	check(not manager.ensure_food_supply(ctx) and ctx.pending_commands.size() == 3, "captured farm construction remains limited to one foundation per decision")
	var execution := CommandExecutionContext.new()
	execution.match_state = state
	execution.entities = entities
	execution.team = ctx.team
	execution.civ = ctx.civ
	check(Executor.execute(captured_farm, execution).ok, "the ordinary protocol executes the captured farm")
	check(farms().size() == 3 and farms()[2].has_method("extract"), "protocol farm creation installs the same FarmAgent script")
	check(state.get_resource(ctx.team, Enums.ResourceType.WOOD) == 440, "executing the farm command spends wood once")
	var current_farms := farms()
	for farm in current_farms:
		var others := Queries.all_buildings(entities)
		others.erase(farm)
		check(Queries.can_plan_settlement(farm.def.footprint, farm.sim_pos, others), "all active and exhausted plots retain AI layout clearance")
	print("AI FARM SUPPLY: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
