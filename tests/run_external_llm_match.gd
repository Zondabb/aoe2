extends SceneTree
## Real fogged game simulation driven through the external Python LLM service.
## tools/test_external_llm_e2e.py supplies a local mock upstream, never a paid API.

const Observation := preload("res://scripts/ai_gateway/observation_builder.gd")
const Prompt := preload("res://scripts/ai_gateway/prompt_assembler.gd")
const Parser := preload("res://scripts/ai_gateway/llm_response_parser.gd")
const Executor := preload("res://scripts/ai_gateway/command_executor.gd")
const ExecutionContext := preload("res://scripts/ai_gateway/command_execution_context.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")
const DT := 0.25
const REQUEST_EVERY_STEPS := 16
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("Expected temporary AI service URL; run tools/test_external_llm_e2e.py")
		quit(1)
		return
	var duration := float(args[1]) if args.size() > 1 else 900.0
	var observation_path := args[2] if args.size() > 2 else ""
	UnitDebugFocus.set_spectator_mode(true)
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
	world.process_mode = Node.PROCESS_MODE_DISABLED
	var state: MatchState = world.get_node("Bootstrap").match_state
	var entities: Node2D = world.get_node("Entities")
	var nav: Node = world.get_node("NavService")
	var support: Node = world.get_node("LandSupport")
	var client: Node = load("res://scripts/ai_gateway/http_ai_client.gd").new()
	root.add_child(client)
	var config: RefCounted = load("res://scripts/ai_gateway/ai_config.gd").new()
	config.use_local_embedded = false
	config.service_url = args[0]
	config.protocol = "v2_chat"
	config.backend = "openai"
	# Fixed-FPS frames advance HTTPRequest's simulated timeout while awaiting
	# the real OS network. The Python harness enforces the wall-clock deadline.
	config.timeout_sec = 3600000.0
	client.configure(config)
	var health: Dictionary = await client.get_health()
	check(health.get("ok") == true, "real external Python HTTP service is reachable")
	if health.get("ok") != true:
		client.free()
		world.free()
		quit(1)
		return
	var match_id := "external-llm-e2e"
	await client.post_match_start({"match_id": match_id, "teams": [{"team": 1, "enemy_team": 0, "profile_id": "teutons"}]})
	var execution := ExecutionContext.new()
	execution.match_id = match_id
	execution.match_state = state
	execution.entities = entities
	execution.team = Enums.Team.AI
	execution.civ = load("res://data/civs/teutons.tres")
	state.fog.rebuild(entities.get_children())
	var initial := Observation.build(state, entities, 1, 0, 0.0)
	check(state.fog_enabled and initial.derived.enemy_tc_id == -1, "enemy starts hidden behind actual fog")
	check(state.resources[1] == {0:200, 1:200, 2:100, 3:200}, "uses normal finite resources without grants")
	check(world.get_node_or_null("AiGateway") == null, "fixture has no embedded rules director")
	var initial_ids := {}
	var own_base := Vector2.ZERO
	var enemy_base := Vector2.ZERO
	var enemy_initial_hp := 0.0
	for entity in entities.get_children():
		if entity is UnitAgent:
			initial_ids[entity.get_instance_id()] = true
		elif entity is BuildingAgent and entity.def.id == &"town_center":
			if entity.team == 1: own_base = entity.sim_pos
			else:
				enemy_base = entity.sim_pos
				enemy_initial_hp = entity.hp
	# A real command rejection is returned to the next LLM request, rather than
	# relying on a fabricated error string or bypassing the production validator.
	var invalid := {"command_id":"test_rejected_missing_unit", "op":"move", "unit_id":2147480000, "pos":[0,0]}
	var invalid_result := Executor.execute(invalid, execution)
	check(not invalid_result.ok, "game executor rejects unavailable unit control")
	var feedback: Array = [{"seq":1,"type":"command_result","command_id":invalid.command_id,"op":"move","ok":false,"reason":invalid_result.reason,"command":invalid}]
	var completed := {}
	var produced := {}
	var outgoing := {}
	var discovered := {}
	var deposits := {0:0, 1:0, 2:0, 3:0}
	var rejected := {}
	var enemy_seen := false
	var first_damage := -1.0
	var first_soldier := -1.0
	var first_sortie := -1.0
	var max_mustered := 0
	var max_rallied := 0
	var premature_sorties := {}
	var active_stance := "develop"
	var rally_point := own_base
	var transmitted := 0
	var leaking_strategy := false
	var event_seq := 1
	for step in ceili(duration / DT):
		var now := step * DT
		state.fog.rebuild(entities.get_children())
		if step % REQUEST_EVERY_STEPS == 0:
			var observation := Observation.build(state, entities, 1, 0, now)
			if not observation_path.is_empty() and step % 240 == 0:
				var capture := FileAccess.open(observation_path, FileAccess.WRITE)
				if capture != null:
					capture.store_string(JSON.stringify(observation, "\t"))
			rally_point = Vector2.ZERO
			var rally: Array = observation.get("decision_context", {}).get("army", {}).get("rally_point", [own_base.x,own_base.y])
			rally_point = Vector2(float(rally[0]), float(rally[1]))
			enemy_seen = enemy_seen or observation.derived.enemy_tc_id >= 0
			for record in observation.entities:
				if record.kind == "resource": discovered[record.resource_type] = true
			var request := Prompt.assemble(observation, feedback, {"match_id":match_id,"team":1,"enemy_team":0,"profile_id":"teutons","tick":step,"time_sec":now,"backend":"openai","model":"mock-strategist"})
			feedback = []
			var response: Dictionary = await client.post_chat_completions(request, false)
			if response.is_empty():
				check(false, "external LLM HTTP request failed: %s" % client.last_error)
				break
			transmitted += 1
			for choice in response.get("choices", []):
				var calls: Variant = choice.get("message", {}).get("tool_calls", [])
				if calls is Array:
					for call in calls:
						leaking_strategy = leaking_strategy or call.get("function", {}).get("name") == "set_strategy"
			for record in response.get("debug", []):
				if record.get("category") == "LLM_PLAN":
					var plan: Variant = JSON.parse_string(record.get("message", "{}"))
					if plan is Dictionary: active_stance = plan.get("stance", active_stance)
			for command in Parser.parse(response, step):
				var result := Executor.execute(command, execution)
				event_seq += 1
				feedback.append({"seq":event_seq,"type":"command_result","command_id":command.command_id,"op":command.op,"ok":result.ok,"reason":result.reason,"command":command})
				if not result.ok: rejected[result.reason] = int(rejected.get(result.reason, 0)) + 1
			if step == 0:
				var balances: Dictionary = state.resources[1].duplicate()
				var reserved: int = state.population_reserved.get(1, 0)
				var repeated: Dictionary = await client.post_chat_completions(request, false)
				check(repeated.get("choices") == response.get("choices"), "same-tick HTTP retry returns the same compiled command IDs")
				var replay_safe := true
				for command in Parser.parse(repeated, step):
					var replay := Executor.execute(command, execution)
					replay_safe = replay_safe and replay.ok and replay.reason == "duplicate_skipped"
				check(replay_safe and state.resources[1] == balances and state.population_reserved.get(1, 0) == reserved, "HTTP replay cannot buy foundations or reserve population twice")
		var before: Dictionary = state.resources[1].duplicate()
		nav._process(DT)
		for entity in entities.get_children():
			if entity.is_queued_for_deletion(): continue
			if entity is UnitAgent or entity is BuildingAgent or entity is ProjectileAgent:
				entity._physics_process(DT)
		for type in deposits:
			deposits[type] += maxi(0, state.get_resource(1, type) - int(before[type]))
		state.age_progression._process(DT)
		state.technology_progression._process(DT)
		support._process(DT)
		var mustered := 0
		var rallied := 0
		for entity in entities.get_children():
			if entity.is_queued_for_deletion(): continue
			if entity is BuildingAgent:
				if entity.team == 1 and entity.is_complete: completed[String(entity.def.id)] = true
				if entity.team == 0 and entity.def.id == &"town_center" and entity.hp < enemy_initial_hp and first_damage < 0: first_damage = now
			elif entity is UnitAgent and entity.team == 1 and entity.def.id != &"villager" and not initial_ids.has(entity.get_instance_id()):
				produced[entity.get_instance_id()] = String(entity.def.id)
				if first_soldier < 0: first_soldier = now
				if entity.sim_pos.distance_to(own_base) < 45.0: mustered += 1
				if active_stance == "muster" and entity.sim_pos.distance_to(rally_point) < 12.0: rallied += 1
				if entity.sim_pos.distance_to(own_base) > 55.0 and entity.sim_pos.distance_to(enemy_base) < own_base.distance_to(enemy_base) - 55.0:
					outgoing[entity.get_instance_id()] = true
					if active_stance != "attack": premature_sorties[entity.get_instance_id()] = true
					if first_sortie < 0: first_sortie = now
		max_mustered = maxi(max_mustered, mustered)
		max_rallied = maxi(max_rallied, rallied)
		if step % 240 == 0:
			print("EXTERNAL LLM %.0fs: resources=%s buildings=%s soldiers=%d mustered=%d sorties=%d seen_enemy=%s rejects=%s" % [now,state.resources[1],completed.keys(),produced.size(),mustered,outgoing.size(),enemy_seen,rejected])
		await process_frame
		if state.winner != -1: break
	check(transmitted >= 20, "gameplay was driven by repeated real HTTP LLM completions")
	check(not leaking_strategy, "server expands strategic tools to primitive game commands")
	check(deposits[0] > 100 and deposits[1] > 100, "LLM-controlled workers gather food and wood through real deposits")
	check(discovered.has("FOOD") and discovered.has("WOOD"), "LLM scouting reveals economic resources")
	check(completed.has("barracks"), "villagers complete a new barracks")
	check(produced.size() >= 4, "barracks trains at least four new soldiers (%d)" % produced.size())
	check(max_mustered >= 3, "at least three trained soldiers gather near the base (%d)" % max_mustered)
	check(max_rallied >= 3, "muster strategy gathers three soldiers at the actual rally point (%d)" % max_rallied)
	check(premature_sorties.is_empty(), "muster holds trained troops until model selects attack")
	check(outgoing.size() >= 3, "at least three trained soldiers leave base toward opponent (%d)" % outgoing.size())
	check(enemy_seen, "external AI discovers hidden enemy town center")
	check(first_damage >= 0, "trained external AI army reaches and damages enemy town center")
	check(state.resources[1].values().all(func(value): return value >= 0), "command batches preserve nonnegative finite resource balances")
	check(state.age_of(0) == Enums.Age.DARK, "external AI does not control opponent progression")
	check(rejected.is_empty(), "generated commands pass production game validation: %s" % rejected)
	for entity in entities.get_children():
		if entity is UnitAgent and entity.team == 1:
			check(Catalog.civilization_allows(Catalog.unit_record(entity.def.id), &"teutons"), "trained %s is civilization legal" % entity.def.id)
	print("EXTERNAL LLM RESULT: soldier=%.1fs sortie=%.1fs damage=%.1fs deposits=%s trained=%s" % [first_soldier,first_sortie,first_damage,deposits,produced.values()])
	await client.post_match_end({"match_id":match_id})
	client.free()
	state.frozen = true
	world.free()
	current_scene = null
	print("EXTERNAL LLM MATCH: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
