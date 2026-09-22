class_name AiCombatManager
extends RefCounted

const FogAccess := preload("res://scripts/systems/fog_access.gd")

const AutoCombatDirectorScript := preload("res://scripts/systems/auto_combat_director.gd")
const AiEntityQueriesScript := preload("res://scripts/systems/ai/ai_entity_queries.gd")


func tick_army(ctx: AiRunContext) -> void:
	var enemy_tc := _find_enemy_town_center(ctx)
	var attacks := 0
	for unit in ctx.blackboard.team_units:
		var unit_def := unit.get("def") as UnitDef
		if unit_def == null or unit_def.id == &"villager":
			continue
		var order: Enums.OrderType = unit.get("order")
		if order == Enums.OrderType.GATHER or order == Enums.OrderType.BUILD:
			continue
		var nearby := AiEntityQueriesScript.nearest_hostile_in_radius(
			unit, ctx.entities, ctx.enemy_team, ctx.profile.retarget_radius
		)
		if nearby != null:
			if unit.get("order") != Enums.OrderType.ATTACK or unit.get("_attack_target") != nearby:
				ctx.issue_attack(unit, nearby)
				attacks += 1
			continue
		if enemy_tc != null:
			if unit.get("order") != Enums.OrderType.ATTACK or unit.get("_attack_target") != enemy_tc:
				ctx.issue_attack(unit, enemy_tc)
				attacks += 1
		elif ctx.blackboard.enemy_tc_pos != Vector2.ZERO:
			ctx.issue_move(unit, ctx.blackboard.enemy_tc_pos)
	if attacks > 0:
		ctx.log_decision("COMBAT", "下达 %d 个攻击命令" % attacks)


func nearest_hostile_in_radius(
	unit: Node2D, entities: Node2D, enemy_team: Enums.Team, radius: float
) -> Node2D:
	return AiEntityQueriesScript.nearest_hostile_in_radius(
		unit, entities, enemy_team, radius
	)


func _find_enemy_town_center(ctx: AiRunContext) -> Node2D:
	if ctx.entities == null:
		return null
	for node in ctx.entities.get_children():
		if not FogAccess.state_can_see(ctx.match_state, ctx.team, node):
			continue
		if node.get("team") != ctx.enemy_team:
			continue
		var building_def := node.get("def") as BuildingDef
		if building_def != null and building_def.id == &"town_center":
			return node as Node2D
	return null
