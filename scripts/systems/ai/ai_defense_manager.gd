extends RefCounted
## Local/embedded fallback uses the same legal wall options as Python defense.
const Observation := preload("res://scripts/ai_gateway/observation_builder.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Walls := preload("res://scripts/systems/wall_system.gd")
var next_check := 0.0
var threat_until := 0.0

func reset() -> void:
	next_check = 0.0
	threat_until = 0.0

func tick(ctx: AiRunContext) -> void:
	var board := ctx.blackboard
	if board.threat_near_base: threat_until = board.match_time + 180.0
	if board.match_time < next_check: return
	next_check = board.match_time + 10.0
	if board.match_time >= threat_until or board.villager_count < 8 or not ctx.can_afford(100, 200, 0): return
	if board.incomplete_buildings > 0: return
	if not board.team_buildings.any(func(b): return String(b.def.id) in ["barracks", "archery_range", "stable"] and b.is_complete): return
	var count := board.team_buildings.filter(func(b): return Walls.is_fortification(b.def.id)).size()
	if count >= 12: return
	var observation := Observation.build_json_safe(ctx.match_state, ctx.entities, ctx.team, ctx.enemy_team, board.match_time)
	for option: Dictionary in observation.decision_context.defense_options:
		if count + int(option.segment_count) > 12: continue
		var builder := Registry.resolve(int(option.builder_id))
		if not is_instance_valid(builder): continue
		if ctx.pending_commands.any(func(c): return int(c.get("unit_id", c.get("builder_id", -1))) == int(option.builder_id)): continue
		var center := (Vector2(option.start[0], option.start[1]) + Vector2(option.end[0], option.end[1])) * 0.5
		if observation.entities.any(func(e): return e.get("kind") == "unit" and int(e.get("team", -1)) != int(ctx.team) and e.get("def_id") != "villager" and minf(Vector2(e.pos[0], e.pos[1]).distance_to(builder.sim_pos), Vector2(e.pos[0], e.pos[1]).distance_to(center)) < 10): continue
		if ctx.issue_wall(option):
			ctx.log_decision("DEFENSE", "建造 %d 段防线，保留通道%s" % [option.segment_count, "和自动城门" if option.include_gate else ""])
			return
