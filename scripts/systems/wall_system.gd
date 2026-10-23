class_name WallSystem
extends RefCounted

const Catalog := preload("res://scripts/data/game_catalog.gd")
const Shore := preload("res://scripts/world/shore_geometry.gd")
const MAX_SEGMENTS := 64
const WALL_IDS := ["palisade_wall", "stone_wall", "fortified_wall"]

static func is_wall(id: StringName) -> bool:
	return String(id) in WALL_IDS

static func is_fortification(id: StringName) -> bool:
	return is_wall(id) or id == &"gate"

static func direction(orientation: int) -> Vector2:
	return [Vector2.RIGHT, Vector2(1, 1), Vector2.DOWN, Vector2(-1, 1)][posmod(orientation, 4)]

static func footprint_for(definition: BuildingDef, orientation := 0) -> Vector2:
	if definition == null: return Vector2.ONE
	if definition.id != &"gate": return definition.footprint
	match posmod(orientation, 4):
		0: return Vector2(4, 1)
		2: return Vector2(1, 4)
		_: return Vector2(4, 4)

static func configure_building(building: Node2D, orientation: int) -> void:
	building.set("wall_orientation", posmod(orientation, 4))
	if building.is_node_ready():
		building.call("_sync_block_half")
		building.call("_configure_visuals")

static func plan(building_def_id: String, start: Vector2, end: Vector2, include_gate := false) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if building_def_id not in WALL_IDS or not start.is_finite() or not end.is_finite(): return result
	start = start.round()
	var delta := end.round() - start
	var axis := posmod(roundi(delta.angle() / (PI / 4.0)), 8)
	var step := Vector2(roundf(cos(axis * PI / 4.0)), roundf(sin(axis * PI / 4.0)))
	var count := roundi(maxf(absf(delta.x), absf(delta.y))) + 1
	if count > MAX_SEGMENTS or (include_gate and count < 6): return result
	var gate_start := floori(float(count - 4) / 2.0) if include_gate else -10
	for index in count:
		if include_gate and index >= gate_start and index < gate_start + 4:
			if index == gate_start:
				result.append({"building_def_id": "gate", "pos": start + step * (gate_start + 1.5), "orientation": axis % 4})
			continue
		result.append({"building_def_id": building_def_id, "pos": start + step * index, "orientation": axis % 4})
	return result

static func _overlaps(a: Vector2, a_size: Vector2, b: Vector2, b_size: Vector2) -> bool:
	var delta := (a - b).abs()
	var half := (a_size + b_size) * 0.5 - Vector2.ONE * 0.001
	return delta.x < half.x and delta.y < half.y

static func existing_segment(item: Dictionary, ctx: CommandExecutionContext) -> Node2D:
	for node in ctx.entities.get_children():
		if not node is Node2D or node.is_queued_for_deletion() or node.get("is_placement_ghost") == true: continue
		var definition := node.get("def") as BuildingDef
		if definition == null or int(node.get("team")) != int(ctx.team) or float(node.get("hp")) <= 0: continue
		# A perimeter may connect to an older wall of a different material.
		# Reuse the existing structure as-is; this never grants an upgrade.
		var same_material: bool = String(definition.id) == item.building_def_id
		var existing_wall := is_wall(definition.id) and is_wall(StringName(item.building_def_id))
		if (same_material or existing_wall) and node.get("sim_pos").distance_to(item.pos) < 0.01:
			if definition.id != &"gate" or int(node.get("wall_orientation")) == int(item.orientation): return node
	return null

static func cost(plan_items: Array, ctx: CommandExecutionContext = null) -> Dictionary:
	var total := {"food": 0, "wood": 0, "gold": 0, "stone": 0}
	for item: Dictionary in plan_items:
		if ctx != null and existing_segment(item, ctx) != null: continue
		var definition := Catalog.get_building(StringName(item.building_def_id))
		if definition == null: continue
		total.food += definition.cost_food
		total.wood += definition.cost_wood
		total.gold += definition.cost_gold
		total.stone += definition.cost_stone
	return total

