extends SceneTree

const Catalog := preload("res://scripts/data/game_catalog.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Events := preload("res://scripts/ai_gateway/event_buffer.gd")
const Observations := preload("res://scripts/ai_gateway/observation_builder.gd")
const Tools := preload("res://scripts/ai_gateway/ai_tool_catalog.gd")
const Context := preload("res://scripts/ai_gateway/command_execution_context.gd")
const Validator := preload("res://scripts/ai_gateway/command_validator.gd")
const Executor := preload("res://scripts/ai_gateway/command_executor.gd")
const AiArmyManagerScript := preload("res://scripts/systems/ai/ai_army_manager.gd")
const AiRunContextScript := preload("res://scripts/systems/ai/ai_run_context.gd")
const VisionServiceScript := preload("res://scripts/systems/vision_service.gd")
const FogServiceScript := preload("res://scripts/systems/fog_of_war_service.gd")
const AiBlackboardScript := preload("res://scripts/systems/ai/ai_blackboard.gd")
const NetworkMatchScript := preload("res://scripts/network/network_match.gd")
const UNIT := preload("res://scenes/entities/unit_view.tscn")
const BUILDING := preload("res://scenes/entities/building_view.tscn")
const CIV := preload("res://data/civs/chinese.tres")
const STEP := 1.0 / 30.0

var checks := 0
var failures: Array[String] = []
var container: Node2D
var entities: Node2D
var state: MatchState


func _initialize() -> void:
	call_deferred("_run")


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)


func _fixture(with_fog := false, with_vision := true) -> void:
	if is_instance_valid(container):
		container.free()
	Registry.clear()
	Events.clear()
	container = Node2D.new()
	container.name = "Match"
	root.add_child(container)
	entities = Node2D.new()
	entities.name = "Entities"
	container.add_child(entities)
	state = MatchState.new()
	state.setup_defaults()
	state.population_cap[0] = 100
	state.population_cap[1] = 100
	state.map_bounds = Rect2(-60, -60, 120, 120)
	state.fog_enabled = with_fog
	if with_fog:
		var fog := FogServiceScript.new()
		fog.setup_rect(state.map_bounds.position, state.map_bounds.end)
		state.fog = fog
	if with_vision:
		var vision_holder := Node.new()
		vision_holder.name = "VisionHolder"
		vision_holder.add_to_group("vision_service")
		var vision := VisionServiceScript.new()
		vision_holder.set_meta("vision", vision)
		container.add_child(vision_holder)


func _unit(id: StringName, at: Vector2, side := Enums.Team.PLAYER) -> UnitAgent:
	var entity := UNIT.instantiate() as UnitAgent
	entity.def = Catalog.get_unit(id)
	entity.team = side
	entity.civ = CIV
	entity.match_state = state
	entity.sim_pos = at
	entities.add_child(entity)
	if entity.hp <= 0.0 and entity.def != null:
		entity.hp = entity.def.max_hp
	entity.set_physics_process(false)
	Registry.register(entity)
	return entity


func _building(id: StringName, at: Vector2, side := Enums.Team.PLAYER) -> BuildingAgent:
	var entity := BUILDING.instantiate() as BuildingAgent
	entity.def = Catalog.get_building(id)
	entity.team = side
	entity.civ = CIV
	entity.match_state = state
	entity.sim_pos = at
	entities.add_child(entity)
	if entity.def != null:
		entity.hp = entity.def.max_hp
	entity.set_process(false)
	entity.set_physics_process(false)
	Registry.register(entity)
	var vision_holder := container.get_node_or_null("VisionHolder")
	if vision_holder != null and vision_holder.has_meta("vision"):
		(vision_holder.get_meta("vision") as VisionService).register(entity)
	return entity


func _ctx(team := 0) -> CommandExecutionContext:
	var ctx := Context.new()
	ctx.match_state = state
	ctx.entities = entities
	ctx.team = team
	ctx.civ = CIV
	ctx.sim_time = 10.0
	ctx.session_epoch = "1"
	ctx.require_session_epoch = true
	return ctx


