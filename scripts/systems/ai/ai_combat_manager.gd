class_name AiCombatManager
extends RefCounted

const FogAccess := preload("res://scripts/systems/fog_access.gd")
const AiEntityQueriesScript := preload("res://scripts/systems/ai/ai_entity_queries.gd")
const EntityRegistry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Walls := preload("res://scripts/systems/wall_system.gd")
const Projectile := preload("res://scripts/entities/projectile_agent.gd")
const DEMOLITION_UNITS := [&"battering_ram", &"capped_ram", &"siege_ram", &"mangonel", &"onager", &"siege_onager", &"trebuchet", &"bombard_cannon"]


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
		hostiles.append(node)
	var base_threats: Array[Node2D] = []
	if ctx.phase == 3:
		for hostile in hostiles:
			if hostile.get("def") is UnitDef and ctx.blackboard.own_tc_pos.distance_to(hostile.get("sim_pos")) <= ctx.profile.defend_radius:
				base_threats.append(hostile)
	var defenders := _defending_units(ctx, base_threats)
	var base_critical := _base_critical(ctx)
	var recall_siege := ctx.phase == 3 and (base_threats.is_empty() or base_critical or defenders.size() < maxi(2, base_threats.size() * 2))
	var engaged := {}
	var attacks := 0
	for unit in ctx.blackboard.team_units:
		var definition := unit.get("def") as UnitDef
		if definition == null or definition.id == &"villager" or float(unit.get("hp")) <= 0.0:
			continue
		var order: int = unit.get("order")
		if order in [Enums.OrderType.GATHER, Enums.OrderType.BUILD] or _already_commanded(ctx, unit):
			continue
		var targets := hostiles
		if ctx.phase == 3 and (base_threats.is_empty() or defenders.has(unit.get_instance_id())):
			targets = base_threats
		elif ctx.phase == 3:
			var offensive: Array[Node2D] = []
			for hostile in hostiles:
				if not base_threats.has(hostile):
					offensive.append(hostile)
			if not offensive.is_empty():
				targets = offensive
		if is_demolition(definition) and recall_siege:
			targets = []
		var previous: Variant = unit.get("_attack_target")
		var current: Node2D
		if is_instance_valid(previous) and previous is Node2D and targets.has(previous) and order == Enums.OrderType.ATTACK:
			current = previous
		var target := _siege_target(unit, targets, current) if is_demolition(definition) else _soldier_target(ctx, unit, targets, current)
		if target == null:
			continue
		engaged[unit.get_instance_id()] = true
		if is_demolition(definition) and _friendly_blast(ctx, unit, target):
			# Cancel a previously safe shot when escorts enter the impact area.
			# Mark the siege engaged so army search does not immediately override it.
			if order == Enums.OrderType.ATTACK:
				ctx.issue_move(unit, unit.get("sim_pos"))
			continue
		if order != Enums.OrderType.ATTACK or unit.get("_attack_target") != target:
			ctx.issue_attack(unit, target)
			attacks += 1
	if attacks > 0:
		ctx.log_decision("COMBAT", "下达 %d 个攻击命令" % attacks)
	return engaged


func _friendly_blast(ctx: AiRunContext, unit: Node2D, target: Node2D) -> bool:
	var definition := unit.get("def") as UnitDef
	if not definition.is_ranged or not definition.projectile_friendly_fire or definition.projectile_splash_radius <= 0:
		return false
	var impact := Projectile.aim_point_for_target(unit.get("sim_pos"), target)
	var radius := definition.projectile_splash_radius + 0.75
	for ally in ctx.blackboard.team_units:
		if ally != unit and float(ally.get("hp")) > 0 and impact.distance_to(ally.get("sim_pos")) <= radius:
			return true
	for ally in ctx.blackboard.team_buildings:
		if float(ally.get("hp")) <= 0:
			continue
		var ally_def := ally.get("def") as BuildingDef
		var size: Vector2 = ally.call("get_placement_footprint") if ally.has_method("get_placement_footprint") else ally_def.footprint
		var center: Vector2 = ally.get("sim_pos")
		if impact.distance_to(impact.clamp(center - size * 0.5, center + size * 0.5)) <= radius:
			return true
	return false


func _base_critical(ctx: AiRunContext) -> bool:
	for building in ctx.blackboard.team_buildings:
		var definition := building.get("def") as BuildingDef
		if definition != null and definition.id == &"town_center" and float(building.get("hp")) < definition.max_hp * 0.35:
			return true
	return false