static func validate_plan(plan_items: Array, ctx: CommandExecutionContext, check_budget := true) -> String:
	if ctx == null or ctx.match_state == null or ctx.entities == null: return "missing_context"
	if plan_items.is_empty() or plan_items.size() > MAX_SEGMENTS: return "invalid_wall_length"
	var checked: Array[Dictionary] = []
	for item: Dictionary in plan_items:
		var definition := Catalog.get_building(StringName(item.get("building_def_id", "")))
		if definition == null or not is_fortification(definition.id): return "invalid_wall_type"
		if item.get("pos") is not Vector2 or not item.pos.is_finite(): return "invalid_pos"
		if item.get("orientation", 0) is not int or int(item.get("orientation", 0)) not in range(4): return "invalid_orientation"
		var reason := Catalog.building_reason(ctx.match_state, ctx.team, ctx.civ, definition, ctx.entities)
		if not reason.is_empty() and reason != "资源不足": return reason
		var footprint := footprint_for(definition, int(item.get("orientation", 0)))
		var rect := Rect2(item.pos - footprint * 0.5, footprint)
		if ctx.match_state.map_bounds.has_area() and not ctx.match_state.map_bounds.encloses(rect): return "outside_map"
		if ctx.match_state.fog_enabled and (ctx.match_state.fog == null or not ctx.match_state.fog.footprint_visible(ctx.team, item.pos, footprint, true)): return "need_vision"
		for other: Dictionary in checked:
			if _overlaps(item.pos, footprint, other.pos, other.footprint): return "overlapping_segments"
		checked.append({"pos": item.pos, "footprint": footprint})
		var reused := existing_segment(item, ctx)
		for node in ctx.entities.get_children():
			if not node is Node2D or node == reused or node.is_queued_for_deletion() or node.get("is_placement_ghost") == true: continue
			if node.has_method("get_water_contours") and not node.get_water_contours().is_empty():
				if Shore.intersects_rect(rect, node.get_water_contours()): return "invalid_placement"
				continue
			var other_def := node.get("def") as BuildingDef
			if other_def != null:
				var other_size: Vector2 = node.call("get_placement_footprint") if node.has_method("get_placement_footprint") else other_def.footprint
				if _overlaps(item.pos, footprint, node.get("sim_pos"), other_size): return "invalid_placement"
			elif node.is_in_group("terrain_regions") and node.get("block_size") is Vector2:
				if _overlaps(item.pos, footprint, node.get("sim_pos"), node.get("block_size")): return "invalid_placement"
			elif node.has_method("pathfinding_size") and float(node.get("amount")) > 0:
				var size: Vector2 = node.pathfinding_size()
				if size != Vector2.ZERO and _overlaps(item.pos, footprint, node.get("sim_pos"), size): return "invalid_placement"
	var price := cost(plan_items, ctx)
	if check_budget and not ctx.match_state.can_afford(ctx.team, price.food, price.wood, price.gold, price.stone): return "cannot_afford_wall"
	return ""

static func place_plan(plan_items: Array, ctx: CommandExecutionContext, builder: Node2D, append := false) -> Array[Node2D]:
	var foundations: Array[Node2D] = []
	if not is_instance_valid(builder) or builder.get("team") != ctx.team or not builder.has_method("command_build_queue"): return foundations
	var unit_def := builder.get("def") as UnitDef
	if unit_def == null or unit_def.id != &"villager" or float(builder.get("hp")) <= 0: return foundations
	if not validate_plan(plan_items, ctx).is_empty(): return foundations
	var price := cost(plan_items, ctx)
	if not ctx.match_state.spend(ctx.team, price.food, price.wood, price.gold, price.stone): return foundations
	var queue: Array[Node2D] = []
	var scene := load("res://scenes/entities/building_view.tscn") as PackedScene
	for item: Dictionary in plan_items:
		var reused := existing_segment(item, ctx)
		if reused != null:
			if not bool(reused.get("is_complete")): queue.append(reused)
			continue
		var foundation := scene.instantiate() as Node2D
		foundation.set("def", Catalog.get_building(StringName(item.building_def_id)))
		foundation.set("team", ctx.team)
		foundation.set("civ", ctx.civ)
		foundation.set("match_state", ctx.match_state)
		foundation.set("sim_pos", item.pos)
		configure_building(foundation, int(item.orientation))
		foundation.call("start_construction")
		ctx.entities.add_child(foundation)
		foundations.append(foundation)
		queue.append(foundation)
	if not queue.is_empty(): builder.call("command_build_queue", queue, append)
	return foundations
