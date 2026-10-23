extends RefCounted
## A match-owned, stable wall footprint. Construction proceeds in small batches;
## buildings discovered or produced later never move an already started wall.
const Walls := preload("res://scripts/systems/wall_system.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Fog := preload("res://scripts/systems/fog_access.gd")
const Shore := preload("res://scripts/world/shore_geometry.gd")
const META_KEY := &"ai_defense_perimeters"

static func get_plan(state: MatchState, entities: Node2D, team: int, base: Vector2, tc_id: int, bounds: Rect2, material: String) -> Dictionary:
	var plans: Dictionary = state.get_meta(META_KEY, {})
	var key := "%d:%d" % [team, tc_id]
	var previous: Dictionary = plans.get(key, {})
	if previous.get("frozen", false): return previous
	# A preview may grow with the developing core until the first wall is paid
	# for. As soon as an existing foundation touches its line, freeze forever.
	if not previous.is_empty():
		for node in entities.get_children():
			if not node is Node2D or node.is_queued_for_deletion() or node.get("is_placement_ghost") == true: continue
			var definition := node.get("def") as BuildingDef
			if definition == null or not Walls.is_fortification(definition.id) or int(node.get("team")) != team or float(node.get("hp")) <= 0: continue
			for side: Dictionary in sides(previous.rect):
				if Geometry2D.get_closest_point_to_segment(node.get("sim_pos"), side.start, side.end).distance_to(node.get("sim_pos")) <= 0.51:
					previous.frozen = true
					return previous
	base = base.round()
	var lo := base.round() - Vector2.ONE * 28
	var hi := base.round() + Vector2.ONE * 28
	var required_lo := base - Vector2.ONE * 24
	var required_hi := base + Vector2.ONE * 24
	# Include the established core and producer exits, but remote mines and
	# lumber camps do not force a huge and unaffordable perimeter.
	for node in entities.get_children():
		if not node is Node2D or node.is_queued_for_deletion() or node.get("is_placement_ghost") == true: continue
		var definition := node.get("def") as BuildingDef
		if definition == null or Walls.is_fortification(definition.id): continue
		if int(node.get("team")) != team or float(node.get("hp")) <= 0: continue
		var point: Vector2 = node.get("sim_pos")
		if point.distance_to(base) > 40: continue
		var margin := definition.footprint * 0.5 + Vector2.ONE * 5.0
		lo = lo.min((point - margin).floor().max(base - Vector2.ONE * 44))
		hi = hi.max((point + margin).ceil().min(base + Vector2.ONE * 44))
		var access := definition.footprint * 0.5 + Vector2.ONE * 2.0
		required_lo = required_lo.min((point - access).floor().max(base - Vector2.ONE * 44))
		if String(definition.id) in ["barracks", "archery_range", "stable", "siege_workshop"]: access.x += 3.0
		required_hi = required_hi.max((point + access).ceil().min(base + Vector2.ONE * 44))
	if bounds.has_area():
		lo = lo.max((bounds.position + Vector2.ONE * 2).ceil())
		hi = hi.min((bounds.end - Vector2.ONE * 2).floor())
	var rectangle := Rect2(lo, hi - lo)
	rectangle = _choose_visible_boundary(state, entities, team, base, rectangle, Rect2(required_lo, required_hi - required_lo), bounds)
	var plan := {"id": "perimeter_v1:%s" % key, "rect": rectangle, "material": previous.get("material", material), "seen_complete": previous.get("seen_complete", {}), "frozen": false}
	plans[key] = plan
	state.set_meta(META_KEY, plans)
	return plan

static func _choose_visible_boundary(state: MatchState, entities: Node2D, team: int, base: Vector2, preferred: Rect2, required: Rect2, bounds: Rect2) -> Rect2:
	var blockers: Array[Rect2] = []
	var shores: Array = []
	for node in entities.get_children():
		if not node is Node2D or node.is_queued_for_deletion() or node.get("is_placement_ghost") == true: continue
		if node.has_method("get_water_contours") and not node.get_water_contours().is_empty():
			if Fog.state_can_see(state, team, node): shores.append(node)
			continue
		var size := Vector2.ZERO
		var definition := node.get("def") as BuildingDef
		if definition != null:
			if Walls.is_fortification(definition.id) or float(node.get("hp")) <= 0: continue
			size = node.get_placement_footprint() if node.has_method("get_placement_footprint") else definition.footprint
		elif node.has_method("pathfinding_size"):
			if float(node.get("amount")) <= 0: continue
			size = node.pathfinding_size()
		elif node.is_in_group("terrain_regions") and node.get("block_size") is Vector2:
			size = node.get("block_size")
		if size == Vector2.ZERO: continue
		var point: Vector2 = node.get("sim_pos")
		if state.fog_enabled and (state.fog == null or not state.fog.footprint_visible(team, point, size, true)): continue
		blockers.append(Rect2(point - size * 0.5, size))
	var clear := true
	for side: Dictionary in sides(preferred):
		if _side_collisions(state, team, side, blockers, shores) > 0:
			clear = false
			break
	if clear: return preferred
	var rectangle := preferred
	# Independent edge choices converge in two bounded sweeps. The score uses
	# observed obstacles only, retains the preferred edge when it is clear, and
	# never trades an enclosed building/producer exit for a cheaper wall.
	for sweep in 2:
		for axis in 4:
			var preferred_edge: float = [preferred.position.x, preferred.end.x, preferred.position.y, preferred.end.y][axis]
			var minimum: float = [base.x - 44, required.end.x, base.y - 44, required.end.y][axis]
			var maximum: float = [required.position.x, base.x + 44, required.position.y, base.y + 44][axis]
			if bounds.has_area():
				minimum = maxf(minimum, [bounds.position.x + 2, bounds.position.x + 2, bounds.position.y + 2, bounds.position.y + 2][axis])
				maximum = minf(maximum, [bounds.end.x - 2, bounds.end.x - 2, bounds.end.y - 2, bounds.end.y - 2][axis])
			var best := rectangle
			var best_score := INF
			for coordinate in range(ceili(minimum), floori(maximum) + 1):
				var lo := rectangle.position
				var hi := rectangle.end
				match axis:
					0: lo.x = coordinate
					1: hi.x = coordinate
					2: lo.y = coordinate
					3: hi.y = coordinate
				var candidate := Rect2(lo, hi - lo)
				var side: Dictionary = sides(candidate)[[3, 1, 0, 2][axis]]
				var collisions := _side_collisions(state, team, side, blockers, shores)
				var score := collisions * 1000.0 + absf(float(coordinate) - preferred_edge)
				if score < best_score:
					best_score = score
					best = candidate
			rectangle = best
	return rectangle

static func _side_collisions(state: MatchState, team: int, side: Dictionary, blockers: Array[Rect2], shores: Array) -> int:
	var strip := Rect2(side.start.min(side.end) - Vector2.ONE * 0.5, (side.end - side.start).abs() + Vector2.ONE)
	var collisions := 0
	for blocker in blockers:
		if strip.intersects(blocker): collisions += 1
	if shores.is_empty(): return collisions
	var tangent: Vector2 = (side.end - side.start).normalized()
	for index in roundi(side.start.distance_to(side.end)) + 1:
		var point: Vector2 = side.start + tangent * index
		if state.fog_enabled and not state.fog.footprint_visible(team, point, Vector2.ONE, true): continue
		var probe := Rect2(point - Vector2.ONE * 0.5, Vector2.ONE)
		for shore in shores:
			if Shore.intersects_rect(probe, shore.get_water_contours()): collisions += 1
	return collisions

static func sides(rectangle: Rect2) -> Array:
	var lo := rectangle.position
	var hi := rectangle.end
	return [
		{"side": "north", "start": lo, "end": Vector2(hi.x, lo.y), "normal": Vector2.UP},
		{"side": "east", "start": Vector2(hi.x, lo.y), "end": hi, "normal": Vector2.RIGHT},
		{"side": "south", "start": Vector2(lo.x, hi.y), "end": hi, "normal": Vector2.DOWN},
		{"side": "west", "start": lo, "end": Vector2(lo.x, hi.y), "normal": Vector2.LEFT},
	]

static func batches(plan: Dictionary) -> Array:
	var result: Array = []
	for side: Dictionary in sides(plan.rect):
		var tangent: Vector2 = (side.end - side.start).normalized()
		var count := roundi(side.start.distance_to(side.end)) + 1
		if count < 12: continue
		var gate_start := floori(float(count - 4) / 2)
		# An eight-cell gate batch has exactly the same half-cell gate center
		# as the complete side. Its adjacent wall batches therefore meet it.
		var gate_batch_start := gate_start - 2
		var ranges: Array = []
		var index := 0
		while index < gate_batch_start:
			var end := mini(index + 7, gate_batch_start - 1)
			ranges.append([index, end, false])
			index = end + 1
		ranges.append([gate_batch_start, gate_batch_start + 7, true])
		index = gate_batch_start + 8
		while index < count:
			var end := mini(index + 7, count - 1)
			ranges.append([index, end, false])
			index = end + 1
		for indices: Array in ranges:
			var start: Vector2 = side.start + tangent * indices[0]
			var end: Vector2 = side.start + tangent * indices[1]
			result.append({"side": side.side, "normal": side.normal, "start": start, "end": end,
				"include_gate": indices[2], "pieces": Walls.plan(plan.material, start, end, indices[2])})
	return result

static func keeps_wall_strip_clear(plan: Dictionary, point: Vector2, footprint: Vector2) -> bool:
	if plan.is_empty(): return true
	var area := Rect2(point - footprint * 0.5, footprint).grow(2.0)
	for side: Dictionary in sides(plan.rect):
		var size: Vector2 = (side.end - side.start).abs() + Vector2.ONE
		var strip := Rect2(side.start.min(side.end) - Vector2.ONE * 0.5, size)
		if area.intersects(strip): return false
	return true
