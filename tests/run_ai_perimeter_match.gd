extends SceneTree
## Real fog, finite stocks and queued construction through the Python v3 API.
const Observation := preload("res://scripts/ai_gateway/observation_builder.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Events := preload("res://scripts/ai_gateway/event_buffer.gd")
const Executor := preload("res://scripts/ai_gateway/command_executor.gd")
const ExecutionContext := preload("res://scripts/ai_gateway/command_execution_context.gd")
const DT := 0.25
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error("MULTI AGENT FAILED: " + message)

func add_record(data: Dictionary, kind: String, definition: String, pos: Vector2, team := "ai") -> void:
	var record: Dictionary = preload("res://scripts/world/map_catalog.gd").make_record(kind, definition, pos, team)
	record.id = "perimeter_%d" % data.entities.size()
	data.entities.append(record)

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var session := root.get_node("GameSession")
	var map: Dictionary = preload("res://scripts/world/map_data.gd").create(240, 240, "Closed perimeter E2E")
	add_record(map, "building", "town_center", Vector2(-40, 0))
	add_record(map, "building", "barracks", Vector2(-30, -8))
	# This construction exercise has no enemy TC: an unrelated early military
	# victory would correctly stop all Python roles before the perimeter closes.
	for i in 12: add_record(map, "unit", "villager", Vector2(-46 + (i % 4) * 3, 5 + (i / 4) * 3))
	add_record(map, "unit", "scout_cavalry", Vector2(-38, -10))
	for spec in [["food", Vector2(-50, 14)], ["wood", Vector2(-54, -12)], ["gold", Vector2(-26, 14)], ["stone", Vector2(-24, -14)]]:
		add_record(map, "resource", spec[0], spec[1])
		map.entities[-1].amount = 3500 if spec[0] == "food" else 10000
	session.match_ai_mode = "sandbox"
	session.match_map_data = map
	session.online_active = false
	session.player_civ_id = &"chinese"
	session.ai_civ_id = &"teutons"
	var world := load("res://scenes/match_2d.tscn").instantiate() as Node2D
	root.add_child(world)
	current_scene = world
	await process_frame
	await process_frame
	world.process_mode = Node.PROCESS_MODE_DISABLED
	var state: MatchState = world.get_node("Bootstrap").match_state
	var entities: Node2D = world.get_node("Entities")
	state.set_age(1, 1)
	state.population_cap[1] = 80
	state.resources[1] = {0: 1500, 1: 3000, 2: 1000, 3: 500}
	var client: Node = load("res://scripts/ai_gateway/http_ai_client.gd").new()
	root.add_child(client)
	var config: RefCounted = load("res://scripts/ai_gateway/ai_config.gd").new()
	config.use_local_embedded = false
	config.service_url = args[0]
	config.fast_timeout_sec = 10.0
	client.configure(config)
	var match_id := "perimeter-%d" % Time.get_ticks_usec()
	var started: Dictionary = await client.post_match_start({"match_id": match_id, "teams": [{"team": 1}]})
	check(started.get("ok") == true, "Python v3 match starts")
	var ctx := ExecutionContext.new()
	ctx.match_id = match_id
	ctx.team = Enums.Team.AI
	ctx.match_state = state
	ctx.entities = entities
	ctx.civ = load("res://data/civs/teutons.tres")
	ctx.session_epoch = "perimeter-test"
	ctx.require_session_epoch = true
	var subscriber := Events.subscribe()
	var deposits := {0: 0, 1: 0}
	var rejects := {}
	var ops := {}
	var plan: Dictionary = {}
	var first_closed := -1.0
	var repaired := false
	var broken_pos := Vector2.ZERO
	var fog_probes := 0
	var trained := 0
	var gates := 0
	for step in ceili(float(args[1]) / DT):
		var now := step * DT
		state.fog.rebuild(entities.get_children())
		if step % 8 == 0:
			Registry.sample_owned_state(entities, 1, now)
			var delivery := Events.peek(subscriber)
			var observation := Observation.build(state, entities, 1, 0, now)
			plan = observation.decision_context.get("defense_plan", {})
			if step == 0:
				check(not plan.get("closed", false), "unwalled base starts open")
				check(plan.get("missing_segments", 0) > 100, "full perimeter requires more than a short wall")
				check(not observation.decision_context.get("defense_scout_options", []).is_empty(), "real fog requires boundary exploration")
			var payload := {"model": "mock-role-planner", "messages": [], "tools": [], "metadata": {
				"protocol_version": 3, "match_id": match_id, "team": 1, "enemy_team": 0, "tick": step,
				"observation_seq": step, "time_sec": now, "profile_id": "teutons", "session_epoch": ctx.session_epoch,
				"event_delivery": delivery.duplicate()}, "observation": observation, "events": Events.for_team(delivery.events, 1, state.fog_enabled)}
			payload.metadata.event_delivery.erase("events")
			var response: Dictionary = await client.post_multi_agent_tick(payload)
			if response.is_empty():
				check(false, "Python tick failed: " + client.last_error)
				break
			Events.acknowledge(subscriber, delivery.to_seq)
			ctx.sim_time = now
			for cmd in response.get("commands", []):
				var result := Executor.execute(cmd, ctx)
				ops[cmd.op] = ops.get(cmd.op, 0) + 1
				if cmd.op == "move":
					var actor := Registry.resolve(int(cmd.unit_id)) as UnitAgent
					if actor != null and actor.def.id == &"villager": fog_probes += 1
				var feedback := {"type": "command_result", "command_id": cmd.command_id, "op": cmd.op, "ok": result.ok,
					"reason": result.reason, "command": cmd, "time_sec": now, "_visible_to": [1]}
				for key in ["created_entity_id", "created_entity_ids", "segment_count", "queue_id", "building_id"]:
					if result.has(key): feedback[key] = result[key]
				Events.push(feedback)
				if not result.ok: rejects[result.reason] = rejects.get(result.reason, 0) + 1
			if step % 240 == 0:
				var file := FileAccess.open(args[2], FileAccess.WRITE)
				file.store_string(JSON.stringify({"observation": observation, "response": response}, "\t"))
				print("MULTI AGENT %.0fs: perimeter=%s resources=%s probes=%d trained=%d rejects=%s status=%s" % [now, plan, state.resources[1], fog_probes, trained, rejects, response.get("agent_status", {}).get("defense", {})])
			if plan.get("closed", false):
				if first_closed < 0:
					first_closed = now
					for entity in entities.get_children():
						if entity is BuildingAgent and entity.team == 1 and entity.def.id == &"palisade_wall" and entity.is_complete:
							broken_pos = entity.sim_pos
							entity.take_damage(100000)
							break
				elif now > first_closed + 4:
					repaired = true
					break
		var before: Dictionary = state.resources[1].duplicate()
		world.get_node("NavService")._process(DT)
		for entity in entities.get_children():
			if entity.is_queued_for_deletion(): continue
			if entity is BuildingAgent: entity._process(DT)
			if entity is UnitAgent or entity is BuildingAgent or entity is ProjectileAgent: entity._physics_process(DT)
		for resource in deposits: deposits[resource] += maxi(0, state.get_resource(1, resource) - int(before[resource]))
		state.age_progression._process(DT)
		state.technology_progression._process(DT)
		world.get_node("LandSupport")._process(DT)
		trained = 0
		gates = 0
		for entity in entities.get_children():
			if entity is UnitAgent and entity.team == 1 and entity.def.id != &"villager" and entity.def.id != &"scout_cavalry": trained += 1
			if entity is BuildingAgent and entity.team == 1 and "gate" in String(entity.def.id) and entity.is_complete: gates += 1
		await process_frame
	check(first_closed >= 0, "Python decisions and actual builders complete a closed perimeter")
	check(plan.get("complete_segments", 0) >= 100 and plan.get("missing_segments", -1) == 0, "every planned wall or gate is complete")
	check(gates >= 4, "four completed gates preserve base access")
	check(fog_probes > 0, "builder actually explores hidden perimeter")
	check(trained > 0, "paid military training continues during enclosure")
	check(deposits[0] > 100 and deposits[1] > 100, "food and wood deposits continue during enclosure")
	check(repaired and broken_pos != Vector2.ZERO, "destroyed section is actually rebuilt and closes the perimeter")
	check(rejects.is_empty(), "AI commands pass actual game validation: %s" % rejects)
	print("MULTI AGENT RESULT: closed_at=%.1f repaired=%s plan=%s gates=%d deposits=%s commands=%s" % [first_closed, repaired, plan, gates, deposits, ops])
	await client.post_match_end({"match_id": match_id})
	Events.unsubscribe(subscriber)
	client.free()
	state.frozen = true
	world.free()
	current_scene = null
	print("MULTI AGENT MATCH: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
