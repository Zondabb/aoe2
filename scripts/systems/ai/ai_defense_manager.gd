extends RefCounted
## Local/embedded fallback follows the same continuous perimeter as Python defense.
const Observation := preload("res://scripts/ai_gateway/observation_builder.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Walls := preload("res://scripts/systems/wall_system.gd")
const FogAccess := preload("res://scripts/systems/fog_access.gd")
var next_check := 0.0
var threat_until := 0.0
var perimeter_scout_id := -1
var perimeter_scout_started := 0.0
var perimeter_scout_progress_time := 0.0
var perimeter_scout_last_pos := Vector2.ZERO
var perimeter_scout_cooldown_until := 0.0
const MAX_SEGMENTS := 512
const SCOUT_TIMEOUT := 20.0
const SCOUT_STALL_TIMEOUT := 8.0
const SCOUT_COOLDOWN := 20.0

func reset() -> void:
	next_check = 0.0
	threat_until = 0.0
	perimeter_scout_id = -1
	perimeter_scout_cooldown_until = 0.0

func tick(ctx: AiRunContext) -> void:
	var board := ctx.blackboard
	_monitor_perimeter_scout(ctx)
	if board.threat_near_base: threat_until = board.match_time + 180.0
	if board.match_time < next_check: return
	next_check = board.match_time + 10.0
	var established := board.military_count >= 3 and (ctx.match_state.age_of(ctx.team) >= 1 or board.match_time >= 180.0)
	if (board.match_time >= threat_until and not established) or board.villager_count < 8: return
	if ctx.pending_commands.any(func(c): return c.get("op") in ["place_building", "place_wall"]): return
	if not board.team_buildings.any(func(b): return String(b.def.id) in ["barracks", "archery_range", "stable"] and b.is_complete): return
	var observation := Observation.build_json_safe(ctx.match_state, ctx.entities, ctx.team, ctx.enemy_team, board.match_time)
	# Already purchased foundations must not depend on another wall budget. Recover
	# an abandoned batch, while preserving workers' active construction queues.
	if _finish_foundations(ctx, observation): return
	if not ctx.can_afford(100, 200, 0): return
	if board.team_buildings.any(func(b): return not b.is_complete and not Walls.is_fortification(b.def.id)): return
	var count := board.team_buildings.filter(func(b): return Walls.is_fortification(b.def.id)).size()
	if count >= MAX_SEGMENTS: return
	var options: Array = observation.decision_context.get("defense_options", [])
	# Geometry supplies repair/connected-batch priority for one persistent ring.
	# Reordering by nearby walls would scatter isolated strips around the base.
	for option: Dictionary in options:
		if count + int(option.segment_count) > MAX_SEGMENTS: continue
		var builder := Registry.resolve(int(option.builder_id))
		if not _free_builder(ctx, builder): continue
		var start := Vector2(option.start[0], option.start[1])
		var end := Vector2(option.end[0], option.end[1])
		if _unsafe(observation, ctx.team, builder.sim_pos, start, end): continue
		if ctx.issue_wall(option):
			ctx.log_decision("DEFENSE", "沿基地周界续建 %d 段城墙%s" % [option.segment_count, "（含自动城门）" if option.include_gate else ""])
			return
	_scout_perimeter(ctx, observation)


func _free_builder(ctx: AiRunContext, builder: Node2D) -> bool:
	if not is_instance_valid(builder) or builder.hp <= 0.0: return false
	if ctx.blackboard.match_time < float(builder.get_meta("manual_control_until_sim_time", -1.0)): return false
	if builder.order not in [Enums.OrderType.NONE, Enums.OrderType.GATHER]: return false
	if builder.carry_amount > 0.001 or builder._gather_state == "to_drop_off" or not builder.get_build_queue_ids().is_empty(): return false
	var id := Registry.id_of(builder)
	return not ctx.pending_commands.any(func(c): return int(c.get("unit_id", c.get("builder_id", -1))) == id)


func _unsafe(observation: Dictionary, team: int, builder_pos: Vector2, start: Vector2, end: Vector2) -> bool:
	return observation.entities.any(func(e):
		if e.get("kind") != "unit" or int(e.get("team", -1)) == team or e.get("def_id") == "villager": return false
		var enemy_pos := Vector2(e.pos[0], e.pos[1])
		return minf(enemy_pos.distance_to(builder_pos), enemy_pos.distance_to(Geometry2D.get_closest_point_to_segment(enemy_pos, start, end))) < 10.0
	)


func _finish_foundations(ctx: AiRunContext, observation: Dictionary) -> bool:
	var unfinished := ctx.blackboard.team_buildings.filter(func(b): return not b.is_complete and Walls.is_fortification(b.def.id))
	if unfinished.is_empty(): return false
	for foundation in unfinished:
		var id := Registry.id_of(foundation)
		if ctx.blackboard.team_villagers.any(func(worker): return worker._build_target == foundation and worker.order == Enums.OrderType.BUILD or id in worker.get_build_queue_ids()): continue
		var builder: Node2D
		for worker in ctx.blackboard.team_villagers:
			if not _free_builder(ctx, worker): continue
			if _unsafe(observation, ctx.team, worker.sim_pos, worker.sim_pos, foundation.sim_pos): continue
			if builder == null or worker.sim_pos.distance_squared_to(foundation.sim_pos) < builder.sim_pos.distance_squared_to(foundation.sim_pos): builder = worker
		if builder != null:
			ctx.issue_build(builder, foundation)
			ctx.log_decision("DEFENSE", "继续完成周界城墙地基")
			break
	return true


func _scout_perimeter(ctx: AiRunContext, observation: Dictionary) -> void:
	var previous := Registry.resolve(perimeter_scout_id) if perimeter_scout_id >= 0 else null
	if is_instance_valid(previous) and previous.hp > 0 and previous.order == Enums.OrderType.MOVE: return
	perimeter_scout_id = -1
	if ctx.blackboard.match_time < perimeter_scout_cooldown_until: return
	for option: Dictionary in observation.decision_context.get("defense_scout_options", []):
		var builder := Registry.resolve(int(option.unit_id))
		if not _free_builder(ctx, builder): continue
		var goal := Vector2(option.pos[0], option.pos[1])
		if _unsafe(observation, ctx.team, builder.sim_pos, builder.sim_pos, goal): continue
		ctx.issue_move(builder, goal)
		perimeter_scout_id = int(option.unit_id)
		perimeter_scout_started = ctx.blackboard.match_time
		perimeter_scout_progress_time = ctx.blackboard.match_time
		perimeter_scout_last_pos = builder.sim_pos
		ctx.log_decision("DEFENSE", "派一名空手村民探明待建周界")
		return


func _monitor_perimeter_scout(ctx: AiRunContext) -> void:
	if perimeter_scout_id < 0: return
	var worker := Registry.resolve(perimeter_scout_id)
	if not is_instance_valid(worker) or worker.hp <= 0.0 or worker.order != Enums.OrderType.MOVE:
		perimeter_scout_id = -1
		return
	var now := ctx.blackboard.match_time
	# A human order or another manager taking over ends this scouting lease.
	# Never cancel the new owner's move when our short survey expires.
	if now < float(worker.get_meta("manual_control_until_sim_time", -1.0)) or ctx.pending_commands.any(func(c): return int(c.get("unit_id", c.get("builder_id", -1))) == perimeter_scout_id):
		perimeter_scout_id = -1
		perimeter_scout_cooldown_until = now + SCOUT_COOLDOWN
		return
	if worker.sim_pos.distance_to(perimeter_scout_last_pos) > 0.5:
		perimeter_scout_last_pos = worker.sim_pos
		perimeter_scout_progress_time = now
	# Monitor every AI tick, including ticks between wall purchases. Only current
	# visible units influence a retreat; undiscovered enemies cannot leak in.
	var visible_enemies: Array = []
	for actor in ctx.entities.get_children():
		if not actor is UnitAgent or actor.team == ctx.team or actor.hp <= 0.0 or actor.def == null or actor.def.id == &"villager": continue
		if not FogAccess.state_can_see(ctx.match_state, ctx.team, actor): continue
		visible_enemies.append({"kind": "unit", "team": actor.team, "def_id": String(actor.def.id), "pos": [actor.sim_pos.x, actor.sim_pos.y]})
	var danger := _unsafe({"entities": visible_enemies}, ctx.team, worker.sim_pos, worker.sim_pos, worker._move_target)
	if not danger and now - perimeter_scout_started < SCOUT_TIMEOUT and now - perimeter_scout_progress_time < SCOUT_STALL_TIMEOUT: return
	perimeter_scout_id = -1
	perimeter_scout_cooldown_until = now + SCOUT_COOLDOWN
	ctx.issue_move(worker, ctx.blackboard.own_tc_pos if danger else worker.sim_pos)
	ctx.log_decision("DEFENSE", "探边遇敌，撤回基地" if danger else "探边停滞或超时，释放施工村民")
