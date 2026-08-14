class_name AiArmyManager
extends RefCounted


func rally(ctx: AiRunContext) -> void:
	if ctx.blackboard.own_tc_pos == Vector2.ZERO or ctx.blackboard.enemy_tc_pos == Vector2.ZERO:
		return
	var rally_point := ctx.blackboard.own_tc_pos.lerp(ctx.blackboard.enemy_tc_pos, 0.35)
	var rally_radius_sq := ctx.profile.rally_radius * ctx.profile.rally_radius
	var rallied := 0
	for unit in ctx.blackboard.team_units:
		var unit_def := unit.get("def") as UnitDef
		if unit_def == null or unit_def.id == &"villager":
			continue
		var order: Enums.OrderType = unit.get("order")
		if order == Enums.OrderType.GATHER or order == Enums.OrderType.BUILD:
			continue
		var dist_sq: float = unit.get("sim_pos").distance_squared_to(rally_point)
		if dist_sq > rally_radius_sq:
			if unit.get("order") != Enums.OrderType.MOVE:
				unit.call("command_move", rally_point)
				rallied += 1
	if rallied > 0:
		ctx.log_decision("ARMY", "集结 %d 单位 → %s" % [rallied, rally_point])
