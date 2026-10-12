extends SceneTree
## End-to-end strategy regression on the default fogged map. All starting
## currency, resource deposits, construction, research, and training are real.
## Run with --headless --fixed-fps 60 --script res://tests/run_ai_strategy_match.gd.
## Optional user args: -- chinese direct 900 (civilization, backend, seconds).

const Director := preload("res://scripts/systems/ai/ai_director.gd")
const Adapter := preload("res://scripts/ai_gateway/ai_service_adapter.gd")
const Observation := preload("res://scripts/ai_gateway/observation_builder.gd")
const Executor := preload("res://scripts/ai_gateway/command_executor.gd")
const ExecutionContext := preload("res://scripts/ai_gateway/command_execution_context.gd")
const DecisionLog := preload("res://scripts/systems/ai/ai_decision_log.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")
const DT := 0.25
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
	UnitDebugFocus.set_spectator_mode(true)
	var args := OS.get_cmdline_user_args()
	if args.size() >= 2:
		await _run_match(StringName(args[0]), args[1], float(args[2]) if args.size() > 2 else 900.0)
	else:
		await _run_match(&"chinese", "direct", 900.0)
		await _run_match(&"teutons", "adapter", 900.0)
	check(checks >= 20, "strategy scenario completes its gameplay assertions")
	print("AI STRATEGY MATCH: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _run_match(civilization: StringName, backend: String, duration: float) -> void:
	var label := "%s/%s" % [civilization, backend]
	var session := root.get_node("GameSession")
	session.match_ai_mode = "sandbox"
	session.match_map_data = {}
	session.online_active = false
	session.player_civ_id = &"teutons" if civilization == &"chinese" else &"chinese"
	session.ai_civ_id = civilization
	var world := load("res://scenes/match_2d.tscn").instantiate() as Node2D
	root.add_child(world)
	current_scene = world
	await process_frame
	await process_frame
	# Disabled tree processing makes each explicit step the sole authority, even
	# when enqueue_train re-enables a building or a new unit/projectile is spawned.
	world.process_mode = Node.PROCESS_MODE_DISABLED
	var state: MatchState = world.get_node("Bootstrap").match_state
	var entities: Node2D = world.get_node("Entities")
	var nav: Node = world.get_node("NavService")
	var support: Node = world.get_node("LandSupport")
	var civ: CivDef = load("res://data/civs/%s.tres" % civilization)
	var log := DecisionLog.new()
	log.enabled = false
	var director := Director.new()
	world.add_child(director)
	director.setup(state, entities, civ, Enums.Team.AI, Enums.Team.PLAYER, label, log, false)
	var adapter := Adapter.new()
	adapter.configure(state, entities, log)
	var client: Node
	if backend == "python":
		client = load("res://scripts/ai_gateway/http_ai_client.gd").new()
		root.add_child(client)
		var config: RefCounted = load("res://scripts/ai_gateway/ai_config.gd").new()
		config.use_local_embedded = false
		config.service_url = "http://127.0.0.1:9876"
		# Fixed-FPS frames advance simulated timeout time much faster than HTTP.
		config.timeout_sec = 120.0
		client.configure(config)
		var health: Dictionary = await client.get_health()
		check(health.get("ok") == true, "%s connects to the Python rules service" % label)
		if health.get("ok") != true:
			client.free()
			world.free()
			current_scene = null
			return
		await client.post_match_start({"protocol_version": 1, "match_id": label, "teams": [{"team": 1, "enemy_team": 0, "profile_id": String(civilization), "team_label": label}]})
	var execution := ExecutionContext.new()
	execution.match_id = label
	execution.match_state = state
	execution.entities = entities
	execution.team = Enums.Team.AI
	execution.civ = civ
	var initial := Observation.build(state, entities, Enums.Team.AI, Enums.Team.PLAYER, 0.0)
	check(state.fog_enabled and state.age_of(Enums.Team.AI) == Enums.Age.DARK, "%s starts in Dark Age with fog" % label)
	check(initial.derived.enemy_tc_id == -1, "%s opponent starts hidden" % label)
	check(state.resources[Enums.Team.AI] == {0: 200, 1: 200, 2: 100, 3: 200}, "%s uses normal finite starting resources" % label)
	check(world.get_node_or_null("AiGateway") == null, "%s fixture does not contact an external service" % label)
	var initial_ids := {}
	var own_base := Vector2.ZERO
	var enemy_base := Vector2.ZERO
	var enemy_initial_hp := 0.0
	for entity in entities.get_children():
		if entity is UnitAgent:
			initial_ids[entity.get_instance_id()] = true
		elif entity is BuildingAgent and entity.def.id == &"town_center":
			if entity.team == Enums.Team.AI: own_base = entity.sim_pos
			else:
				enemy_base = entity.sim_pos
				enemy_initial_hp = entity.hp
	var produced := {}
	var completed := {}
	var deposits := {0: 0, 1: 0, 2: 0, 3: 0}
	var discovered := {}
	var outgoing := {}
	var first_soldier := -1.0
	var first_sortie := -1.0
	var first_damage := -1.0
	var enemy_seen := false
	var rejected := {}
	var ages: Array[int] = []
	state.age_changed.connect(func(team: int, age: int):
		if team == Enums.Team.AI: ages.append(age)
	)
	for step in ceili(duration / DT):
		var now := step * DT
		state.fog.rebuild(entities.get_children())
		if step % 2 == 0:
			var observation := Observation.build(state, entities, Enums.Team.AI, Enums.Team.PLAYER, now)
			enemy_seen = enemy_seen or int(observation.derived.enemy_tc_id) >= 0
			for record in observation.entities:
				if record.kind == "resource": discovered[record.resource_type] = true
			if backend in ["adapter", "python"]:
				var request := {"match_id": label, "team": Enums.Team.AI, "enemy_team": Enums.Team.PLAYER, "profile_id": String(civilization), "tick": step, "time_sec": now, "observation": observation}
				var response: Dictionary
				if backend == "python":
					response = await client.post_tick(request, false)
					if response.is_empty():
						check(false, "%s Python tick failed: %s" % [label, client.last_error])
						break
				else:
					response = adapter.handle_tick(request)
				for command in response.get("commands", []):
					var result := Executor.execute(command, execution)
					if not result.ok: rejected[result.reason] = int(rejected.get(result.reason, 0)) + 1
			else:
				director.match_time = now
				director.evaluate()
		# Currency increases here can only come from the actual workers' deposits.
		var before: Dictionary = state.resources[Enums.Team.AI].duplicate()
		nav._process(DT)
		for entity in entities.get_children():
			if entity.is_queued_for_deletion(): continue
			if entity is UnitAgent or entity is BuildingAgent or entity is ProjectileAgent:
				entity._physics_process(DT)
		for type in deposits:
			deposits[type] += maxi(0, state.get_resource(Enums.Team.AI, type) - int(before[type]))
		state.age_progression._process(DT)
		state.technology_progression._process(DT)
		support._process(DT)
		for entity in entities.get_children():
			if entity.is_queued_for_deletion(): continue
			if entity is BuildingAgent:
				if entity.team == Enums.Team.AI and entity.is_complete: completed[String(entity.def.id)] = true
				if entity.team == Enums.Team.PLAYER and entity.def.id == &"town_center" and entity.hp < enemy_initial_hp and first_damage < 0: first_damage = now
			elif entity is UnitAgent and entity.team == Enums.Team.AI and entity.def.id != &"villager" and not initial_ids.has(entity.get_instance_id()):
				produced[entity.get_instance_id()] = String(entity.def.id)
				if first_soldier < 0: first_soldier = now
				# Require trained troops to leave the base toward the hostile half.
				if entity.sim_pos.distance_to(own_base) > 55.0 and entity.sim_pos.distance_to(enemy_base) < own_base.distance_to(enemy_base) - 55.0:
					outgoing[entity.get_instance_id()] = true
					if first_sortie < 0: first_sortie = now
		if step % 240 == 0:
			print("STRATEGY %s %.0fs: age=%d resources=%s buildings=%s soldiers=%d sorties=%d deposits=%s rejects=%s" % [label, now, state.age_of(Enums.Team.AI), state.resources[Enums.Team.AI], completed.keys(), produced.size(), outgoing.size(), deposits, rejected])
		# Let path invalidation, deferred spawns and entity deletion settle every
		# step. --fixed-fps makes these frames run without wall-clock throttling.
		await process_frame
		if state.winner != -1: break
	check(deposits[0] > 100 and deposits[1] > 100, "%s economy deposits food and wood without grants" % label)
	check(discovered.has("FOOD") and discovered.has("WOOD"), "%s discovers economic resources through fog" % label)
	check(completed.has("barracks"), "%s villagers finish a military production building" % label)
	check(produced.size() >= 4, "%s trains at least four new soldiers (%d)" % [label, produced.size()])
	check(outgoing.size() >= 3, "%s at least three trained soldiers advance toward the opponent (%d)" % [label, outgoing.size()])
	check(enemy_seen, "%s scouts discover the enemy through fog" % label)
	check(first_damage >= 0, "%s army reaches and damages the enemy town center" % label)
	check(ages.has(Enums.Age.FEUDAL), "%s advances to Feudal using gathered resources" % label)
	check(state.age_of(Enums.Team.PLAYER) == Enums.Age.DARK, "%s does not advance the opponent's age" % label)
	check(state.resources[Enums.Team.AI].values().all(func(value): return value >= 0), "%s does not overspend finite resources" % label)
	check(rejected.is_empty(), "%s captured orders pass the production command validator: %s" % [label, rejected])
	for entity in entities.get_children():
		if entity is UnitAgent and entity.team == Enums.Team.AI:
			check(Catalog.civilization_allows(Catalog.unit_record(entity.def.id), civilization), "%s unit %s belongs to its civilization" % [label, entity.def.id])
	print("STRATEGY RESULT %s: first_soldier=%.1fs first_sortie=%.1fs first_tc_damage=%.1fs enemy_seen=%s ages=%s trained=%s deposits=%s rejects=%s" % [label, first_soldier, first_sortie, first_damage, enemy_seen, ages, produced.values(), deposits, rejected])
	var captured_directors: Array = adapter._directors.values()
	adapter.handle_match_end({"match_id": label})
	for captured_director in captured_directors: captured_director.free()
	if client != null:
		await client.post_match_end({"match_id": label})
		client.free()
	state.frozen = true
	world.free()
	current_scene = null
	await process_frame
