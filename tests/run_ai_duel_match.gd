extends SceneTree
## Headless AI-vs-AI duel: each team is controlled by its own external Python
## AI service over real v3 HTTP, with real fog, economy, combat and victory.
## Args: url_team0 url_team1 duration_sec report_path civ_team0 civ_team1 [map_seed]
## Without map_seed the match uses the default map; a seed regenerates the same
## rotationally symmetric layout with different forest placement.
## AOE2_DUEL_SYMMETRY_TRACE=1 (mirror matches: same code and civ on both sides)
## prints the first steps where the two teams' units and buildings stop being
## 180-degree rotations of each other.
const Observation := preload("res://scripts/ai_gateway/observation_builder.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Events := preload("res://scripts/ai_gateway/event_buffer.gd")
const Executor := preload("res://scripts/ai_gateway/command_executor.gd")
const ExecutionContext := preload("res://scripts/ai_gateway/command_execution_context.gd")
const MapGenerator := preload("res://scripts/world/default_map_generator.gd")
const DT := 0.25

func _team_digest(entities: Node2D, team: int) -> Array:
	var rows: Array = []
	for entity in entities.get_children():
		if entity.is_queued_for_deletion(): continue
		if not (entity is UnitAgent or entity is BuildingAgent): continue
		if int(entity.get("team")) != team: continue
		var pos: Vector2 = entity.get("sim_pos")
		if team == 1: pos = -pos
		var order := int(entity.get("order")) if entity is UnitAgent else -1
		rows.append("%s %d,%d hp=%d order=%d" % [String(entity.get("def").id), roundi(pos.x), roundi(pos.y), roundi(float(entity.get("hp"))), order])
	rows.sort()
	return rows

func _team_shape(entities: Node2D, team: int) -> Dictionary:
	var counts := {}
	for entity in entities.get_children():
		if entity.is_queued_for_deletion(): continue
		if not (entity is UnitAgent or entity is BuildingAgent): continue
		if int(entity.get("team")) != team: continue
		var key := String(entity.get("def").id)
		if entity is BuildingAgent and not bool(entity.get("is_complete")): key += "(site)"
		counts[key] = int(counts.get(key, 0)) + 1
	return counts

func _symmetry_diff(entities: Node2D) -> String:
	var a := _team_digest(entities, 0)
	var b := _team_digest(entities, 1)
	if a == b: return ""
	var only_a := a.filter(func(row): return not b.has(row))
	var only_b := b.filter(func(row): return not a.has(row))
	return "team0 only %s | team1 only %s" % [JSON.stringify(only_a.slice(0, 6)), JSON.stringify(only_b.slice(0, 6))]

func _unit_trace(entities: Node2D, team: int) -> Array:
	# Soldiers and wounded units only, team1 rotated like _team_digest.
	var rows: Array = []
	for entity in entities.get_children():
		if entity.is_queued_for_deletion() or not entity is UnitAgent or int(entity.get("team")) != team: continue
		if entity.def.id == &"villager" and float(entity.hp) >= float(entity.def.max_hp): continue
		var pos: Vector2 = entity.get("sim_pos")
		if team == 1: pos = -pos
		rows.append("%s %d,%d hp=%d order=%d" % [String(entity.def.id), roundi(pos.x), roundi(pos.y), roundi(float(entity.hp)), int(entity.get("order"))])
	rows.sort()
	return rows

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
	if args.size() >= 7 and args[6].is_valid_int():
		session.match_map_data = MapGenerator.generate(int(args[6]), civs[0], civs[1])
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
	var symmetry_trace := OS.get_environment("AOE2_DUEL_SYMMETRY_TRACE") == "1"
	var symmetry_reports := 0
	var shape_reports := 0
	var finished_at := 0.0
	var failed := ""
	for step in ceili(duration / DT):
		var now := step * DT
		finished_at = now
		state.fog.rebuild(entities.get_children())
		if step % 4 == 0:
			if symmetry_trace and symmetry_reports < 3:
				var diff := _symmetry_diff(entities)
				if diff != "":
					print("AI DUEL SYMMETRY %.2fs: %s" % [now, diff])
					symmetry_reports += 1
			if symmetry_trace and now >= 55.0 and now <= 110.0:
				print("AI DUEL UNITS %.2fs: team0 %s | team1 %s" % [now, JSON.stringify(_unit_trace(entities, 0)), JSON.stringify(_unit_trace(entities, 1))])
			if symmetry_trace:
				# Structural divergence: stockpiles, unit/building counts, TC health.
				var rows := _summary(state, entities)
				var shape0 := _team_shape(entities, 0)
				var shape1 := _team_shape(entities, 1)
				if (rows[0]["resources"] != rows[1]["resources"] or shape0 != shape1 or rows[0]["tc_hp"] != rows[1]["tc_hp"]) and (shape_reports < 40 or step % 240 == 0):
					print("AI DUEL SHAPE %.2fs: team0 %s %s | team1 %s %s" % [now, JSON.stringify(rows[0]["resources"]), JSON.stringify(shape0), JSON.stringify(rows[1]["resources"]), JSON.stringify(shape1)])
					shape_reports += 1
			# Simultaneous turns: both teams observe the same state before either
			# team's commands run, and the commands are interleaved with the lead
			# alternating each decision tick, so neither side always acts first.
			var lead := int(step / 4.0) % 2
			var turn_order := [lead, 1 - lead]
			var deliveries := {}
			var payloads := {}
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
				deliveries[team] = delivery
				payloads[team] = payload
			var queues := {0: [], 1: []}
			for team in turn_order:
				var before := Time.get_ticks_usec()
				var response: Dictionary = await clients[team].post_multi_agent_tick(payloads[team])
				stats[team]["max_http_ms"] = maxf(stats[team]["max_http_ms"], float(Time.get_ticks_usec() - before) / 1000.0)
				if response.is_empty():
					failed = "team %d HTTP failed: %s" % [team, clients[team].last_error]
					break
				stats[team]["calls"] += 1
				Events.acknowledge(subscribers[team], deliveries[team].to_seq)
				contexts[team].sim_time = now
				queues[team] = response.get("commands", [])
			if failed.is_empty():
				for index in maxi(queues[0].size(), queues[1].size()):
					for team in turn_order:
						if index >= queues[team].size(): continue
						var cmd = queues[team][index]
						var result := Executor.execute(cmd, contexts[team])
						var event := {"type": "command_result", "command_id": cmd.command_id, "op": cmd.op,
							"ok": result.ok, "reason": result.reason, "command": cmd, "time_sec": now, "_visible_to": [team]}
						for key in ["created_entity_id", "created_entity_ids", "segment_count", "queue_id", "building_id"]:
							if result.has(key): event[key] = result[key]
						Events.push(event)
						if not result.ok:
							stats[team]["rejects"][result.reason] = stats[team]["rejects"].get(result.reason, 0) + 1
			if not failed.is_empty(): break
		var nav_service = world.get_node("NavService")
		nav_service._process(DT)
		# Fairness and determinism: resolve every queued path this step. The live
		# game spreads path requests over frames under a 2 ms wall-clock budget,
		# which serves whichever team queued first and depends on machine load.
		var flushes := 0
		while nav_service.nav != null and nav_service.nav.pending_count() > 0 and flushes < 256:
			nav_service._process(DT)
			flushes += 1
		# Alternate which entities act first within a step. Starting units are
		# ordered team 0 first, and when two units trade blows in the same step
		# the first one processed lands its hit first.
		var acting := entities.get_children()
		if step % 2 == 1: acting.reverse()
		for entity in acting:
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
