class_name AiArmyManager
extends RefCounted

const EntityRegistry := preload("res://scripts/ai_gateway/entity_registry.gd")
var _search_base := Vector2.INF
var _search_bounds := Rect2()
var _search_points: Array[Vector2] = []
var _search_index := 0
var _search_goal := Vector2.INF
var _leader_id := 0
var _leader_position := Vector2.INF
var _last_progress_time := 0.0
var _move_goals := {}


func reset() -> void:
	_search_base = Vector2.INF
	_search_bounds = Rect2()
	_search_points.clear()
	_search_index = 0
	_search_goal = Vector2.INF
	_leader_id = 0
	_leader_position = Vector2.INF
	_last_progress_time = 0.0
	_move_goals.clear()


func rally(ctx: AiRunContext, engaged: Dictionary = {}) -> void:
	var candidates: Array[Node2D] = []
	for unit in ctx.blackboard.team_units:
		var definition := unit.get("def") as UnitDef
		if definition == null or definition.id in [&"villager", &"scout_cavalry", &"light_cavalry"]:
			continue
		if float(unit.get("hp")) <= 0.0 or engaged.has(unit.get_instance_id()) or _already_commanded(ctx, unit):
			continue
		var order: int = unit.get("order")
		if order in [Enums.OrderType.GATHER, Enums.OrderType.BUILD, Enums.OrderType.ATTACK]:
			continue
		if order == Enums.OrderType.MOVE and not _move_goals.has(unit.get_instance_id()):
			continue
		candidates.append(unit)
	var bounds := ctx.blackboard.map_bounds
	if candidates.is_empty() or not bounds.has_area():
		return
	if _search_base != ctx.blackboard.own_tc_pos or _search_bounds != bounds:
		reset()
		_search_base = ctx.blackboard.own_tc_pos
		_search_bounds = bounds
		_search_points.append(_clamp(bounds.get_center()))
		_search_points.append(_clamp(bounds.get_center() * 2.0 - _search_base))
		for row in 5:
			for step in 5:
				var column := step if row % 2 == 0 else 4 - step
				var point := _clamp(bounds.position + bounds.size * Vector2((column + 0.5) / 5.0, (row + 0.5) / 5.0))
				if not _search_points.has(point):
					_search_points.append(point)
	var leader := candidates[0]
	var position: Vector2 = leader.get("sim_pos")
	if leader.get_instance_id() != _leader_id:
		_leader_id = leader.get_instance_id()
		_leader_position = position
		_last_progress_time = ctx.blackboard.match_time
	if position.distance_to(_leader_position) >= 1.0:
		_leader_position = position
		_last_progress_time = ctx.blackboard.match_time
	var arrived := _search_goal != Vector2.INF and position.distance_to(_search_goal) <= ctx.profile.rally_radius
	var stalled := ctx.blackboard.match_time - _last_progress_time >= 8.0
	if _search_goal == Vector2.INF or arrived or stalled:
		_search_goal = _search_points[_search_index % _search_points.size()]
		_search_index += 1
		_last_progress_time = ctx.blackboard.match_time
		_leader_position = position
	var moved := 0
	for unit in candidates:
		if _move(ctx, unit, _search_goal):
			moved += 1
	if moved > 0:
		ctx.log_decision("ARMY", "搜索敌军 %d 单位 → %s" % [moved, _search_goal])


func rally_to_base(ctx: AiRunContext, engaged: Dictionary = {}) -> void:
	if ctx.blackboard.own_tc_pos == Vector2.ZERO and ctx.blackboard.team_buildings.is_empty():
		return
	var rallied := 0
	for unit in ctx.blackboard.team_units:
		var definition := unit.get("def") as UnitDef
		if definition == null or definition.id == &"villager" or float(unit.get("hp")) <= 0.0:
			continue
		if engaged.has(unit.get_instance_id()) or _already_commanded(ctx, unit):
			continue
		if unit.get("order") in [Enums.OrderType.GATHER, Enums.OrderType.BUILD]:
			continue
		var position: Vector2 = unit.get("sim_pos")
		if position.distance_to(ctx.blackboard.own_tc_pos) > ctx.profile.rally_radius and _move(ctx, unit, ctx.blackboard.own_tc_pos):
			rallied += 1
	if rallied > 0:
		ctx.log_decision("ARMY", "回防 %d 单位 → %s" % [rallied, ctx.blackboard.own_tc_pos])


func _move(ctx: AiRunContext, unit: Node2D, goal: Vector2) -> bool:
	var id := unit.get_instance_id()
	if unit.get("order") == Enums.OrderType.MOVE and _move_goals.get(id) == goal:
		return false
	_move_goals[id] = goal
	ctx.issue_move(unit, goal)
	return true


func _clamp(point: Vector2) -> Vector2:
	return point.clamp(_search_bounds.position + Vector2.ONE * 2.0, _search_bounds.end - Vector2.ONE * 2.0)


func _already_commanded(ctx: AiRunContext, unit: Node2D) -> bool:
	if not ctx.capture_commands:
		return false
	var id := EntityRegistry.id_of(unit)
	for command in ctx.pending_commands:
		if command.get("unit_id", -1) == id:
			return true
	return false