func _defending_units(ctx: AiRunContext, threats: Array[Node2D]) -> Dictionary:
	var selected := {}
	if ctx.phase != 3 or threats.is_empty():
		return selected
	var soldiers: Array[Node2D] = []
	for unit in ctx.blackboard.team_units:
		var definition := unit.get("def") as UnitDef
		if definition != null and definition.id != &"villager" and not is_demolition(definition) and float(unit.get("hp")) > 0:
			soldiers.append(unit)
	soldiers.sort_custom(func(a: Node2D, b: Node2D): return ctx.blackboard.own_tc_pos.distance_squared_to(a.get("sim_pos")) < ctx.blackboard.own_tc_pos.distance_squared_to(b.get("sim_pos")))
	var needed := soldiers.size() if _base_critical(ctx) else maxi(2, threats.size() * 2)
	for index in mini(needed, soldiers.size()):
		selected[soldiers[index].get_instance_id()] = true
	return selected


static func is_demolition(definition: UnitDef) -> bool:
	return definition != null and definition.id in DEMOLITION_UNITS


func _soldier_target(ctx: AiRunContext, unit: Node2D, hostiles: Array[Node2D], current: Node2D) -> Node2D:
	var position: Vector2 = unit.get("sim_pos")
	var definition := unit.get("def") as UnitDef
	var nearby_military: Array[Node2D] = []
	var nearby_workers: Array[Node2D] = []
	var troops: Array[Node2D] = []
	var workers: Array[Node2D] = []
	var contact_radius := maxf(ctx.profile.retarget_radius, definition.attack_range + 12.0)
	for hostile in hostiles:
		var enemy := hostile.get("def") as UnitDef
		if enemy == null:
			continue
		troops.append(hostile)
		if enemy.id == &"villager":
			workers.append(hostile)
		if position.distance_to(hostile.get("sim_pos")) <= contact_radius:
			if enemy.id == &"villager":
				nearby_workers.append(hostile)
			else:
				nearby_military.append(hostile)
	# Escort troops intercept enemy fighters before raiding nearby workers. Never
	# remain on a building while visible enemy manpower can still be pressured.
	for candidates in [nearby_military, nearby_workers]:
		if not candidates.is_empty():
			return current if candidates.has(current) else _nearest(position, candidates)
	if troops.has(current):
		return current
	if not workers.is_empty() and ctx.phase != 3:
		return _nearest(position, workers)
	if not troops.is_empty():
		return _nearest(position, troops)
	return _building_target(position, hostiles, current)


func _siege_target(unit: Node2D, hostiles: Array[Node2D], current: Node2D) -> Node2D:
	var position: Vector2 = unit.get("sim_pos")
	var target := _building_target(position, hostiles, current)
	if target == null:
		return null
	var definition := unit.get("def") as UnitDef
	# Ranged siege can fire over walls once it is within its firing envelope.
	if definition.is_ranged and position.distance_to(target.get("sim_pos")) <= definition.attack_range:
		return target
	var breach: Node2D
	var nearest_distance := INF
	for hostile in hostiles:
		var building := hostile.get("def") as BuildingDef
		if hostile == target or building == null or not Walls.is_fortification(building.id):
			continue
		if building.id == &"gate" and bool(hostile.get("gate_open")):
			continue
		var center: Vector2 = hostile.get("sim_pos")
		var size: Vector2 = hostile.call("get_placement_footprint") if hostile.has_method("get_placement_footprint") else building.footprint
		var rect := Rect2(center - size * 0.5, size).grow(definition.resolved_footprint_radius() + 0.2)
		if _crosses_rectangle(position, target.get("sim_pos"), rect) and position.distance_squared_to(center) < nearest_distance:
			breach = hostile
			nearest_distance = position.distance_squared_to(center)
	return breach if breach != null else target


func _building_target(position: Vector2, hostiles: Array[Node2D], current: Node2D) -> Node2D:
	var buildings: Array[Node2D] = []
	var centers: Array[Node2D] = []
	for hostile in hostiles:
		var definition := hostile.get("def") as BuildingDef
		if definition == null:
			continue
		buildings.append(hostile)
		if definition.id == &"town_center":
			centers.append(hostile)
	if not centers.is_empty():
		return current if centers.has(current) else _nearest(position, centers)
	return current if buildings.has(current) else _nearest(position, buildings)


func _crosses_rectangle(start: Vector2, end: Vector2, rect: Rect2) -> bool:
	if rect.has_point(start) or rect.has_point(end):
		return true
	var corners := [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]
	for index in 4:
		if Geometry2D.segment_intersects_segment(start, end, corners[index], corners[(index + 1) % 4]) != null:
			return true
	return false


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
