extends SceneTree

const Observation := preload("res://scripts/ai_gateway/observation_builder.gd")
const Prompt := preload("res://scripts/ai_gateway/prompt_assembler.gd")
const Tools := preload("res://scripts/ai_gateway/ai_tool_catalog.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Context := preload("res://scripts/ai_gateway/command_execution_context.gd")
const Validator := preload("res://scripts/ai_gateway/command_validator.gd")
const Executor := preload("res://scripts/ai_gateway/command_executor.gd")
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
	var session := root.get_node("GameSession")
	session.match_map_data = {}
	session.match_ai_mode = "sandbox"
	session.player_civ_id = &"chinese"
	session.ai_civ_id = &"teutons"
	var world := load("res://scenes/match_2d.tscn").instantiate() as Node2D
	root.add_child(world)
	await process_frame
	await process_frame
	var state: MatchState = world.get_node("Bootstrap").match_state
	var entities: Node2D = world.get_node("Entities")
	for node in entities.get_children(): node.set_physics_process(false)
	state.fog.rebuild(entities.get_children())
	var started := Time.get_ticks_usec()
	var observation := Observation.build_json_safe(state, entities, 1, 0, 0)
	print("EXTERNAL CONTEXT BUILD %.2f ms" % ((Time.get_ticks_usec() - started) / 1000.0))
	var decision: Dictionary = observation.decision_context
	check(observation.team == 1, "observation explicitly identifies issuing team")
	check(observation.derived.enemy_tc_id == -1, "hidden enemy town center is not disclosed")
	check(observation.entities.filter(func(e): return e.kind == "resource").is_empty(), "initial distant deposits stay hidden")
	check(not decision.scouting.frontiers.is_empty(), "fog frontier provides an autonomous scout destination")
	check(decision.scouting.frontiers.size() <= 12, "frontier context remains bounded")
	check(decision.scouting.explored_ratio > 0 and decision.scouting.explored_ratio < 1, "exploration ratio uses own history")
	check(not decision.scouting.scout_ids.is_empty(), "initial scout is available without hijacking working villagers")
	check(decision.scouting.probes.size() == 2, "public map center and opposing sector can be explored without hidden enemy coordinates")
	for frontier: Dictionary in decision.scouting.frontiers:
		check(frontier.pos.size() == 2 and state.map_bounds.has_point(Vector2(frontier.pos[0], frontier.pos[1])), "scout waypoint uses a bounded two dimensional coordinate")
	var barracks: Array = decision.catalog.buildings.filter(func(b): return b.id == "barracks")
	check(barracks.size() == 1 and barracks[0].cost.wood == Catalog.get_building(&"barracks").cost_wood, "barracks cost comes from actual game catalog")
	var militia: Array = decision.catalog.units.filter(func(u): return u.id == "militia")
	check(militia.size() == 1 and militia[0].cost.food == Catalog.get_unit(&"militia").cost_food and militia[0].train_at == "barracks", "unit price and producer are real catalog definitions")
	check(decision.catalog.age_upgrade.target_age == 1 and decision.catalog.age_upgrade.required_distinct_buildings == 2, "age plan includes the game's actual building prerequisites")
	check(decision.army.visible_enemy_ids.is_empty(), "army metrics cannot read hidden armies")
	check(decision.army.rally_point.size() == 2, "army has a usable gathering coordinate")
	var hidden_enemy: Node2D
	for node in entities.get_children():
		if node.get("team") == 0 and node.get("def") is BuildingDef and node.get("def").id == &"town_center": hidden_enemy = node
	var saved_position: Vector2 = hidden_enemy.get("sim_pos")
	var before := JSON.stringify(decision)
	hidden_enemy.set("sim_pos", saved_position + Vector2(30, 15))
	var changed := Observation.build_json_safe(state, entities, 1, 0, 0)
	check(JSON.stringify(changed.decision_context) == before, "moving an unseen opponent changes no planning hints")
	hidden_enemy.set("sim_pos", saved_position)
	var ctx := Context.new()
	ctx.match_state = state
	ctx.entities = entities
	ctx.team = 1
	ctx.civ = load("res://data/civs/teutons.tres")
	var options: Array = decision.construction_options.filter(func(option): return option.building_def_id == "barracks")
	check(not options.is_empty(), "starting villagers have visible and reachable barracks sites")
	for option: Dictionary in options:
		var position := Vector2(option.pos[0], option.pos[1])
		check(state.fog.footprint_visible(1, position, Catalog.get_building(&"barracks").footprint, true), "suggested construction footprint is entirely visible")
		var command := option.duplicate()
		command.op = "place_building"
		check(Validator.validate(command, ctx).ok, "construction hint passes the authoritative command validator")
	if not options.is_empty():
		var delivering := Registry.resolve(int(options[0].builder_id))
		delivering.set("carry_amount", 10)
		delivering.set("carry_type", Enums.ResourceType.WOOD)
		delivering.set("order", Enums.OrderType.GATHER)
		delivering.set("_gather_state", "to_drop_off")
		delivering.set("_gather_resource_type", Enums.ResourceType.WOOD)
		var delivery_observation := Observation.build_json_safe(state, entities, 1, 0, 1)
		check(delivery_observation.decision_context.construction_options.all(func(option): return option.builder_id != Registry.id_of(delivering)), "construction pairs never interrupt a worker delivering resources")
		var delivery_unit: Array = delivery_observation.entities.filter(func(e): return e.id == Registry.id_of(delivering))
		check(delivery_unit[0].gather_resource_type == "WOOD", "own economic assignment remains explicit during delivery without disclosing hidden resource IDs")
		delivering.set("carry_amount", 0)
		delivering.set("carry_type", -1)
		delivering.set("order", Enums.OrderType.NONE)
		delivering.set("_gather_state", "")
		delivering.set("_gather_resource_type", -1)
	var town_center := Registry.resolve(int(observation.derived.own_tc_id))
	check(town_center.enqueue_train(Catalog.get_unit(&"villager")), "real production can be queued")
	var after := Observation.build_json_safe(state, entities, 1, 0, 2)
	var tc_records: Array = after.entities.filter(func(e): return e.id == Registry.id_of(town_center))
	check(tc_records[0].train_queue == ["villager"] and not tc_records[0].train_queue_empty, "production queue is explicit and prevents duplicate orders")
	check(tc_records[0].trainable.has("villager") and tc_records[0].has("train_blocked_reasons"), "producer capabilities and current rejection conditions are present")
	var scout := Registry.resolve(int(decision.scouting.scout_ids[0]))
	var goal: Array = decision.scouting.frontiers[0].pos
	scout.command_move(Vector2(goal[0], goal[1]))
	after = Observation.build_json_safe(state, entities, 1, 0, 2)
	var scout_record: Array = after.entities.filter(func(e): return e.id == Registry.id_of(scout))
	check(scout_record[0].move_goal == goal, "requested move goal is available for persistent scouting and deduplication")
	var dead: Node2D
	for node in entities.get_children():
		if node.get("team") == 1 and node.get("def") is UnitDef and node != scout:
			dead = node
			break
	dead.set("hp", 0)
	after = Observation.build_json_safe(state, entities, 1, 0, 3)
	check(after.entities.all(func(e): return e.id != Registry.id_of(dead)), "dead own actors cannot appear as actionable entities")
	# Visible enemy art does not reveal the opponent's private production/orders.
	hidden_enemy.set("sim_pos", town_center.get("sim_pos") + Vector2(10, 0))
	hidden_enemy.set("train_queue", [Catalog.get_unit(&"villager")] as Array[UnitDef])
	var enemy_unit: Node2D
	for node in entities.get_children():
		if node.get("team") == 0 and node.get("def") is UnitDef:
			enemy_unit = node
			break
	enemy_unit.set("sim_pos", town_center.get("sim_pos") + Vector2(12, 0))
	enemy_unit.command_move(town_center.get("sim_pos") + Vector2(30, 30))
	state.fog.rebuild(entities.get_children())
	after = Observation.build_json_safe(state, entities, 1, 0, 3)
	var seen_enemy: Array = after.entities.filter(func(e): return e.id == Registry.id_of(hidden_enemy))
	check(seen_enemy.size() == 1 and not seen_enemy[0].has("train_queue") and not seen_enemy[0].has("trainable"), "seeing an enemy building does not expose its private production queue")
	var seen_enemy_unit: Array = after.entities.filter(func(e): return e.id == Registry.id_of(enemy_unit))
	check(seen_enemy_unit.size() == 1 and not seen_enemy_unit[0].has("move_goal"), "enemy movement endpoints remain private")
	check(after.derived.threat_near_base and after.decision_context.army.enemy_near_base_ids.has(Registry.id_of(enemy_unit)), "defense context is correct even when enemy actors precede own town center")
	scout.set("hp", 0)
	var replacement := load("res://scenes/entities/unit_view.tscn").instantiate() as Node2D
	replacement.set("def", Catalog.get_unit(&"militia"))
	replacement.set("team", 1)
	replacement.set("civ", ctx.civ)
	replacement.set("match_state", state)
	replacement.set("sim_pos", town_center.get("sim_pos") - Vector2(6, 0))
	entities.add_child(replacement)
	replacement.set_physics_process(false)
	state.fog.rebuild(entities.get_children())
	after = Observation.build_json_safe(state, entities, 1, 0, 4)
	check(not after.decision_context.scouting.frontiers.is_empty() and not after.decision_context.scouting.scout_ids.has(Registry.id_of(replacement)), "a surviving soldier can continue exploration without permanent exclusion from the army")
	var feedback := [{"type": "command_result", "command_id": "failed-build", "op": "place_building", "ok": false, "reason": "need_vision", "team": 1}]
	var payload := Prompt.assemble(after, feedback, {"team": 1, "enemy_team": 0, "tick": 2})
	var user := String(payload.messages[-1].content)
	check(not user.contains("阶段=经济"), "model is free to switch strategy phases")
	check(user.contains("need_vision") and user.contains("failed-build"), "prompt retains exact command feedback for replanning")
	check(user.contains("train_queue") and user.contains("frontiers") and user.contains("construction_options"), "LLM text contains the operational context rather than only economy")
	for tool: Dictionary in Tools.tools_payload():
		var parameters: Dictionary = tool.function.parameters
		check(parameters.required.size() == parameters.properties.size() and not parameters.additionalProperties, "tool schema enforces its actual arguments")
		if parameters.properties.has("pos"):
			check(parameters.properties.pos.minItems == 2 and parameters.properties.pos.maxItems == 2, "coordinate tools enforce exactly two dimensions")
	# Shared legacy suite remains v1 compatible.
	var legacy_failures: Array = load("res://tests/test_prompt_assembler.gd").new().run()
	check(legacy_failures.is_empty(), "legacy prompt/tool payload contract remains compatible: %s" % [legacy_failures])
	state.frozen = true
	world.free()
	for path in ["test_observation_builder", "test_observation_vision", "test_entity_registry", "test_command_validator", "test_command_executor", "test_ai_gateway_v2", "test_ai_gateway_integration", "test_ai_parity"]:
		var related_failures: Array = load("res://tests/%s.gd" % path).new().run()
		check(related_failures.is_empty(), "related legacy suite %s: %s" % [path, related_failures])
	print("EXTERNAL AI CONTEXT: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
