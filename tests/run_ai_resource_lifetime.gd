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
	var ctx := AiRunContext.new()
	ctx.match_state = MatchState.new()
	ctx.match_state.setup_defaults()
	ctx.match_state.progression_enabled = true
	ctx.team = Enums.Team.AI
	ctx.enemy_team = Enums.Team.PLAYER
	ctx.profile = load("res://data/ai/profile_teutons.tres")
	ctx.blackboard = AiBlackboard.new()
	ctx.blackboard.map_bounds = Rect2(-240, -240, 480, 480)
	var economy := Economy.new()
	var food := _resource(Enums.ResourceType.FOOD)
	var wood := _resource(Enums.ResourceType.WOOD)
	ctx.blackboard.resource_nodes.assign([food, wood])
	var worker := _worker(food)
	ctx.blackboard.team_villagers.assign([worker])
	var removed := _resource(Enums.ResourceType.FOOD)
	worker._last_resource = removed
	removed.free()
	check(not is_instance_valid(worker.get("_last_resource")), "fixture retains an actually freed resource reference")
	var counts: Variant = economy._count_active_gatherers(ctx)
	check(counts is Dictionary and counts.get(Enums.ResourceType.FOOD) == 0, "freed resource is excluded from active gatherer counts")
	var idle: Variant = economy._villagers_needing_gather(ctx)
	check(idle is Array and worker in idle, "worker with freed source needs a replacement job")
	ctx.begin_capture(1)
	economy.assign_gatherers(ctx)
	check(ctx.pending_commands.size() == 1 and ctx.pending_commands[0].op == "gather", "AI assigns a surviving source after the old source is freed")
	for delivery_state in ["to_drop_off", "searching_resource"]:
		worker._gather_state = delivery_state
		ctx.begin_capture(2)
		economy.assign_gatherers(ctx)
		check(ctx.pending_commands.is_empty(), "freed source does not interrupt " + delivery_state)
	worker._gather_state = "gathering"
	var other := _worker(food)
	var third := _worker(food)
	ctx.blackboard.team_villagers.assign([worker, other, third])
	ctx.begin_capture(3)
	economy._rebalance_discovered_type(ctx)
	check(ctx.pending_commands.size() == 1 and ctx.pending_commands[0].unit_id != EntityRegistry.id_of(worker), "rebalancing skips stale history and can assign a live surplus worker")
	check(ctx.pending_commands.size() == 1 and ctx.pending_commands[0].target_id == EntityRegistry.id_of(wood), "rebalancing still sends the live worker to newly found wood")
	# queue_free is a separate lifecycle state before the deletion is flushed.
	var queued := _resource(Enums.ResourceType.FOOD)
	root.add_child(queued)
	worker._last_resource = queued
	queued.queue_free()
	ctx.blackboard.team_villagers.assign([worker])
	counts = economy._count_active_gatherers(ctx)
	check(counts is Dictionary and counts.get(Enums.ResourceType.FOOD) == 0, "queued resource is excluded before deletion flush")
	ctx.begin_capture(4)
	economy.assign_gatherers(ctx)
	check(ctx.pending_commands.size() == 1, "queued source triggers a replacement gather order")
	worker._last_resource = food
	counts = economy._count_active_gatherers(ctx)
	check(counts is Dictionary and counts.get(Enums.ResourceType.FOOD) == 1, "live source still counts as active work")
	worker._last_resource = null
	counts = economy._count_active_gatherers(ctx)
	check(counts is Dictionary and counts.get(Enums.ResourceType.FOOD) == 0, "null source remains safe")
	for node in [worker, other, third, food, wood]: node.free()
	await process_frame
	EntityRegistry.clear()
	check(checks == 12, "all resource lifetime scenarios ran to completion")
	print("AI RESOURCE LIFETIME: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _resource(type: int) -> ResourceNode:
	var resource := ResourceNode.new()
	resource.resource_type = type
	resource.amount = 100.0
	resource.sim_pos = Vector2(10, 0)
	EntityRegistry.register(resource)
	return resource

func _worker(resource: ResourceNode) -> UnitAgent:
	var worker := UnitAgent.new()
	worker.def = load("res://data/units/villager.tres")
	worker.team = Enums.Team.AI
	worker.order = Enums.OrderType.GATHER
	worker._gather_state = "gathering"
	worker._last_resource = resource
	EntityRegistry.register(worker)
	return worker
