class_name AiBuildManager
extends RefCounted

const Catalog := preload("res://scripts/data/game_catalog.gd")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const HOUSE: BuildingDef = preload("res://data/buildings/house.tres")
const BARRACKS: BuildingDef = preload("res://data/buildings/barracks.tres")
const ARCHERY_RANGE: BuildingDef = preload("res://data/buildings/archery_range.tres")
const STABLE: BuildingDef = preload("res://data/buildings/stable.tres")
const FARM_AGENT := preload("res://scripts/entities/farm_agent.gd")
const FARM_SUPPLY_RADIUS := 144.0
const FARM_FOOD_THRESHOLD := 100.0
const FARM_FOOD_AMOUNT := 175.0

const AiEntityQueriesScript := preload("res://scripts/systems/ai/ai_entity_queries.gd")


func tick(ctx: AiRunContext) -> void:
	ensure_food_supply(ctx)
	if ctx.phase <= 0:  # ECO — farms above; Production handles population houses.
		return
	_tick_build_order(ctx)
	if ctx.phase >= 1:  # BOOM+
		_ensure_military_buildings(ctx)


## Original berries run out. Keep a small farm economy once local natural food
## falls low; completed farms can coexist and already growing plots count too.
func ensure_food_supply(ctx: AiRunContext) -> bool:
	if ctx.match_state == null or not ctx.match_state.progression_enabled or ctx.match_state.frozen:
		return false
	if AiEntityQueriesScript.find_complete_building(ctx.blackboard.team_buildings, &"mill") == null:
		return false
	var town_center := AiEntityQueriesScript.find_town_center(ctx.blackboard.team_buildings)
	if town_center == null:
		return false
	var origin: Vector2 = town_center.get("sim_pos")
	var natural_food := 0.0
	for resource in ctx.blackboard.resource_nodes:
		if resource.get("def") is BuildingDef or int(resource.get("resource_type")) != Enums.ResourceType.FOOD:
			continue
		var pos: Vector2 = resource.get("sim_pos")
		if origin.distance_to(pos) <= FARM_SUPPLY_RADIUS:
			natural_food += maxf(0.0, float(resource.get("amount")))
	if natural_food > FARM_FOOD_THRESHOLD:
		return false
	var active_farms := 0
	var exhausted: Node2D
	for building in ctx.blackboard.team_buildings:
		var definition := building.get("def") as BuildingDef
		if definition == null or definition.id != &"farm" or origin.distance_to(building.get("sim_pos")) > FARM_SUPPLY_RADIUS:
			continue
		if not bool(building.get("is_complete")) or float(building.get("amount")) > 0:
			active_farms += 1
		elif exhausted == null:
			exhausted = building
	var desired := clampi(ceili(ctx.blackboard.team_villagers.size() / 2.0), 2, 4)
	if active_farms >= desired:
		return false
	var farm := Catalog.get_building("farm")
	if farm == null:
		return false
	# Offline AI can renew its own plot. Captured/external AI uses a normal new
	# foundation so the shared protocol has no hidden state mutations.
	if exhausted != null and not ctx.capture_commands:
		if ctx.match_state.spend(ctx.team, farm.cost_food, farm.cost_wood, farm.cost_gold, farm.cost_stone):
			exhausted.set("amount", FARM_FOOD_AMOUNT)
			ctx.log_decision("ECON", "重播农田")
			return true
		return false
	return ensure_building(ctx, farm)


func ensure_house_if_pop_blocked(ctx: AiRunContext, unit_def: UnitDef) -> void:
	if unit_def == null or ctx.match_state == null:
		return
	if not ctx.match_state.can_afford(
		ctx.team, unit_def.cost_food, unit_def.cost_wood, unit_def.cost_gold
	):
		return
	if int(ctx.match_state.population[ctx.team]) + int(ctx.match_state.population_reserved[ctx.team]) + unit_def.population <= int(ctx.match_state.population_cap[ctx.team]):
		return
	ensure_building(ctx, HOUSE)


