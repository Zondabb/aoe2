extends SceneTree
## Validate decisions and execute captured orders against real production rules.

const Catalog := preload("res://scripts/data/game_catalog.gd")
const Production := preload("res://scripts/systems/ai/ai_production_manager.gd")
const Progression := preload("res://scripts/systems/ai/ai_progression_manager.gd")
const Build := preload("res://scripts/systems/ai/ai_build_manager.gd")
const Economy := preload("res://scripts/systems/ai/ai_economy_manager.gd")
const Executor := preload("res://scripts/ai_gateway/command_executor.gd")
const Observation := preload("res://scripts/ai_gateway/observation_builder.gd")
var checks := 0
var failures: Array[String] = []
var world: Node2D
var ctx: AiRunContext

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func fixture(age: int = 0) -> void:
	world = Node2D.new()
	root.add_child(world)
	world.process_mode = Node.PROCESS_MODE_DISABLED
	ctx = AiRunContext.new()
	ctx.match_state = MatchState.new()
	ctx.match_state.setup_defaults()
	ctx.match_state.progression_enabled = true
	ctx.match_state.set_age(Enums.Team.AI, age)
	ctx.match_state.population_cap[Enums.Team.AI] = 30
	ctx.match_state.team_civilizations = {Enums.Team.AI: &"teutons"}
	ctx.match_state.unit_catalog.assign(Catalog.units().values())
	ctx.entities = world
	ctx.team = Enums.Team.AI
	ctx.enemy_team = Enums.Team.PLAYER
	ctx.civ = load("res://data/civs/teutons.tres")
	ctx.profile = CivAiProfile.for_civ(ctx.civ)
	ctx.blackboard = AiBlackboard.new()
	var age_service := AgeProgression.new()
	world.add_child(age_service)
	age_service.setup(ctx.match_state, world)
	for index in 8:
		var worker := load("res://scenes/entities/unit_view.tscn").instantiate() as UnitAgent
		worker.def = Catalog.get_unit("villager")
		worker.civ = ctx.civ
		worker.team = ctx.team
		worker.match_state = ctx.match_state
		worker.sim_pos = Vector2(45 + index * 2, 55)
		world.add_child(worker)

func building(id: String, pos: Vector2) -> BuildingAgent:
	var actor := load("res://scenes/entities/building_view.tscn").instantiate() as BuildingAgent
	actor.def = Catalog.get_building(id)
	actor.civ = ctx.civ
	actor.team = ctx.team
	actor.match_state = ctx.match_state
	actor.sim_pos = pos
	world.add_child(actor)
	return actor

func refresh() -> void:
	ctx.blackboard.refresh(ctx.match_state, world, ctx.team, ctx.enemy_team, 0, 20)

func train_commands() -> Array:
	return ctx.pending_commands.filter(func(c): return c.op == "train")

func execute_orders() -> void:
	var execution := CommandExecutionContext.new()
	execution.match_state = ctx.match_state
	execution.entities = world
	execution.team = ctx.team
	execution.civ = ctx.civ
	for command in ctx.pending_commands:
		var result := Executor.execute(command, execution)
		check(result.ok, "captured %s executes legally: %s" % [command.op, result.reason])

func _run() -> void:
	UnitDebugFocus.set_spectator_mode(true)
	fixture()
	var first := building("barracks", Vector2(40, 40))
	var second := building("barracks", Vector2(70, 40))
	ctx.match_state.resources[ctx.team][Enums.ResourceType.FOOD] = 120
	refresh()
	ctx.begin_capture(1)
	Production.new().tick(ctx, Build.new())
	check(train_commands().size() == 2, "both idle barracks train before an army exists, below age-up stockpile")
	check(ctx.available_resource(Enums.ResourceType.FOOD) == 0, "captured troops share the food budget")
	execute_orders()
	check(first.train_queue.size() == 1 and second.train_queue.size() == 1, "both real training queues receive soldiers")
	var snapshot := Observation.build(ctx.match_state, world, ctx.team, ctx.enemy_team, 0)
	check(snapshot.economy.pop_reserved == 2, "external AI sees population already reserved in queues")
	world.free()

	fixture()
	building("barracks", Vector2(40, 40))
	building("barracks", Vector2(70, 40))
	ctx.match_state.population_cap[ctx.team] = 9
	refresh()
	ctx.begin_capture(2)
	Production.new().tick(ctx, Build.new())
	check(train_commands().size() == 1, "one remaining population slot permits only one producer")
	execute_orders()
	world.free()

	fixture(1)
	building("archery_range", Vector2(40, 40))
	ctx.match_state.resources[ctx.team][Enums.ResourceType.GOLD] = 0
	refresh()
	ctx.begin_capture(3)
	Production.new().tick(ctx, Build.new())
	var affordable := train_commands()
	check(affordable.size() == 1 and affordable[0].unit_def_id == "skirmisher", "gold shortage selects an affordable counter unit")
	execute_orders()
	world.free()

	fixture()
	var tc := building("town_center", Vector2(40, 40))
	building("mill", Vector2(70, 40))
	building("lumber_camp", Vector2(90, 40))
	ctx.match_state.resources[ctx.team][Enums.ResourceType.FOOD] = 550
	refresh()
	ctx.begin_capture(4)
	check(ctx.issue_age_upgrade(tc), "ready age research is captured")
	check(not ctx.issue_train(tc, Catalog.get_unit("villager")), "age research and training cannot share a producer in one decision")
	check(ctx.available_resource(Enums.ResourceType.FOOD) == 50, "age research reserves its cost in the decision budget")
	execute_orders()
	world.free()

	fixture()
	building("town_center", Vector2(40, 40))
	ctx.match_state.population_cap[ctx.team] = 8
	ctx.match_state.resources[ctx.team][Enums.ResourceType.FOOD] = 0
	ctx.match_state.resources[ctx.team][Enums.ResourceType.WOOD] = Catalog.get_building("house").cost_wood
	refresh()
	ctx.begin_capture(5)
	Build.new().ensure_population_capacity(ctx)
	check(ctx.pending_commands.size() == 1 and ctx.pending_commands[0].building_def_id == "house", "housing can recover a block without food to train")
	Economy.new().assign_gatherers(ctx)
	if not ctx.pending_commands.is_empty():
		var builder_id := int(ctx.pending_commands[0].builder_id)
		check(not ctx.pending_commands.any(func(c): return c.op == "gather" and c.unit_id == builder_id), "gather allocation preserves captured construction")
	execute_orders()
	world.free()
	print("AI PRODUCTION STRATEGY: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