func _test_auto_aggro() -> void:
	# 1. Idle melee unit automatically attacks nearby enemy unit.
	_fixture(false, true)
	var sword := _unit(&"militia", Vector2(0, 0), Enums.Team.PLAYER)
	var enemy := _unit(&"militia", Vector2(5, 0), Enums.Team.AI)
	sword._physics_process(STEP)
	check(sword.order == Enums.OrderType.ATTACK and sword.get("_attack_target") == enemy, "idle militia auto-attacks nearby visible enemy")

	# 2. Idle archer auto-attacks enemy unit at ranged distance.
	_fixture(false, true)
	var archer := _unit(&"archer", Vector2(0, 0), Enums.Team.PLAYER)
	var enemy_a := _unit(&"militia", Vector2(4.5, 0), Enums.Team.AI)
	archer._physics_process(STEP)
	check(archer.order == Enums.OrderType.ATTACK and archer.get("_attack_target") == enemy_a, "idle archer auto-attacks nearby enemy")

	# 3. Villager must NOT auto-aggro.
	_fixture(false, true)
	var vil := _unit(&"villager", Vector2(0, 0), Enums.Team.PLAYER)
	var _enemy_v := _unit(&"militia", Vector2(3, 0), Enums.Team.AI)
	vil._physics_process(STEP)
	check(vil.order == Enums.OrderType.NONE, "idle villager never auto-aggros enemies")

	# 4. Fog prevents auto-aggro on unseen enemy beyond vision.
	_fixture(true, true)
	var scout_sword := _unit(&"militia", Vector2(0, 0), Enums.Team.PLAYER)
	var unseen := _unit(&"militia", Vector2(30, 0), Enums.Team.AI)
	state.fog.rebuild(entities.get_children())
	check(not state.fog.can_see(Enums.Team.PLAYER, unseen), "test precondition: enemy outside fog sight")
	scout_sword._physics_process(STEP)
	check(scout_sword.order == Enums.OrderType.NONE, "idle militia does not auto-aggro unseen enemies through fog")

	# 5. Mangonel refuses friendly-fire auto-aggro when an ally stands in blast radius, then engages once clear.
	_fixture(false, true)
	var mango := _unit(&"mangonel", Vector2(0, 0), Enums.Team.PLAYER)
	var target_e := _unit(&"militia", Vector2(15, 0), Enums.Team.AI)
	var ally := _unit(&"militia", Vector2(15.3, 0.2), Enums.Team.PLAYER)
	mango._physics_process(STEP)
	check(mango.order == Enums.OrderType.NONE, "mangonel skips auto-aggro when ally is in splash zone")
	ally.queue_free()
	entities.remove_child(ally)
	mango._physics_process(STEP)
	check(mango.order == Enums.OrderType.ATTACK and mango.get("_attack_target") == target_e, "mangonel auto-attacks once blast zone is clear")

	# 6. Battering ram ignores lone enemy unit in auto-aggro and attacks nearby enemy building.
	_fixture(false, true)
	var ram := _unit(&"battering_ram", Vector2(0, 0), Enums.Team.PLAYER)
	var _enemy_inf := _unit(&"militia", Vector2(4, 0), Enums.Team.AI)
	ram._physics_process(STEP)
	check(ram.order == Enums.OrderType.NONE, "battering ram does not chase non-building units via auto-aggro")
	var enemy_bldg := _building(&"house", Vector2(5, 0), Enums.Team.AI)
	ram._physics_process(STEP)
	check(ram.order == Enums.OrderType.ATTACK and ram.get("_attack_target") == enemy_bldg, "battering ram auto-attacks nearby visible enemy building")

	# 7. Active MOVE keeps moving normally, hold suppresses stalled auto-aggro briefly, then stalled MOVE engages blocking enemy unit.
	_fixture(false, true)
	var mover := _unit(&"militia", Vector2(0, 0), Enums.Team.PLAYER)
	var side_enemy := _unit(&"militia", Vector2(4, 0), Enums.Team.AI)
	mover.command_move(Vector2(20, 0))
	mover.set("_no_progress_frames", 2)
	mover._physics_process(STEP)
	check(mover.order == Enums.OrderType.MOVE, "moving unit making progress ignores auto-aggro interruption")
	mover.set("_no_progress_frames", UnitAgent.STALLED_MOVE_AGGRO_FRAMES)
	mover._physics_process(STEP)
	check(mover.order == Enums.OrderType.MOVE, "post-move hold suppresses stalled-move auto-aggro immediately after command")
	mover.set("_auto_aggro_hold_units", 0)
	mover.set("_no_progress_frames", UnitAgent.STALLED_MOVE_AGGRO_FRAMES)
	mover._physics_process(STEP)
	check(mover.order == Enums.OrderType.ATTACK and mover.get("_attack_target") == side_enemy, "stalled moving unit engages blocking enemy unit once hold expires")

	# 8. Built-in AiArmyManager.rally_to_base preserves active ATTACK orders.
	_fixture(false, true)
	var fighter := _unit(&"militia", Vector2(2, 0), Enums.Team.AI)
	var target_p := _unit(&"militia", Vector2(5, 0), Enums.Team.PLAYER)
	fighter.command_attack(target_p)
	var army_mgr := AiArmyManagerScript.new()
	var ai_ctx := AiRunContextScript.new()
	ai_ctx.match_state = state
	ai_ctx.entities = entities
	ai_ctx.team = Enums.Team.AI
	ai_ctx.profile = CivAiProfile.new()
	ai_ctx.blackboard = AiBlackboardScript.new()
	ai_ctx.blackboard.own_tc_pos = Vector2(20, 20)
	ai_ctx.blackboard.team_units = [fighter]
	army_mgr.rally_to_base(ai_ctx, {})
	check(fighter.order == Enums.OrderType.ATTACK, "AiArmyManager.rally_to_base does not pull attacking units away")

	# 9. Nearby radius cap: idle militia ignores visible enemy beyond 6.0 melee auto-aggro radius, engages within 6.0.
	_fixture(false, true)
	var near_sword := _unit(&"militia", Vector2(0, 0), Enums.Team.PLAYER)
	var mid_enemy := _unit(&"militia", Vector2(10, 0), Enums.Team.AI)
	near_sword._physics_process(STEP)
	check(near_sword.order == Enums.OrderType.NONE, "idle militia ignores visible enemy outside nearby auto-aggro radius (10 > 6)")
	mid_enemy.sim_pos = Vector2(5, 0)
	mid_enemy._vision_sync_position()
	near_sword._physics_process(STEP)
	check(near_sword.order == Enums.OrderType.ATTACK and near_sword.get("_attack_target") == mid_enemy, "idle militia engages once enemy enters nearby 6.0 radius")

	# 10. Post-command 4s hold: stop/finish_move suppresses both auto-aggro and unit retaliation for 4s, then resumes auto-aggro.
	_fixture(false, true)
	var pulled := _unit(&"militia", Vector2(0, 0), Enums.Team.PLAYER)
	var nearby_foe := _unit(&"militia", Vector2(4, 0), Enums.Team.AI)
	pulled.command_move(Vector2(0, 0))
	pulled._finish_move()
	check(int(pulled.get("_auto_aggro_hold_units")) > 0, "_finish_move arms auto-aggro cooldown hold")
	pulled._physics_process(STEP)
	pulled.take_damage(1.0, nearby_foe)
	check(pulled.order == Enums.OrderType.NONE, "unit stays passive during 4s post-command hold even when taking damage")
	for _i in 122:
		pulled._physics_process(STEP)
		if pulled.order == Enums.OrderType.ATTACK:
			break
	check(pulled.order == Enums.OrderType.ATTACK and pulled.get("_attack_target") == nearby_foe, "unit resumes auto-aggro after 4s post-command hold expires")

	# 11. Scout cavalry ignores passive enemy buildings and refuses to retaliate against enemy TC/tower fire.
	_fixture(false, true)
	var scout := _unit(&"scout_cavalry", Vector2(0, 0), Enums.Team.PLAYER)
	var _enemy_house := _building(&"house", Vector2(4, 0), Enums.Team.AI)
	var enemy_tc := _building(&"town_center", Vector2(8, 0), Enums.Team.AI)
	scout._physics_process(STEP)
	check(scout.order == Enums.OrderType.NONE, "idle scout_cavalry does not auto-attack enemy buildings")
	scout.take_damage(1.0, enemy_tc)
	check(scout.order == Enums.OrderType.NONE, "idle scout_cavalry does not retaliate against enemy building damage")