func ensure_building(ctx: AiRunContext, building_def: BuildingDef) -> bool:
	# Captured commands have not created foundations in the scene yet. Wait for
	# the next observation before planning another site against updated blockers.
	if ctx.capture_commands:
		for command in ctx.pending_commands:
			if command.get("op", "") == "place_building":
				return false
	if ctx.match_state.progression_enabled and building_def != null: building_def = Catalog.get_building(building_def.id)
	if building_def == null:
		return false
	if not Catalog.building_reason(ctx.match_state, ctx.team, ctx.civ, building_def, ctx.entities).is_empty():
		return false
	if building_def.id not in [&"house", &"farm"] and AiEntityQueriesScript.has_building(
		ctx.blackboard.team_buildings, building_def.id
	):
		return false
	if AiEntityQueriesScript.has_incomplete_building(
		ctx.blackboard.team_buildings, building_def.id
	):
		return false
	if not ctx.match_state.can_afford(
		ctx.team,
		building_def.cost_food,
		building_def.cost_wood,
		building_def.cost_gold,
		building_def.cost_stone,
	):
		return false
	var builder := _available_builder(ctx)
	if builder == null:
		return false
	var town_center := AiEntityQueriesScript.find_town_center(ctx.blackboard.team_buildings)
	var place_position: Variant = AiEntityQueriesScript.next_build_position(
		building_def, town_center, ctx.entities, ctx.next_build_slot
	)
	if place_position == null:
		return false
	if ctx.capture_commands:
		ctx.issue_place_building(building_def, place_position as Vector2, builder)
		ctx.log_decision("BUILD", "放置 %s @ %s" % [building_def.id, place_position])
		return true
	if not ctx.match_state.spend(
		ctx.team,
		building_def.cost_food,
		building_def.cost_wood,
		building_def.cost_gold,
		building_def.cost_stone,
	):
		return false
	var foundation := BUILDING_VIEW.instantiate() as Node2D
	if building_def.id == &"farm":
		foundation.set_script(FARM_AGENT)
	foundation.name = "Ai%sFoundation%d" % [
		String(building_def.id).to_pascal_case(),
		ctx.next_build_slot,
	]
	foundation.set("team", ctx.team)
	foundation.set("def", building_def)
	foundation.set("civ", ctx.civ)
	foundation.set("match_state", ctx.match_state)
	foundation.set("sim_pos", place_position)
	foundation.call("start_construction")
	ctx.entities.add_child(foundation)
	ctx.issue_build(builder, foundation)
	ctx.next_build_slot += 1
	ctx.log_decision("BUILD", "放置 %s @ %s" % [building_def.id, place_position])
	return true


func _available_builder(ctx: AiRunContext) -> Node2D:
	# Keep existing construction, combat, travel and deliveries intact. Captured
	# orders have not changed the actor yet, so reserve their workers explicitly.
	var reserved := {}
	if ctx.capture_commands:
		for command in ctx.pending_commands:
			for key in ["unit_id", "builder_id"]:
				if command.has(key): reserved[int(command[key])] = true
	var gatherer: Node2D
	for candidate in ctx.blackboard.team_villagers:
		if float(candidate.get("carry_amount")) > 0.001:
			continue
		if ctx.capture_commands and reserved.has(EntityRegistry.id_of(candidate)):
			continue
		var order: int = candidate.get("order")
		if order == Enums.OrderType.NONE:
			return candidate
		if order == Enums.OrderType.GATHER and candidate.get("_gather_state") != "to_drop_off" and gatherer == null:
			gatherer = candidate
	return gatherer


func _tick_build_order(ctx: AiRunContext) -> void:
	for building_id in ctx.profile.build_order:
		var building_def := _def_for_id(building_id)
		if building_def == null:
			continue
		if AiEntityQueriesScript.has_building(ctx.blackboard.team_buildings, building_id):
			continue
		if AiEntityQueriesScript.has_incomplete_building(
			ctx.blackboard.team_buildings, building_id
		):
			continue
		if ensure_building(ctx, building_def):
			return


func _ensure_military_buildings(ctx: AiRunContext) -> void:
	ensure_building(ctx, BARRACKS)
	ensure_building(ctx, ARCHERY_RANGE)
	if ctx.civ != null and ctx.civ.id == &"teutons":
		ensure_building(ctx, STABLE)
	if ctx.match_state.progression_enabled and ctx.match_state.age_of(ctx.team) >= 2:
		ensure_building(ctx, Catalog.get_building("castle"))
		ensure_building(ctx, Catalog.get_building("siege_workshop"))


func _def_for_id(building_id: StringName) -> BuildingDef:
	return Catalog.get_building(String(building_id))
