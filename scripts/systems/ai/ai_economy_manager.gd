## DEPRECATED (P5): Use Python AI service; kept for LocalAiServer adapter fallback.
class_name AiEconomyManager
extends RefCounted

const AiEntityQueriesScript := preload("res://scripts/systems/ai/ai_entity_queries.gd")
const STUCK_GATHER_FRAMES := 12
const BASE_RESOURCE_RADIUS := 144.0


func assign_builders(ctx: AiRunContext) -> void:
	for building in ctx.blackboard.team_buildings:
		if bool(building.get("is_complete")):
			continue
		var assigned_builder: Node2D = null
		for villager in ctx.blackboard.team_villagers:
			if _worker_reserved(ctx, villager):
				continue
			if (
				villager.get("order") == Enums.OrderType.BUILD
				and villager.get("_build_target") == building
			):
				assigned_builder = villager
				if int(villager.get("_no_progress_frames")) >= STUCK_GATHER_FRAMES:
					ctx.issue_build(villager, building)
					ctx.log_decision("ECON", "重建路径建造 %s" % _building_label(building))
				break
		if assigned_builder != null:
			continue
		var available: Array[Node2D] = []
		for villager in ctx.blackboard.team_villagers:
			if not _worker_reserved(ctx, villager):
				available.append(villager)
		var idle := AiEntityQueriesScript.idle_villager(available)
		if idle != null:
			ctx.issue_build(idle, building)
			ctx.log_decision(
				"ECON",
				"派村民建造 %s" % _building_label(building)
			)


func assign_gatherers(ctx: AiRunContext) -> void:
	var needs_work := _villagers_needing_gather(ctx)
	if needs_work.is_empty():
		if ctx.match_state.progression_enabled and ctx.blackboard.map_bounds.has_area():
			_rebalance_discovered_type(ctx)
		return
	if ctx.phase <= 0 and not ctx.match_state.progression_enabled:
		_assign_opening_gatherers(ctx, needs_work)
	else:
		_assign_balanced_gatherers(ctx, needs_work)


func _rebalance_discovered_type(ctx: AiRunContext) -> void:
	# Existing assignments must track the economy's needs, including resources
	# revealed later. Move only one empty-handed surplus worker per decision.
	var counts := _count_active_gatherers(ctx)
	var total := _total_gather_count(counts)
	var ratios := _resource_ratios(ctx)
	var reserved := {}
	if ctx.capture_commands:
		for command in ctx.pending_commands:
			reserved[int(command.get("unit_id", -1))] = true
			reserved[int(command.get("builder_id", -1))] = true
	var targets: Array = ratios.keys()
	targets.sort_custom(func(a: int, b: int) -> bool:
		return float(ratios[a]) * total - int(counts[a]) > float(ratios[b]) * total - int(counts[b])
	)
	for type in targets:
		if float(ratios[type]) * total - int(counts[type]) < 0.75:
			continue
		for villager in ctx.blackboard.team_villagers:
			if villager.get("order") != Enums.OrderType.GATHER or villager.get("_gather_state") in ["to_drop_off", "searching_resource"] or float(villager.get("carry_amount")) > 0.001: continue
			if reserved.has(EntityRegistry.id_of(villager)): continue
			var previous := _last_live_resource(villager)
			if previous == null: continue
			var source: int = previous.get("resource_type")
			if source == type or int(counts[source]) - float(ratios.get(source, 0.0)) * total < 0.75: continue
			var target := AiEntityQueriesScript.nearest_resource_near_base(villager, ctx.blackboard.resource_nodes, type, ctx.blackboard.own_tc_pos, BASE_RESOURCE_RADIUS)
			if target == null: continue
			ctx.issue_gather(villager, target)
			ctx.log_decision("ECON", "调配空手村民补充 " + _resource_name(type))
			return


func _villagers_needing_gather(ctx: AiRunContext) -> Array[Node2D]:
	var result: Array[Node2D] = []
	for villager in ctx.blackboard.team_villagers:
		if _worker_reserved(ctx, villager):
			continue
		var order: Enums.OrderType = villager.get("order")
		if order == Enums.OrderType.BUILD:
			continue
		# Let delivery and the worker's budgeted resource search finish first.
		if (
			order == Enums.OrderType.GATHER
			and String(villager.get("_gather_state")) in ["to_drop_off", "searching_resource"]
		):
			continue
		if order == Enums.OrderType.NONE:
			result.append(villager)
			continue
		if order != Enums.OrderType.GATHER:
			continue
		var resource := _last_live_resource(villager)
		if resource == null:
			result.append(villager)
			continue
		if float(resource.get("amount")) <= 0.0:
			result.append(villager)
			continue
		if int(villager.get("_no_progress_frames")) >= STUCK_GATHER_FRAMES:
			result.append(villager)
	return result


func _worker_reserved(ctx: AiRunContext, villager: Node2D) -> bool:
	if not ctx.capture_commands:
		return false
	var id := EntityRegistry.id_of(villager)
	for command in ctx.pending_commands:
		if int(command.get("unit_id", -1)) == id or int(command.get("builder_id", -1)) == id:
			return true
	return false


func _assign_opening_gatherers(ctx: AiRunContext, villagers: Array[Node2D]) -> void:
	var base_pos := ctx.blackboard.own_tc_pos
	for villager in villagers:
		var resource := _pick_gather_target(
			ctx, villager, Enums.ResourceType.FOOD, base_pos
		)
		if resource == null:
			continue
		ctx.issue_gather(villager, resource)
		ctx.log_decision("ECON", "开局采集 %s" % _resource_name(int(resource.get("resource_type"))))