func _test_batch_gateway_and_execution() -> void:
	_fixture(false, true)
	var _tc := _building(&"town_center", Vector2(-10, -10), Enums.Team.PLAYER)
	var m1 := _unit(&"militia", Vector2(0, 0), Enums.Team.PLAYER)
	var m2 := _unit(&"militia", Vector2(2, 1), Enums.Team.PLAYER)
	var a1 := _unit(&"archer", Vector2(1, 2), Enums.Team.PLAYER)
	var a2 := _unit(&"archer", Vector2(50, 50), Enums.Team.PLAYER)
	var v1 := _unit(&"villager", Vector2(1, 1), Enums.Team.PLAYER)
	var enemy := _unit(&"militia", Vector2(12, 0), Enums.Team.AI)

	# Capabilities + DecisionContext army summary + Tool schema checks
	var obs := Observations.build_json_safe(state, entities, 0, 1, 1.0)
	check(obs.capabilities.get("batch_unit_commands", false) == true, "observation advertises batch_unit_commands capability")
	check(obs.capabilities.get("unit_auto_aggro", false) == true, "observation advertises unit_auto_aggro capability")
	var army_ctx: Dictionary = obs.decision_context.get("army", {})
	check(army_ctx.has("unit_groups") and army_ctx.has("cluster_box"), "decision_context.army includes unit_groups and cluster_box")
	check((army_ctx.cluster_box as Array).size() == 4, "cluster_box has 4 bounds entries")

	var tool_names: Array = []
	for tool in Tools.tools_payload():
		tool_names.append(tool.function.name)
	for req_name in ["move_group", "move_box", "move_same_type", "attack_group", "attack_box", "attack_same_type"]:
		check(req_name in tool_names, "tool catalog exposes %s" % req_name)

	var ctx := _ctx(0)

	# 1. move_box excludes villager, commands militia + nearby archer with formation destinations
	var box_res := Executor.execute({
		"command_id": "c_move_box",
		"session_epoch": "1",
		"op": "move_box",
		"box": [-2, -2, 5, 5],
		"pos": [18, 18],
		"formation": "box",
	}, ctx)
	check(bool(box_res.get("ok")), "move_box executes successfully")
	check(int(box_res.get("unit_count", 0)) == 3, "move_box selects 3 military units inside box and excludes villager & distant archer")
	check(m1.order == Enums.OrderType.MOVE and m2.order == Enums.OrderType.MOVE and a1.order == Enums.OrderType.MOVE, "move_box issues MOVE to selected military units")
	check(v1.order == Enums.OrderType.NONE, "move_box leaves villager in box untouched")
	check(a2.order == Enums.OrderType.NONE, "move_box leaves distant archer outside box untouched")
	check(not m1._move_target.is_equal_approx(m2._move_target), "move_box assigns distinct formation destinations")

	# 2. attack_box focus-fires military units inside rect on target
	var atk_box_res := Executor.execute({
		"command_id": "c_attack_box",
		"session_epoch": "1",
		"op": "attack_box",
		"box": [-2, -2, 5, 5],
		"target_id": Registry.id_of(enemy),
	}, ctx)
	check(bool(atk_box_res.get("ok")) and int(atk_box_res.get("unit_count", 0)) == 3, "attack_box orders 3 military units to attack")
	check(m1.order == Enums.OrderType.ATTACK and a1.order == Enums.OrderType.ATTACK and v1.order == Enums.OrderType.NONE, "attack_box sets ATTACK on military units only")

	# 3. move_same_type selects nearby cluster (a1) within 36 tiles and leaves distant a2 (>40 tiles) untouched
	var same_move := Executor.execute({
		"command_id": "c_same_move",
		"session_epoch": "1",
		"op": "move_same_type",
		"unit_def_id": "archer",
		"pos": [5, 5],
		"formation": "line",
	}, ctx)
	check(bool(same_move.get("ok")) and int(same_move.get("unit_count", 0)) == 1, "move_same_type selects only archers within SAME_TYPE_SELECT_RADIUS of anchor")
	check(a1.order == Enums.OrderType.MOVE and a2.order == Enums.OrderType.NONE, "move_same_type leaves archer beyond 36-tile double-click radius untouched")

	# 4. manual_control_hold skips manually held unit in move_group / rejects when all held
	m1.set_meta("manual_control_until_sim_time", 25.0)
	var hold_partial := Executor.execute({
		"command_id": "c_group_partial",
		"session_epoch": "1",
		"op": "move_group",
		"unit_ids": [Registry.id_of(m1), Registry.id_of(m2)],
		"pos": [8, 8],
		"formation": "line",
	}, ctx)
	check(bool(hold_partial.get("ok")) and int(hold_partial.get("unit_count", 0)) == 1, "move_group skips manually held m1 and still commands m2")
	var hold_all := Executor.execute({
		"command_id": "c_group_all_held",
		"session_epoch": "1",
		"op": "attack_group",
		"unit_ids": [Registry.id_of(m1)],
		"target_id": Registry.id_of(enemy),
	}, ctx)
	check(not bool(hold_all.get("ok")) and hold_all.get("reason") == "manual_control_hold", "attack_group reports manual_control_hold when all targets are held")


