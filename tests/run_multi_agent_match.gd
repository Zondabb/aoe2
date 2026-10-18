extends SceneTree
## Real simulation and real v3 HTTP; the local upstream only supplies role plans.
const Observation := preload("res://scripts/ai_gateway/observation_builder.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Events := preload("res://scripts/ai_gateway/event_buffer.gd")
const Executor := preload("res://scripts/ai_gateway/command_executor.gd")
const ExecutionContext := preload("res://scripts/ai_gateway/command_execution_context.gd")
const DT := 0.25
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error("MULTI AGENT FAILED: " + message)

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 3:
		quit(1)
		return
	var session := root.get_node("GameSession")
	session.match_ai_mode = "sandbox"
	session.match_map_data = {}
	session.online_active = false
	session.player_civ_id = &"chinese"
	session.ai_civ_id = &"teutons"
	var world := load("res://scenes/match_2d.tscn").instantiate() as Node2D
	root.add_child(world)
	current_scene = world
	await process_frame
	await process_frame
	UnitDebugFocus.set_spectator_mode(true)
	world.process_mode = Node.PROCESS_MODE_DISABLED
	var state: MatchState = world.get_node("Bootstrap").match_state
	var entities: Node2D = world.get_node("Entities")
	var client: Node = load("res://scripts/ai_gateway/http_ai_client.gd").new()
	root.add_child(client)
	var config: RefCounted = load("res://scripts/ai_gateway/ai_config.gd").new()
	config.use_local_embedded = false
	config.service_url = args[0]
	config.backend = "openai"
	config.timeout_sec = 10.0
	config.fast_timeout_sec = 10.0
	client.configure(config)
	var match_id := "multi-agent-real-match-%d" % Time.get_ticks_usec()
	var epoch := "e2e-epoch"
	var started: Dictionary = await client.post_match_start({"match_id":match_id, "teams":[{"team":1}]})
	check(started.get("ok") == true, "real service starts a v3 session")
	var ctx := ExecutionContext.new()
	ctx.match_id = match_id
	ctx.team = Enums.Team.AI
	ctx.match_state = state
	ctx.entities = entities
	ctx.civ = load("res://data/civs/teutons.tres")
	ctx.session_epoch = epoch
	ctx.require_session_epoch = true
	var subscriber := Events.subscribe()
	state.fog.rebuild(entities.get_children())
	var first := Observation.build(state, entities, 1, 0, 0.0)
	check(first.derived.enemy_tc_id == -1, "enemy TC starts hidden")
	check(state.resources[1][0] == 200 and state.resources[1][1] == 200, "normal finite opening resources")
	var initial_ids := {}
	var base := Vector2(first.derived.own_tc_pos[0], first.derived.own_tc_pos[1])
	for entity in entities.get_children():
		if entity is UnitAgent: initial_ids[entity.get_instance_id()] = true
	var trained := {}
	var buildings := {}
	var sorties := {}
	var rejects := {}
	var roles := {}
	var goals := {}
	var seen := false
	var damaged := false
	var calls := 0
	var latencies_while_planning: Array[float] = []
	var max_latency := 0.0
	var milestones := {}
	var deposits := {0:0, 1:0, 2:0, 3:0}
	var finished_at := 0.0
	var duration := float(args[1])
	for step in ceili(duration / DT):
		var now := step * DT
		finished_at = now
		state.fog.rebuild(entities.get_children())
		if step % 4 == 0:
			Registry.sample_owned_state(entities, 1, now)
			var delivery := Events.peek(subscriber)
			var observation := Observation.build(state, entities, 1, 0, now)
			seen = seen or observation.derived.enemy_tc_id >= 0
			if seen and not milestones.has("enemy_tc_seen"): milestones["enemy_tc_seen"] = now
			for entity in observation.entities:
				if entity.get("def_id") == "town_center" and entity.get("team") == 0 and entity.hp < entity.max_hp: damaged = true
			if damaged and not milestones.has("enemy_tc_damaged"): milestones["enemy_tc_damaged"] = now
			var payload := {"model":"mock-role-planner", "messages":[], "tools":[], "metadata":{
				"protocol_version":3, "match_id":match_id, "team":1, "enemy_team":0,
				"tick":step, "observation_seq":step, "time_sec":now, "profile_id":"teutons",
				"backend":"openai", "session_epoch":epoch, "event_delivery":delivery.duplicate()},
				"observation":observation, "events":Events.for_team(delivery.events, 1, state.fog_enabled)}
			payload.metadata.event_delivery.erase("events")
			var before_request := Time.get_ticks_usec()
			var response: Dictionary = await client.post_multi_agent_tick(payload)
			var latency := float(Time.get_ticks_usec() - before_request) / 1000.0
			max_latency = maxf(max_latency, latency)
			if response.is_empty():
				check(false, "v3 HTTP failed: %s" % client.last_error)
				break
			calls += 1
			goals = response.get("goals", {})
			for role in response.get("agent_status", {}): roles[role] = true
			for planning in response.get("planning", {}).values():
				if planning is Dictionary and planning.get("state") == "planning":
					latencies_while_planning.append(latency)
					break
			Events.acknowledge(subscriber, delivery.to_seq)
			ctx.sim_time = now
			for cmd in response.get("commands", []):
				var result := Executor.execute(cmd, ctx)
				var event := {"type":"command_result", "command_id":cmd.command_id, "op":cmd.op,
					"ok":result.ok, "reason":result.reason, "command":cmd, "time_sec":now, "_visible_to":[1]}
				for key in ["created_entity_id", "created_entity_ids", "segment_count", "queue_id", "building_id"]:
					if result.has(key): event[key] = result[key]
				Events.push(event)
				if not result.ok: rejects[result.reason] = rejects.get(result.reason, 0) + 1
			if step == 0:
				var balances: Dictionary = state.resources[1].duplicate()
				var retry: Dictionary = await client.post_multi_agent_tick(payload)
				check(retry.get("commands") == response.get("commands"), "HTTP retry returns stable command IDs")
				for cmd in retry.get("commands", []): Executor.execute(cmd, ctx)
				check(state.resources[1] == balances, "HTTP retry cannot spend resources twice")
			if step % 240 == 0:
				var file := FileAccess.open(args[2], FileAccess.WRITE)
				file.store_string(JSON.stringify({"observation":observation, "response":response}, "\t"))
		var before: Dictionary = state.resources[1].duplicate()
		world.get_node("NavService")._process(DT)
		for entity in entities.get_children():
			if entity.is_queued_for_deletion(): continue
			if entity is UnitAgent or entity is BuildingAgent or entity is ProjectileAgent: entity._physics_process(DT)
		for type in deposits: deposits[type] += maxi(0, state.get_resource(1, type) - int(before[type]))
		state.age_progression._process(DT)
		state.technology_progression._process(DT)
		world.get_node("LandSupport")._process(DT)
		for entity in entities.get_children():
			if entity.is_queued_for_deletion(): continue
			if entity is BuildingAgent and entity.team == 1 and entity.is_complete: buildings[String(entity.def.id)] = true
			if entity is UnitAgent and entity.team == 1 and entity.def.id != &"villager" and not initial_ids.has(entity.get_instance_id()):
				trained[entity.get_instance_id()] = String(entity.def.id)
				if entity.sim_pos.distance_to(base) > 55: sorties[entity.get_instance_id()] = true
		if buildings.has("barracks") and not milestones.has("barracks_completed"): milestones["barracks_completed"] = now
		if not trained.is_empty() and not milestones.has("first_soldier"): milestones["first_soldier"] = now
		if sorties.size() >= 3 and not milestones.has("three_soldiers_departed"): milestones["three_soldiers_departed"] = now
		var age_key := "age_%d" % state.age_of(1)
		if state.age_of(1) > 0 and not milestones.has(age_key): milestones[age_key] = now
		if trained.values().any(func(def_id): return "ram" in def_id) and not milestones.has("first_ram"): milestones["first_ram"] = now
		if step % 240 == 0: print("MULTI AGENT %.0fs: resources=%s buildings=%s trained=%d sorties=%d seen=%s damage=%s goals=%s rejects=%s" % [now,state.resources[1],buildings.keys(),trained.size(),sorties.size(),seen,damaged,goals,rejects])
		await process_frame
		if state.winner != -1: break
	check(calls >= 30, "many quick HTTP observations processed")
	check(roles.size() == 7, "all seven independent roles report task state")
	latencies_while_planning.sort()
	var p95 := INF if latencies_while_planning.is_empty() else latencies_while_planning[mini(latencies_while_planning.size() - 1, floori(latencies_while_planning.size() * .95))]
	check(latencies_while_planning.size() >= 2 and p95 < 500, "model planning does not block fast responses (n=%d p95=%.1f ms)" % [latencies_while_planning.size(), p95])
	check(buildings.has("barracks"), "workers finish first military producer")
	check(deposits[0] > 100 and deposits[1] > 100, "economy produces actual food and wood deposits")
	check(trained.size() >= 4, "new soldiers actually spawn")
	check(sorties.size() >= 3, "trained army leaves base")
	check(seen, "scouting discovers hidden TC")
	check(damaged, "army reaches and damages TC")
	check(state.resources[1].values().all(func(value): return value >= 0), "resource budgets stay valid")
	check(rejects.is_empty(), "generated commands pass game validation: %s" % rejects)
	if args.size() > 3 and args[3] == "1": check(state.winner == 1, "AI destroys the enemy TC and wins")
	if args.size() > 4 and args[4] == "1": check(buildings.has("palisade_wall") or buildings.has("stone_wall"), "defense agent actually completes a wall in the match")
	print("MULTI AGENT RESULT: winner=%d finished_at=%.1f trained=%s max_http_ms=%.1f planning_p95_ms=%.1f milestones=%s" % [state.winner, finished_at, trained.values(), max_latency, p95, milestones])
	await client.post_match_end({"match_id":match_id})
	Events.unsubscribe(subscriber)
	client.free()
	state.frozen = true
	world.free()
	current_scene = null
	print("MULTI AGENT MATCH: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