func _assign_balanced_gatherers(ctx: AiRunContext, villagers: Array[Node2D]) -> void:
	var ratios := _resource_ratios(ctx)
	var counts := _count_active_gatherers(ctx)
	var assigned := _total_gather_count(counts)
	var base_pos := ctx.blackboard.own_tc_pos

	for villager in villagers:
		var total := assigned + 1
		var target_type := _underfilled_resource_type(counts, total, ratios)
		var resource := _pick_gather_target(ctx, villager, target_type, base_pos)
		if resource == null:
			continue
		ctx.issue_gather(villager, resource)
		var resource_type: int = int(resource.get("resource_type"))
		if counts.has(resource_type):
			counts[resource_type] = int(counts[resource_type]) + 1
		assigned += 1
		ctx.log_decision("ECON", "村民采集 %s" % _resource_name(resource_type))


func _resource_ratios(ctx: AiRunContext) -> Dictionary:
	if not ctx.match_state.progression_enabled:
		return ctx.profile.ratios_for_phase(ctx.phase)
	if AiEntityQueriesScript.find_complete_building(ctx.blackboard.team_buildings, &"barracks") == null or AiEntityQueriesScript.find_complete_building(ctx.blackboard.team_buildings, &"lumber_camp") == null:
		return {Enums.ResourceType.FOOD: 0.5, Enums.ResourceType.WOOD: 0.4, Enums.ResourceType.GOLD: 0.1, Enums.ResourceType.STONE: 0.0}
	if ctx.match_state.age_of(ctx.team) == 0:
		return {Enums.ResourceType.FOOD: 0.5, Enums.ResourceType.WOOD: 0.3, Enums.ResourceType.GOLD: 0.1, Enums.ResourceType.STONE: 0.1}
	return {Enums.ResourceType.FOOD: 0.4, Enums.ResourceType.WOOD: 0.25, Enums.ResourceType.GOLD: 0.25, Enums.ResourceType.STONE: 0.1}


func _pick_gather_target(
	ctx: AiRunContext,
	villager: Node2D,
	preferred_type: Enums.ResourceType,
	base_pos: Vector2
) -> Node2D:
	var resource := AiEntityQueriesScript.nearest_resource_near_base(
		villager, ctx.blackboard.resource_nodes, preferred_type, base_pos, BASE_RESOURCE_RADIUS
	)
	if resource != null:
		return resource
	# Preferred type depleted — walk wood → gold → food for any remaining stock.
	var fallback_order: Array[Enums.ResourceType] = [
		Enums.ResourceType.WOOD,
		Enums.ResourceType.GOLD,
		Enums.ResourceType.FOOD,
	]
	for resource_type in fallback_order:
		if resource_type == preferred_type:
			continue
		resource = AiEntityQueriesScript.nearest_resource_near_base(
			villager, ctx.blackboard.resource_nodes, resource_type, base_pos, BASE_RESOURCE_RADIUS
		)
		if resource != null:
			return resource
	return AiEntityQueriesScript.nearest_any_resource_near_base(
		villager, ctx.blackboard.resource_nodes, base_pos, BASE_RESOURCE_RADIUS
	)


func _count_active_gatherers(ctx: AiRunContext) -> Dictionary:
	var counts := {
		Enums.ResourceType.FOOD: 0,
		Enums.ResourceType.WOOD: 0,
		Enums.ResourceType.GOLD: 0,
		Enums.ResourceType.STONE: 0,
	}
	for villager in ctx.blackboard.team_villagers:
		if villager.get("order") != Enums.OrderType.GATHER:
			continue
		var resource := _last_live_resource(villager)
		if resource == null:
			continue
		var resource_type: int = int(resource.get("resource_type"))
		if counts.has(resource_type):
			counts[resource_type] = int(counts[resource_type]) + 1
	return counts


func _last_live_resource(villager: Node2D) -> Node2D:
	# A worker can retain its source while delivering or searching after removal.
	# Keep the raw reference untyped until validated: casting a freed object throws.
	var resource: Variant = villager.get("_last_resource")
	if not is_instance_valid(resource) or not resource is Node2D or resource.is_queued_for_deletion():
		return null
	return resource as Node2D


func _total_gather_count(counts: Dictionary) -> int:
	return (
		int(counts[Enums.ResourceType.FOOD])
		+ int(counts[Enums.ResourceType.WOOD])
		+ int(counts[Enums.ResourceType.GOLD])
		+ int(counts[Enums.ResourceType.STONE])
	)


func _underfilled_resource_type(
	counts: Dictionary, total: int, targets: Dictionary
) -> Enums.ResourceType:
	var best_type: Enums.ResourceType = Enums.ResourceType.FOOD
	var best_deficit := -INF
	for resource_type in targets.keys():
		var actual := float(counts[resource_type]) / float(maxi(total, 1))
		var deficit: float = float(targets[resource_type]) - actual
		if deficit > best_deficit:
			best_deficit = deficit
			best_type = resource_type
	return best_type


func _building_label(building: Node2D) -> String:
	var building_def := building.get("def") as BuildingDef
	return String(building_def.id) if building_def != null else "building"


func _resource_name(resource_type: int) -> String:
	match resource_type:
		Enums.ResourceType.FOOD:
			return "food"
		Enums.ResourceType.WOOD:
			return "wood"
		Enums.ResourceType.GOLD:
			return "gold"
		Enums.ResourceType.STONE:
			return "stone"
		_:
			return "resource"
