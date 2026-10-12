class_name AiCombatManager
extends RefCounted

const FogAccess := preload("res://scripts/systems/fog_access.gd")
const AiEntityQueriesScript := preload("res://scripts/systems/ai/ai_entity_queries.gd")
const EntityRegistry := preload("res://scripts/ai_gateway/entity_registry.gd")


func tick_army(ctx: AiRunContext) -> Dictionary:
	var hostiles: Array[Node2D] = []
	if ctx.entities == null:
		return {}
	for node in ctx.entities.get_children():
		if not node is Node2D or not FogAccess.state_can_see(ctx.match_state, ctx.team, node):
			continue
		if node.get("team") != ctx.enemy_team or node.get("is_placement_ghost") == true:
			continue
		if not node.has_method("take_damage") or float(node.get("hp")) <= 0.0:
			continue
		if ctx.phase == 3:
			if not node.get("def") is UnitDef:
				continue
			if ctx.blackboard.own_tc_pos.distance_to(node.get("sim_pos")) > ctx.profile.defend_radius:
				continue
		hostiles.append(node)
	var engaged := {}
	var attacks := 0
	for unit in ctx.blackboard.team_units:
		var definition := unit.get("def") as UnitDef
		if definition == null or definition.id == &"villager" or float(unit.get("hp")) <= 0.0:
			continue
		var order: int = unit.get("order")
		if order in [Enums.OrderType.GATHER, Enums.OrderType.BUILD] or _already_commanded(ctx, unit):
			continue
		var previous: Variant = unit.get("_attack_target")
		var current: Node2D
		if is_instance_valid(previous) and previous is Node2D and hostiles.has(previous) and order == Enums.OrderType.ATTACK:
			current = previous
		var position: Vector2 = unit.get("sim_pos")
		var target: Node2D
		var nearby_troops: Array[Node2D] = []
		for hostile in hostiles:
			if hostile.get("def") is UnitDef and position.distance_to(hostile.get("sim_pos")) <= ctx.profile.retarget_radius:
				nearby_troops.append(hostile)
		if current != null and nearby_troops.has(current):
			target = current
		elif not nearby_troops.is_empty():
			target = _nearest(position, nearby_troops)
		elif current != null:
			target = current
		elif ctx.phase == 3:
			target = _nearest(position, hostiles)
		else:
			for hostile in hostiles:
				var building_def := hostile.get("def") as BuildingDef
				if building_def != null and building_def.id == &"town_center":
					target = hostile
					break
			if target == null:
				target = _nearest(position, hostiles)
		if target == null:
			continue
		engaged[unit.get_instance_id()] = true
		if order != Enums.OrderType.ATTACK or unit.get("_attack_target") != target:
			ctx.issue_attack(unit, target)
			attacks += 1
	if attacks > 0:
		ctx.log_decision("COMBAT", "下达 %d 个攻击命令" % attacks)
	return engaged


func _nearest(position: Vector2, candidates: Array[Node2D]) -> Node2D:
	var nearest: Node2D
	var distance := INF
	for candidate in candidates:
		var next_distance := position.distance_squared_to(candidate.get("sim_pos"))
		if next_distance < distance:
			nearest = candidate
			distance = next_distance
	return nearest


func _already_commanded(ctx: AiRunContext, unit: Node2D) -> bool:
	if not ctx.capture_commands:
		return false
	var id := EntityRegistry.id_of(unit)
	for command in ctx.pending_commands:
		if command.get("unit_id", -1) == id:
			return true
	return false


func nearest_hostile_in_radius(
	unit: Node2D, entities: Node2D, enemy_team: Enums.Team, radius: float
) -> Node2D:
	return AiEntityQueriesScript.nearest_hostile_in_radius(unit, entities, enemy_team, radius)
