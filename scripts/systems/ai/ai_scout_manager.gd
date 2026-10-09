class_name AiScoutManager
extends RefCounted

## Plan only from own actors, currently observed resources and public map bounds.
## No hidden entity position is queried to choose exploration destinations.
const RING_STEP := 24.0
const WAYPOINT_SPACING := 24.0
const ARRIVAL_RADIUS := 2.0
const MAX_STALLED_SECONDS := 8.0
var _waypoints: Array[Vector2] = []
var _base := Vector2.INF
var _bounds := Rect2()
var _index := 0
var _actor_id := 0
var _goal := Vector2.INF
var _last_position := Vector2.INF
var _last_progress_time := 0.0
var _seen_types := {}
var _probe_stage := 0

func reset() -> void:
	_waypoints.clear()
	_base = Vector2.INF
	_bounds = Rect2()
	_index = 0
	_actor_id = 0
	_goal = Vector2.INF
	_seen_types.clear()
	_probe_stage = 0

func tick(ctx: AiRunContext) -> void:
	var bb := ctx.blackboard
	var bounds: Rect2 = bb.map_bounds
	if not ctx.match_state.progression_enabled or not bounds.has_area() or bb.team_buildings.is_empty(): return
	if _base != bb.own_tc_pos or _bounds != bounds:
		reset()
		_base = bb.own_tc_pos
		_bounds = bounds
		_make_waypoints()
	var has_resource := false
	for resource in bb.resource_nodes:
		if float(resource.get("amount")) > 0:
			has_resource = true
			_seen_types[int(resource.get("resource_type"))] = true
	var scout: Node2D
	var has_scout := false
	for unit in bb.team_units:
		var definition := unit.get("def") as UnitDef
		if definition == null or definition.id not in [&"scout_cavalry", &"light_cavalry"]: continue
		has_scout = true
		if _available(unit) and not _already_commanded(ctx, unit):
			scout = unit
			break
	# Saved scenarios may omit the scout. One otherwise unemployed villager can
	# discover food; existing workers and construction/combat orders are preserved.
	if scout == null and not has_scout and not has_resource:
		for villager in bb.team_villagers:
			if _available(villager) and not _already_commanded(ctx, villager):
				scout = villager
				break
	if scout == null: return
	var actor_id := scout.get_instance_id()
	var position: Vector2 = scout.get("sim_pos")
	if actor_id != _actor_id:
		_actor_id = actor_id
		_goal = Vector2.INF
		_last_progress_time = bb.match_time
		_last_position = position
	if position.distance_to(_last_position) >= 1.0:
		_last_position = position
		_last_progress_time = bb.match_time
	var arrived := _goal != Vector2.INF and position.distance_to(_goal) <= ARRIVAL_RADIUS
	var stalled := bb.match_time - _last_progress_time >= MAX_STALLED_SECONDS
	if _goal != Vector2.INF and not arrived and not stalled and scout.get("order") == Enums.OrderType.MOVE: return
	var goal := _next_goal(ctx)
	if goal == Vector2.INF: return
	_goal = goal
	_last_progress_time = bb.match_time
	_last_position = position
	ctx.issue_move(scout, goal)
	ctx.log_decision("SCOUT", "探索公开地图坐标 %s" % goal)

func _available(unit: Node2D) -> bool:
	var order: int = unit.get("order")
	return order == Enums.OrderType.NONE or (order == Enums.OrderType.MOVE and unit.get_instance_id() == _actor_id)

func _already_commanded(ctx: AiRunContext, unit: Node2D) -> bool:
	if not ctx.capture_commands: return false
	var id := EntityRegistry.id_of(unit)
	for command in ctx.pending_commands:
		if command.get("unit_id", -1) == id or command.get("builder_id", -1) == id: return true
	return false

func _next_goal(ctx: AiRunContext) -> Vector2:
	# When the army is ready, probe the public map center and opposite sector.
	# These are geometric guesses, not the unseen enemy town center's position.
	if ctx.phase == 2 and _seen_types.size() == 4 and _probe_stage < 2 and ctx.blackboard.enemy_tc_pos == Vector2.ZERO:
		var point := _bounds.get_center() if _probe_stage == 0 else _bounds.get_center() * 2.0 - _base
		_probe_stage += 1
		return _clamp(point)
	while _index < _waypoints.size():
		var point := _waypoints[_index]
		_index += 1
		var blocked := false
		for resource in ctx.blackboard.resource_nodes:
			if int(resource.get("resource_type")) == Enums.ResourceType.FOOD: continue
			var half := ResourceNode.pathfinding_footprint(resource.get("resource_type")) * 0.5 + Vector2.ONE
			if Rect2(resource.get("sim_pos") - half, half * 2.0).has_point(point):
				blocked = true
				break
		if not blocked: return point
	return Vector2.INF

func _make_waypoints() -> void:
	var start_angle := (_bounds.get_center() - _base).angle()
	var max_radius := 0.0
	for corner in [_bounds.position, _bounds.end, Vector2(_bounds.position.x, _bounds.end.y), Vector2(_bounds.end.x, _bounds.position.y)]:
		max_radius = maxf(max_radius, _base.distance_to(corner))
	var used := {}
	for ring in range(1, ceili(max_radius / RING_STEP) + 1):
		var radius := ring * RING_STEP
		var sectors := maxi(8, ceili(TAU * radius / WAYPOINT_SPACING))
		for sector in sectors:
			var point := _clamp(_base + Vector2.from_angle(start_angle + TAU * sector / sectors) * radius)
			var key := Vector2i(point.round())
			if used.has(key): continue
			used[key] = true
			_waypoints.append(point)

func _clamp(point: Vector2) -> Vector2:
	return point.clamp(_bounds.position + Vector2.ONE * 2.0, _bounds.end - Vector2.ONE * 2.0)
