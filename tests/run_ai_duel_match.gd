extends SceneTree
## Headless AI-vs-AI duel: each team is controlled by its own external Python
## AI service over real v3 HTTP, with real fog, economy, combat and victory.
## Args: url_team0 url_team1 duration_sec report_path civ_team0 civ_team1
const Observation := preload("res://scripts/ai_gateway/observation_builder.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Events := preload("res://scripts/ai_gateway/event_buffer.gd")
const Executor := preload("res://scripts/ai_gateway/command_executor.gd")
const ExecutionContext := preload("res://scripts/ai_gateway/command_execution_context.gd")
const DT := 0.25

func _initialize() -> void:
	call_deferred("_run")

func _cost(definition: Resource) -> int:
	return int(definition.get("cost_food")) + int(definition.get("cost_wood")) + int(definition.get("cost_gold")) + int(definition.get("cost_stone"))

func _summary(state: MatchState, entities: Node2D) -> Array:
	var teams: Array = []
	for team in 2:
		var record := {"age": state.age_of(team), "villagers": 0, "military": 0, "military_value": 0, "tc_hp": 0.0, "resources": state.resources[team].duplicate()}
		for entity in entities.get_children():
			if entity.is_queued_for_deletion() or entity.get("team") != team: continue
			if entity is UnitAgent:
				if entity.def.id == &"villager": record["villagers"] += 1
				else:
					record["military"] += 1
					record["military_value"] += _cost(entity.def)
			elif entity is BuildingAgent and entity.def.id == &"town_center" and entity.is_complete:
				record["tc_hp"] += float(entity.hp)
		teams.append(record)
	return teams

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 6:
		push_error("AI DUEL usage: url0 url1 duration report civ0 civ1")
		quit(2)
		return
	var civs := [StringName(args[4]), StringName(args[5])]
	var session := root.get_node("GameSession")
	session.match_ai_mode = "sandbox"
	session.match_map_data = {}
	session.online_active = false
	session.player_civ_id = civs[0]
	session.ai_civ_id = civs[1]
	var world := load("res://scenes/match_2d.tscn").instantiate() as Node2D
	root.add_child(world)
	current_scene = world
	await process_frame
	await process_frame
	UnitDebugFocus.set_spectator_mode(true)
	world.process_mode = Node.PROCESS_MODE_DISABLED
	var state: MatchState = world.get_node("Bootstrap").match_state
	var entities: Node2D = world.get_node("Entities")
	var match_id := "ai-duel-%d" % Time.get_ticks_usec()
	var epoch := "duel-epoch"
	var clients: Array = []
	var contexts: Array = []
	var subscribers: Array = []
	var stats: Array = []
	for team in 2:
		var client: Node = load("res://scripts/ai_gateway/http_ai_client.gd").new()
		root.add_child(client)
		var config: RefCounted = load("res://scripts/ai_gateway/ai_config.gd").new()
		config.use_local_embedded = false
		config.service_url = args[team]
		config.backend = "openai"
		config.timeout_sec = 10.0
		config.fast_timeout_sec = 10.0
		client.configure(config)
		var started: Dictionary = await client.post_match_start({"match_id": match_id, "teams": [{"team": team}]})
		if started.get("ok") != true:
			push_error("AI DUEL: service for team %d did not start: %s" % [team, client.last_error])
			quit(1)
			return
		var ctx := ExecutionContext.new()
		ctx.match_id = match_id
		ctx.team = team
		ctx.match_state = state
		ctx.entities = entities
		ctx.civ = load("res://data/civs/%s.tres" % String(civs[team]))
		ctx.session_epoch = epoch
		ctx.require_session_epoch = true
		clients.append(client)
		contexts.append(ctx)
		subscribers.append(Events.subscribe())
		stats.append({"calls": 0, "rejects": {}, "trained": {}, "max_http_ms": 0.0, "milestones": {}, "buildings": {}})
	var initial := {}
	for entity in entities.get_children():
		initial[entity.get_instance_id()] = true
	var duration := float(args[2])
	var finished_at := 0.0
	var failed := ""
	for step in ceili(duration / DT):
		var now := step * DT
		finished_at = now
		state.fog.rebuild(entities.get_children())
		if step % 4 == 0:
			for team in 2:
				Registry.sample_owned_state(entities, team, now)
				var delivery := Events.peek(subscribers[team])
				var observation := Observation.build(state, entities, team, 1 - team, now)
				var payload := {"model": "duel", "messages": [], "tools": [], "metadata": {
					"protocol_version": 3, "match_id": match_id, "team": team, "enemy_team": 1 - team,
					"tick": step, "observation_seq": step, "time_sec": now, "profile_id": String(civs[team]),
					"backend": "openai", "session_epoch": epoch, "event_delivery": delivery.duplicate()},
					"observation": observation, "events": Events.for_team(delivery.events, team, state.fog_enabled)}
				payload["metadata"]["event_delivery"].erase("events")
				var before := Time.get_ticks_usec()
				var response: Dictionary = await clients[team].post_multi_agent_tick(payload)
				stats[team]["max_http_ms"] = maxf(stats[team]["max_http_ms"], float(Time.get_ticks_usec() - before) / 1000.0)
				if response.is_empty():
					failed = "team %d HTTP failed: %s" % [team, clients[team].last_error]
					break
				stats[team]["calls"] += 1
				Events.acknowledge(subscribers[team], delivery.to_seq)
				contexts[team].sim_time = now
				for cmd in response.get("commands", []):
					var result := Executor.execute(cmd, contexts[team])
					var event := {"type": "command_result", "command_id": cmd.command_id, "op": cmd.op,
						"ok": result.ok, "reason": result.reason, "command": cmd, "time_sec": now, "_visible_to": [team]}
					for key in ["created_entity_id", "created_entity_ids", "segment_count", "queue_id", "building_id"]:
						if result.has(key): event[key] = result[key]
					Events.push(event)
					if not result.ok:
						stats[team]["rejects"][result.reason] = stats[team]["rejects"].get(result.reason, 0) + 1
			if not failed.is_empty(): break
		world.get_node("NavService")._process(DT)
		for entity in entities.get_children():
			if entity.is_queued_for_deletion(): continue
			if entity is BuildingAgent: entity._process(DT)
			if entity is UnitAgent or entity is BuildingAgent or entity is ProjectileAgent: entity._physics_process(DT)
		state.age_progression._process(DT)
		state.technology_progression._process(DT)
		world.get_node("LandSupport")._process(DT)
		for entity in entities.get_children():
			if entity.is_queued_for_deletion(): continue
			if entity is UnitAgent and entity.def.id != &"villager" and not initial.has(entity.get_instance_id()):
				stats[entity.team]["trained"][entity.get_instance_id()] = [String(entity.def.id), _cost(entity.def)]
			if entity is BuildingAgent and entity.is_complete: stats[entity.team]["buildings"][String(entity.def.id)] = true
		for team in 2:
			var marks: Dictionary = stats[team]["milestones"]
			if stats[team]["buildings"].has("barracks") and not marks.has("barracks"): marks["barracks"] = now
			if not stats[team]["trained"].is_empty() and not marks.has("first_soldier"): marks["first_soldier"] = now
			var age_key := "age_%d" % state.age_of(team)
			if state.age_of(team) > 0 and not marks.has(age_key): marks[age_key] = now
		if step % 480 == 0: print("AI DUEL %.0fs: %s" % [now, JSON.stringify(_summary(state, entities))])
		await process_frame
		if state.winner != -1: break
	var final := _summary(state, entities)
	var teams: Array = []
	for team in 2:
		var produced := {}
		var produced_value := 0
		var lost_value := 0
		for instance_id in stats[team]["trained"]:
			var info: Array = stats[team]["trained"][instance_id]
			produced[info[0]] = produced.get(info[0], 0) + 1
			produced_value += int(info[1])
			if not is_instance_id_valid(instance_id): lost_value += int(info[1])
		teams.append({"civ": String(civs[team]), "calls": stats[team]["calls"], "rejects": stats[team]["rejects"],
			"max_http_ms": stats[team]["max_http_ms"], "milestones": stats[team]["milestones"], "produced": produced,
			"produced_military_value": produced_value, "lost_military_value": lost_value, "final": final[team]})
	var report := {"winner": state.winner, "finished_at": finished_at, "failed": failed, "teams": teams}
	var file := FileAccess.open(args[3], FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("AI DUEL RESULT: " + JSON.stringify(report))
	for client in clients:
		await client.post_match_end({"match_id": match_id})
	for subscriber in subscribers:
		Events.unsubscribe(subscriber)
	for client in clients:
		client.free()
	state.frozen = true
	world.free()
	current_scene = null
	quit(0 if failed.is_empty() else 1)
