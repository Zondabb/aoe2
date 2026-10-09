extends SceneTree

const Economy := preload("res://scripts/systems/ai/ai_economy_manager.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var state := MatchState.new()
	state.setup_defaults()
	state.progression_enabled = true
	var ctx := AiRunContext.new()
	ctx.match_state = state
	ctx.team = Enums.Team.AI
	ctx.enemy_team = Enums.Team.PLAYER
	ctx.profile = load("res://data/ai/profile_teutons.tres")
	ctx.blackboard = AiBlackboard.new()
	ctx.blackboard.map_bounds = Rect2(-240, -240, 480, 480)
	var food := ResourceNode.new()
	food.resource_type = Enums.ResourceType.FOOD
	food.sim_pos = Vector2(10, 0)
	var ore := ResourceNode.new()
	ore.resource_type = Enums.ResourceType.GOLD
	ore.sim_pos = Vector2(20, 0)
	ctx.blackboard.resource_nodes.assign([food, ore])
	var workers: Array[UnitAgent] = []
	for index in 3:
		var worker := UnitAgent.new()
		worker.order = Enums.OrderType.GATHER
		worker._gather_state = "searching_resource"
		worker._last_resource = food
		workers.append(worker)
	ctx.blackboard.team_villagers.assign(workers)
	var economy := Economy.new()
	for previous in ["depleted", "missing", "stuck"]:
		ctx.blackboard.team_villagers.assign([workers[0]])
		food.amount = 100
		workers[0]._last_resource = food
		workers[0]._no_progress_frames = 0
		if previous == "depleted": food.amount = 0
		elif previous == "missing": workers[0]._last_resource = null
		else: workers[0]._no_progress_frames = 12
		ctx.begin_capture(1)
		economy.assign_gatherers(ctx)
		check(ctx.pending_commands.is_empty(), "budgeted resource search protects %s prior target" % previous)
	food.amount = 100
	workers[0]._last_resource = food
	workers[0]._no_progress_frames = 0
	ctx.blackboard.team_villagers.assign(workers)
	ctx.begin_capture(2)
	economy.assign_gatherers(ctx)
	check(ctx.pending_commands.is_empty(), "resource search is protected when newly discovered ore invites rebalancing")
	for worker in workers: worker.free()
	food.free()
	ore.free()
	print("AI GATHER CONTINUATION: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
