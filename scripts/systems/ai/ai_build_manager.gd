class_name AiBuildManager
extends RefCounted

const Catalog := preload("res://scripts/data/game_catalog.gd")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const HOUSE: BuildingDef = preload("res://data/buildings/house.tres")
const BARRACKS: BuildingDef = preload("res://data/buildings/barracks.tres")
const ARCHERY_RANGE: BuildingDef = preload("res://data/buildings/archery_range.tres")
const STABLE: BuildingDef = preload("res://data/buildings/stable.tres")

const AiEntityQueriesScript := preload("res://scripts/systems/ai/ai_entity_queries.gd")


func tick(ctx: AiRunContext) -> void:
	if ctx.phase <= 0:  # ECO — 仅人口满时由 Production 触发 house
		return
	_tick_build_order(ctx)
	if ctx.phase >= 1:  # BOOM+
		_ensure_military_buildings(ctx)


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
	if ctx.match_state.progression_enabled and building_def != null: building_def = Catalog.get_building(building_def.id)
	if building_def == null:
		return false
	if not Catalog.building_reason(ctx.match_state, ctx.team, ctx.civ, building_def, ctx.entities).is_empty():
		return false
	if building_def.id != &"house" and AiEntityQueriesScript.has_building(
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
	var builder := AiEntityQueriesScript.idle_villager(ctx.blackboard.team_villagers)
	if builder == null:
		for candidate in ctx.blackboard.team_villagers:
			if candidate.get("order") != Enums.OrderType.BUILD:
				builder = candidate
				break
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