func _test_online_lockstep_batch() -> void:
	_fixture(false, true)
	var network := NetworkMatchScript.new()
	network.name = "NetworkMatch"
	network.entities = entities
	network.match_state = state
	network.is_host = true
	network.local_team = 0
	network.synchronized = true
	network._playing = true
	container.add_child(network)
	state.lockstep_enabled = true

	var u1 := _unit(&"militia", Vector2(0, 0), Enums.Team.PLAYER)
	var u2 := _unit(&"archer", Vector2(2, 0), Enums.Team.PLAYER)
	var enemy := _unit(&"militia", Vector2(15, 0), Enums.Team.AI)
	var ctx := _ctx(0)

	var online_move := Executor.execute({
		"command_id": "c_online_move",
		"session_epoch": "1",
		"op": "move_box",
		"box": [-2, -2, 5, 5],
		"pos": [22, 22],
		"formation": "line",
	}, ctx)
	check(bool(online_move.get("ok")) and online_move.get("reason") == "queued_for_frame", "online move_box queues wire commands for frame")
	check(int(online_move.get("unit_count", 0)) == 2, "online move_box queues 2 unit move wire commands")
	var pending: Array = network.get("_pending_commands")
	check(pending.size() == 2 and pending[0].command.op == "move" and pending[1].command.op == "move", "online batch expands into wire-compatible move commands")
	var min_speed := minf(u1.def.move_speed, u2.def.move_speed)
	check(is_equal_approx(float(pending[1].command.get("formation_speed", 0.0)), min_speed), "online batch move includes shared formation_speed on faster unit")

	# Executing inside frame applies both moves with formation_speed and AI lineage (seq matches _local_order_notes)
	for entry in pending:
		network._frame_running = true
		check(network.execute_team_command(entry.command, 0, int(entry.get("seq", 0))), "lockstep execute_team_command accepts expanded batch move")
		network._frame_running = false
	check(u1.order == Enums.OrderType.MOVE and u2.order == Enums.OrderType.MOVE, "replayed batch move moves both units")
	check(is_equal_approx(u2._formation_move_speed, min_speed), "replayed formation_speed applies to faster archer")

	# Clear pending and test online attack_same_type
	pending.clear()
	var online_atk := Executor.execute({
		"command_id": "c_online_atk",
		"session_epoch": "1",
		"op": "attack_same_type",
		"unit_def_id": "militia",
		"target_id": Registry.id_of(enemy),
	}, ctx)
	check(bool(online_atk.get("ok")) and int(online_atk.get("unit_count", 0)) == 1, "online attack_same_type queues attack wire command")
	check(pending.size() == 1 and pending[0].command.op == "attack", "online attack_same_type expands into attack wire command")


func _run() -> void:
	UnitDebugFocus.set_spectator_mode(true)
	_test_auto_aggro()
	_test_batch_gateway_and_execution()
	_test_online_lockstep_batch()
	if is_instance_valid(container):
		container.free()
	Registry.clear()
	Events.clear()
	if failures.is_empty():
		print("ALL AUTO-AGGRO & BATCH AI TESTS PASSED (%d checks)" % checks)
		quit(0)
	else:
		printerr("AUTO-AGGRO & BATCH AI TESTS FAILED (%d failures / %d checks): %s" % [failures.size(), checks, failures])
		quit(1)
